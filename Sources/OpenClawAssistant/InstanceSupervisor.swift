import AppKit
import Foundation

final class InstanceSupervisor {
    private struct ObservedProcess {
        let pid: Int32
        let command: String
        let currentDirectory: String?
    }

    private struct LaunchdService {
        let label: String
        let plistPath: String
    }

    private let store: ConfigurationStore
    private var configuration: AssistantConfiguration
    private var runtime: RuntimeState

    init(store: ConfigurationStore) {
        self.store = store
        self.configuration = store.loadConfiguration()
        self.runtime = store.loadRuntime()
    }

    func reloadConfiguration() {
        configuration = store.loadConfiguration()
        runtime = store.loadRuntime()
    }

    func reports() -> [InstanceReport] {
        reloadConfiguration()
        let processes = observedProcesses()
        var textReferenceCache: [Int32: [String]] = [:]
        var nextRuntime = runtime
        var didMutateRuntime = false

        let reports = configuration.instances.map { instance in
            var runtimeState = nextRuntime.instances[instance.id] ?? .empty
            let repoPath = instance.expandedRepoPath
            let repoExists = repositoryLooksValid(for: instance)
            let observedPIDs = repoExists
                ? matchingPIDs(for: instance, in: processes, textReferenceCache: &textReferenceCache)
                : []

            let observedRuntimeState = synchronizedRuntimeState(
                runtimeState,
                withObservedPIDs: observedPIDs
            )
            if observedRuntimeState != runtimeState {
                runtimeState = observedRuntimeState
                nextRuntime.instances[instance.id] = observedRuntimeState
                didMutateRuntime = true
            }

            let branch = repoExists ? currentGitBranch(for: repoPath) : nil
            let lastActivity = FileSystem.latestModificationDate(
                for: instance.activityPaths + [store.logURL(for: instance).path]
            )
            let recentLog = FileSystem.lastNonEmptyLine(in: store.logURL(for: instance))

            let status = resolveStatus(
                for: instance,
                runtime: runtimeState,
                repoExists: repoExists,
                observedPIDs: observedPIDs
            )

            return InstanceReport(
                instance: instance,
                runtime: runtimeState,
                status: status,
                observedPIDs: observedPIDs,
                repoExists: repoExists,
                repoBranch: branch,
                lastActivityAt: lastActivity,
                recentLogLine: recentLog,
                logFileURL: store.logURL(for: instance)
            )
        }

        if didMutateRuntime {
            runtime = nextRuntime
            try? store.save(runtime: nextRuntime)
        }

        return reports
    }

    func start(instanceID: String) throws {
        reloadConfiguration()
        guard let instance = configuration.instances.first(where: { $0.id == instanceID }) else {
            return
        }
        guard !instance.disabled else {
            return
        }
        guard repositoryLooksValid(for: instance) else {
            throw SupervisorError.invalidRepository(instance.expandedRepoPath)
        }

        let report = reports().first(where: { $0.id == instanceID })
        if report?.status == .running || report?.status == .starting {
            return
        }

        if try startManagedLaunchdServicesIfPresent(for: instance) {
            var nextRuntime = runtime.instances[instance.id] ?? .empty
            nextRuntime.lastStartedAt = Date()
            nextRuntime.lastStopWasManual = false
            nextRuntime.lastExitCode = nil
            nextRuntime.lastCrashedAt = nil
            runtime.instances[instance.id] = nextRuntime
            try store.save(runtime: runtime)
            return
        }

        let repoURL = URL(fileURLWithPath: instance.expandedRepoPath)
        let logURL = store.logURL(for: instance)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let outputHandle = try FileHandle(forWritingTo: logURL)
        try outputHandle.seekToEnd()

        let process = Process()
        process.currentDirectoryURL = repoURL
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var processEnvironment = instance.env
        processEnvironment["OPENCLAW_ASSISTANT_INSTANCE_ID"] = instance.id
        processEnvironment["OPENCLAW_ASSISTANT_INSTANCE_NAME"] = instance.name

        let envAssignments = processEnvironment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        process.arguments = envAssignments + instance.startCommand
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        let runtimeURL = store.runtimeURL
        let instanceID = instance.id
        process.terminationHandler = { finishedProcess in
            Self.recordTermination(
                runtimeURL: runtimeURL,
                instanceID: instanceID,
                exitCode: finishedProcess.terminationStatus
            )
        }

        try process.run()

        var nextRuntime = runtime.instances[instance.id] ?? .empty
        nextRuntime.pid = process.processIdentifier
        nextRuntime.lastStartedAt = Date()
        nextRuntime.lastStopWasManual = false
        nextRuntime.lastExitCode = nil
        runtime.instances[instance.id] = nextRuntime
        try store.save(runtime: runtime)
    }

    func stop(instanceID: String) throws {
        reloadConfiguration()
        guard configuration.instances.contains(where: { $0.id == instanceID }) else {
            return
        }

        let report = reports().first(where: { $0.id == instanceID })
        guard let report else { return }

        var nextRuntime = runtime.instances[instanceID] ?? .empty
        nextRuntime.lastStopWasManual = true
        nextRuntime.lastStoppedAt = Date()
        runtime.instances[instanceID] = nextRuntime
        try store.save(runtime: runtime)

        if let instance = configuration.instances.first(where: { $0.id == instanceID }) {
            stopManagedLaunchdServices(for: instance)
        }

        for pid in report.observedPIDs {
            _ = ProcessRunner.run(executable: "/bin/kill", arguments: ["-TERM", String(pid)])
        }

        let waitUntil = Date().addingTimeInterval(2)
        while Date() < waitUntil {
            var textReferenceCache: [Int32: [String]] = [:]
            let refreshedPIDs = matchingPIDs(
                for: report.instance,
                in: observedProcesses(),
                textReferenceCache: &textReferenceCache
            )
            if refreshedPIDs.isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        var textReferenceCache: [Int32: [String]] = [:]
        for pid in matchingPIDs(
            for: report.instance,
            in: observedProcesses(),
            textReferenceCache: &textReferenceCache
        ) {
            _ = ProcessRunner.run(executable: "/bin/kill", arguments: ["-KILL", String(pid)])
        }

        nextRuntime.pid = nil
        runtime.instances[instanceID] = nextRuntime
        try store.save(runtime: runtime)
    }

    func restart(instanceID: String) throws {
        try stop(instanceID: instanceID)
        Thread.sleep(forTimeInterval: 0.2)
        try start(instanceID: instanceID)
    }

    func startAll() throws {
        reloadConfiguration()
        for instance in configuration.instances where !instance.disabled {
            try start(instanceID: instance.id)
        }
    }

    func stopAll() throws {
        reloadConfiguration()
        for instance in configuration.instances where !instance.disabled {
            try stop(instanceID: instance.id)
        }
    }

    func restartAll() throws {
        reloadConfiguration()
        for instance in configuration.instances where !instance.disabled {
            try restart(instanceID: instance.id)
        }
    }

    func managedLaunchdLabels(for instanceID: String) -> [String] {
        reloadConfiguration()
        guard let instance = configuration.instances.first(where: { $0.id == instanceID }) else {
            return []
        }

        let installed = installedLaunchdServices(matching: instance).map(\.label)
        let loaded = loadedLaunchdServices(matching: instance).map(\.label)
        return Array(Set(installed + loaded)).sorted()
    }

    private func resolveStatus(
        for instance: OpenClawInstance,
        runtime: InstanceRuntimeState,
        repoExists: Bool,
        observedPIDs: [Int32]
    ) -> InstanceStatus {
        if instance.disabled {
            return .disabled
        }
        if !repoExists {
            return .missingProject
        }
        if !observedPIDs.isEmpty {
            if let lastStartedAt = runtime.lastStartedAt,
               Date().timeIntervalSince(lastStartedAt) < 8 {
                return .starting
            }
            return .running
        }
        if runtime.lastStopWasManual {
            return .stopped
        }
        if runtime.lastCrashedAt != nil || runtime.lastExitCode.map({ $0 != 0 }) == true {
            return .crashed
        }
        return .stopped
    }

    private func matchingPIDs(
        for instance: OpenClawInstance,
        in processes: [ObservedProcess],
        textReferenceCache: inout [Int32: [String]]
    ) -> [Int32] {
        let matchers = instance.processMatch.isEmpty
            ? ["OPENCLAW_ASSISTANT_INSTANCE_ID=\(instance.id)"]
            : instance.processMatch
        let repoPath = standardizedPath(instance.expandedRepoPath)
        let launchTokens = instance.startCommand
            .map { $0.lowercased() }
            .filter { !$0.contains("=") && $0.count >= 3 }

        return processes.compactMap { process in
            let command = process.command.lowercased()
            let matchesConfigured = matchers.allSatisfy { command.contains($0.lowercased()) }
            let matchesRepoPath = command.contains(repoPath)
            let matchesCurrentDirectory = process.currentDirectory.map { standardizedPath($0) == repoPath } ?? false
            let matchesLaunchTokens = !launchTokens.isEmpty && launchTokens.allSatisfy { command.contains($0) }
            let looksLikeOpenClawProcess =
                command.contains("scripts/run-node.mjs") ||
                command.contains("gateway") ||
                command.contains("openclaw")
            let matchesTextReferences =
                looksLikeOpenClawProcess &&
                processReferencesRepository(
                    pid: process.pid,
                    repoPath: repoPath,
                    cache: &textReferenceCache
                )

            guard
                matchesConfigured ||
                matchesRepoPath ||
                matchesTextReferences ||
                (matchesCurrentDirectory && (matchesLaunchTokens || looksLikeOpenClawProcess))
            else {
                return nil
            }
            return process.pid
        }
    }

    private func observedProcesses() -> [ObservedProcess] {
        let psOutput = ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,command="]
        ).stdout

        return psOutput
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                guard let splitIndex = trimmed.firstIndex(where: \.isWhitespace) else { return nil }

                let pidString = trimmed[..<splitIndex]
                let command = trimmed[splitIndex...].trimmingCharacters(in: .whitespaces)
                guard let pid = Int32(pidString) else { return nil }

                let currentDirectory = shouldInspectCurrentDirectory(for: command)
                    ? currentWorkingDirectory(for: pid)
                    : nil

                return ObservedProcess(
                    pid: pid,
                    command: command,
                    currentDirectory: currentDirectory
                )
            }
    }

    private func repositoryLooksValid(for instance: OpenClawInstance) -> Bool {
        let repoURL = URL(fileURLWithPath: instance.expandedRepoPath)
        guard FileSystem.directoryExists(atPath: repoURL.path) else {
            return false
        }

        let packageJSON = repoURL.appendingPathComponent("package.json").path
        let openClawEntry = repoURL.appendingPathComponent("openclaw.mjs").path
        guard FileSystem.fileExists(atPath: packageJSON) || FileSystem.fileExists(atPath: openClawEntry) else {
            return false
        }

        if instance.startCommand.contains("scripts/run-node.mjs") {
            let runNodeScript = repoURL.appendingPathComponent("scripts/run-node.mjs").path
            guard FileSystem.fileExists(atPath: runNodeScript) else {
                return false
            }
        }

        return true
    }

    private func synchronizedRuntimeState(
        _ runtimeState: InstanceRuntimeState,
        withObservedPIDs observedPIDs: [Int32]
    ) -> InstanceRuntimeState {
        guard let observedPID = observedPIDs.first else {
            guard runtimeState.pid != nil, !runtimeState.lastStopWasManual else {
                return runtimeState
            }

            var next = runtimeState
            var didChange = false
            if next.pid != nil {
                next.pid = nil
                didChange = true
            }
            if next.lastCrashedAt == nil {
                next.lastCrashedAt = Date()
                didChange = true
            }
            return didChange ? next : runtimeState
        }

        var next = runtimeState
        var didChange = false

        if next.pid != observedPID {
            next.pid = observedPID
            didChange = true
        }
        if next.lastStopWasManual {
            next.lastStopWasManual = false
            didChange = true
        }
        if next.lastStartedAt == nil {
            next.lastStartedAt = Date()
            didChange = true
        }
        if next.lastCrashedAt != nil {
            next.lastCrashedAt = nil
            didChange = true
        }
        if next.lastExitCode != nil {
            next.lastExitCode = nil
            didChange = true
        }

        return didChange ? next : runtimeState
    }

    private func shouldInspectCurrentDirectory(for command: String) -> Bool {
        let lowered = command.lowercased()
        return ["node", "pnpm", "npm", "yarn", "bun", "openclaw", "gateway"].contains(where: lowered.contains)
    }

    private func currentWorkingDirectory(for pid: Int32) -> String? {
        let result = ProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-d", "cwd", "-p", String(pid), "-Fn"]
        )
        guard result.exitCode == 0 else {
            return nil
        }

        return result.stdout
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("n") })
            .map { String($0.dropFirst()) }
    }

    private func processReferencesRepository(
        pid: Int32,
        repoPath: String,
        cache: inout [Int32: [String]]
    ) -> Bool {
        let references: [String]
        if let cached = cache[pid] {
            references = cached
        } else {
            let result = ProcessRunner.run(
                executable: "/usr/sbin/lsof",
                arguments: ["-a", "-d", "txt", "-p", String(pid), "-Fn"]
            )
            let parsed = result.stdout
                .split(separator: "\n")
                .filter { $0.hasPrefix("n") }
                .map { standardizedPath(String($0.dropFirst())) }
            cache[pid] = parsed
            references = parsed
        }

        return references.contains { reference in
            reference == repoPath || reference.hasPrefix("\(repoPath)/")
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }

    private func currentGitBranch(for repoPath: String) -> String? {
        let result = ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"]
        )
        guard result.exitCode == 0 else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recordTermination(runtimeURL: URL, instanceID: String, exitCode: Int32) {
        let runtime: RuntimeState
        if let data = try? Data(contentsOf: runtimeURL),
           let decoded = try? JSONDecoder().decode(RuntimeState.self, from: data) {
            runtime = decoded
        } else {
            runtime = .empty
        }

        var nextRuntime = runtime.instances[instanceID] ?? .empty
        let wasManualStop = nextRuntime.lastStopWasManual
        nextRuntime.pid = nil
        nextRuntime.lastExitCode = exitCode

        if wasManualStop {
            nextRuntime.lastStoppedAt = Date()
        } else if exitCode != 0 {
            nextRuntime.lastCrashedAt = Date()
        }

        var nextState = runtime
        nextState.instances[instanceID] = nextRuntime

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(nextState) {
            try? data.write(to: runtimeURL, options: .atomic)
        }
    }

    private func startManagedLaunchdServicesIfPresent(for instance: OpenClawInstance) throws -> Bool {
        let services = installedLaunchdServices(matching: instance)
        guard !services.isEmpty else {
            return false
        }

        let domain = launchdDomain()
        var startedAny = false

        for service in services {
            _ = runLaunchctl(arguments: ["enable", "\(domain)/\(service.label)"])
            _ = runLaunchctl(arguments: ["bootstrap", domain, service.plistPath])
            let result = runLaunchctl(arguments: ["kickstart", "-k", "\(domain)/\(service.label)"])
            if result.exitCode == 0 {
                startedAny = true
            }
        }

        return startedAny
    }

    private func stopManagedLaunchdServices(for instance: OpenClawInstance) {
        let services = loadedLaunchdServices(matching: instance)
        guard !services.isEmpty else {
            return
        }

        let domain = launchdDomain()
        for service in services {
            _ = runLaunchctl(arguments: ["bootout", domain, service.plistPath])
            _ = runLaunchctl(arguments: ["disable", "\(domain)/\(service.label)"])
        }
    }

    private func installedLaunchdServices(matching instance: OpenClawInstance) -> [LaunchdService] {
        let agentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: agentsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let repoPath = standardizedPath(instance.expandedRepoPath)
        var matched: [LaunchdService] = []

        for file in files where file.pathExtension == "plist" {
            let plistPath = file.path
            let result = ProcessRunner.run(
                executable: "/usr/bin/plutil",
                arguments: ["-p", plistPath]
            )
            guard result.exitCode == 0 else {
                continue
            }

            let lowered = result.stdout.lowercased()
            guard lowered.contains(repoPath) else {
                continue
            }

            guard let label = firstMatch(in: result.stdout, pattern: #""Label"\s*=>\s*"([^"]+)""#),
                  !label.isEmpty else {
                continue
            }

            matched.append(LaunchdService(label: label, plistPath: plistPath))
        }

        return matched
    }

    private func loadedLaunchdServices(matching instance: OpenClawInstance) -> [LaunchdService] {
        let list = runLaunchctl(arguments: ["list"])
        guard list.exitCode == 0 else {
            return []
        }

        let labels = list.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line
                    .split(separator: "\t")
                    .map(String.init)
                guard let label = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty else {
                    return nil
                }
                return label
            }
            .filter { $0.localizedCaseInsensitiveContains("openclaw") || $0.localizedCaseInsensitiveContains("claw") }

        let domain = launchdDomain()
        let repoPath = standardizedPath(instance.expandedRepoPath)
        var services: [LaunchdService] = []

        for label in labels {
            let printed = runLaunchctl(arguments: ["print", "\(domain)/\(label)"])
            guard printed.exitCode == 0 else {
                continue
            }

            let lowered = printed.stdout.lowercased()
            guard lowered.contains(repoPath) else {
                continue
            }

            if let plistPath = firstMatch(in: printed.stdout, pattern: #"(?m)^\s*path = (.+)$"#)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !plistPath.isEmpty {
                services.append(LaunchdService(label: label, plistPath: plistPath))
            }
        }

        return services
    }

    private func runLaunchctl(arguments: [String]) -> ProcessRunner.Result {
        ProcessRunner.run(executable: "/bin/launchctl", arguments: arguments)
    }

    private func launchdDomain() -> String {
        "gui/\(getuid())"
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}

private enum SupervisorError: LocalizedError {
    case invalidRepository(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRepository(path):
            return "项目目录缺失或不完整：\(path)"
        }
    }
}
