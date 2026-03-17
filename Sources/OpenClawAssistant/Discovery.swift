import Foundation

enum OpenClawDiscovery {
    static func discoverDefaultInstances(
        ignoredRepoPaths: [String] = [],
        includeIgnored: Bool = false
    ) -> [OpenClawInstance] {
        discoverInstances(
            existing: [],
            ignoredRepoPaths: ignoredRepoPaths,
            includeIgnored: includeIgnored
        )
    }

    static func refreshAutoDiscoveredInstances(_ instances: [OpenClawInstance]) -> [OpenClawInstance] {
        instances.map { instance in
            guard instance.notes?.contains("自动发现。") == true else {
                return instance
            }

            let repoPath = PathExpander.expand(instance.repoPath)
            let repoURL = URL(fileURLWithPath: repoPath)
            let packageURL = repoURL.appendingPathComponent("package.json")
            guard packageName(for: packageURL) != nil || FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("openclaw.mjs").path) else {
                return instance
            }

            var refreshed = makeInstance(
                id: instance.id,
                name: defaultName(for: repoURL),
                repoPath: repoPath,
                preserving: instance
            )
            refreshed.disabled = instance.disabled
            return refreshed
        }
    }

    static func discoverAdditionalInstances(
        existing: [OpenClawInstance],
        ignoredRepoPaths: [String],
        includeIgnored: Bool = false
    ) -> [OpenClawInstance] {
        discoverInstances(
            existing: existing,
            ignoredRepoPaths: ignoredRepoPaths,
            includeIgnored: includeIgnored
        )
    }

    private static func discoverInstances(
        existing: [OpenClawInstance],
        ignoredRepoPaths: [String],
        includeIgnored: Bool
    ) -> [OpenClawInstance] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        var reservedIDs = Set(existing.map(\.id))
        let existingPaths = Set(existing.map { standardizedPath(PathExpander.expand($0.repoPath)) })
        let ignoredPaths = Set(ignoredRepoPaths.map(standardizedPath))

        var discovered: [OpenClawInstance] = []
        var seenPaths: Set<String> = []

        for repoPath in candidateRepoURLs(in: desktop) {
            let normalizedRepoPath = standardizedPath(repoPath.path)
            guard !existingPaths.contains(normalizedRepoPath) else { continue }
            guard includeIgnored || !ignoredPaths.contains(normalizedRepoPath) else { continue }
            guard seenPaths.insert(normalizedRepoPath).inserted else { continue }
            let packageURL = repoPath.appendingPathComponent("package.json")
            guard let packageName = packageName(for: packageURL) else { continue }
            guard ["openclaw", "openclaw-cn"].contains(packageName) || FileManager.default.fileExists(atPath: repoPath.appendingPathComponent("openclaw.mjs").path) else {
                continue
            }

            let name = defaultName(for: repoPath)
            let id = makeUniqueID(
                name: name,
                packageName: packageName,
                repoPath: repoPath.path,
                reservedIDs: &reservedIDs
            )
            let instance = makeInstance(
                id: id,
                name: name,
                repoPath: repoPath.path,
                preserving: nil
            )
            discovered.append(instance)
        }

        if discovered.isEmpty {
            for candidate in fallbackCandidates(in: home) {
                let normalizedCandidatePath = standardizedPath(candidate.path)
                guard !existingPaths.contains(normalizedCandidatePath) else { continue }
                guard includeIgnored || !ignoredPaths.contains(normalizedCandidatePath) else { continue }
                guard seenPaths.insert(normalizedCandidatePath).inserted else { continue }
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                let name = defaultName(for: candidate)
                let packageURL = candidate.appendingPathComponent("package.json")
                let packageName = packageName(for: packageURL) ?? candidate.lastPathComponent
                let id = makeUniqueID(
                    name: name,
                    packageName: packageName,
                    repoPath: candidate.path,
                    reservedIDs: &reservedIDs
                )
                discovered.append(makeInstance(id: id, name: name, repoPath: candidate.path, preserving: nil))
            }
        }

        return discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func candidateRepoURLs(in desktop: URL) -> [URL] {
        guard let desktopChildren = try? FileManager.default.contentsOfDirectory(
            at: desktop,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for child in desktopChildren {
            guard isDirectory(child) else { continue }
            candidates.append(child)
            candidates.append(child.appendingPathComponent("openclaw", isDirectory: true))
            candidates.append(child.appendingPathComponent("openclaw-cn", isDirectory: true))
        }

        return candidates.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("package.json").path) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func packageName(for packageURL: URL) -> String? {
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            return nil
        }
        return name
    }

    private static func defaultName(for repoURL: URL) -> String {
        if repoURL.lastPathComponent == "openclaw" {
            return repoURL.deletingLastPathComponent().lastPathComponent
        }
        return repoURL.lastPathComponent
    }

    private static func makeInstance(
        id: String,
        name: String,
        repoPath: String,
        preserving existing: OpenClawInstance?
    ) -> OpenClawInstance {
        let repoURL = URL(fileURLWithPath: repoPath)
        let defaultCommand = defaultStartCommand(for: repoURL)
        let launchPreset = inferredLaunchPreset(for: repoURL)

        let shouldPreserveLaunchSettings =
            launchPreset == nil &&
            existing.map { hasCustomLaunchConfiguration($0, defaultCommand: defaultCommand) } == true

        let startCommand =
            shouldPreserveLaunchSettings
                ? (existing?.startCommand ?? defaultCommand)
                : (launchPreset?.startCommand ?? defaultCommand)
        let environment =
            shouldPreserveLaunchSettings
                ? (existing?.env ?? [:])
                : (launchPreset?.environment ?? [:])
        let noteSuffix: String?
        if shouldPreserveLaunchSettings, let existing, let notes = existing.notes, !notes.isEmpty {
            noteSuffix = nil
        } else {
            noteSuffix = launchPreset?.note
        }
        let notes = shouldPreserveLaunchSettings
            ? existing?.notes ?? [
                "自动发现。",
                "沿用上次记录的启动参数。",
                "必要时请手动补充 activityPaths 或自定义启动参数。"
            ]
            .joined(separator: " ")
            : [
                "自动发现。",
                noteSuffix,
                "必要时请手动补充 activityPaths 或自定义启动参数。"
            ]
            .compactMap { $0 }
            .joined(separator: " ")

        return OpenClawInstance(
            id: id,
            name: name,
            repoPath: repoPath,
            startCommand: startCommand,
            processMatch: existing?.processMatch ?? ["OPENCLAW_ASSISTANT_INSTANCE_ID=\(id)"],
            activityPaths: existing?.activityPaths ?? ["~/.openclaw/logs", "~/.openclaw/agents"],
            env: environment,
            notes: notes,
            disabled: existing?.disabled ?? false
        )
    }

    private static func defaultStartCommand(for repoURL: URL) -> [String] {
        let runNodePath = repoURL.appendingPathComponent("scripts/run-node.mjs").path
        return FileManager.default.fileExists(atPath: runNodePath)
            ? ["node", "scripts/run-node.mjs", "gateway", "run"]
            : ["pnpm", "start"]
    }

    private static func hasCustomLaunchConfiguration(
        _ instance: OpenClawInstance,
        defaultCommand: [String]
    ) -> Bool {
        !instance.env.isEmpty || instance.startCommand != defaultCommand
    }

    private static func makeUniqueID(
        name: String,
        packageName: String,
        repoPath: String,
        reservedIDs: inout Set<String>
    ) -> String {
        let candidates = [
            slugify(name),
            slugify(packageName),
            "instance-\(shortStableHash(for: repoPath))",
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            if reservedIDs.insert(candidate).inserted {
                return candidate
            }
        }

        var index = 2
        while true {
            let fallback = "instance-\(shortStableHash(for: repoPath))-\(index)"
            if reservedIDs.insert(fallback).inserted {
                return fallback
            }
            index += 1
        }
    }

    private static func fallbackCandidates(in home: URL) -> [URL] {
        [
            home.appendingPathComponent("Desktop/openclaw"),
            home.appendingPathComponent("Desktop/openclaw-cn"),
            home.appendingPathComponent("Desktop/OpenclawCn"),
            home.appendingPathComponent("Desktop/openclaw-china"),
        ]
    }

    private static func slugify(_ value: String) -> String {
        let direct = normalizedSlug(value)
        if !direct.isEmpty {
            return direct
        }

        let transliterated = value
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? ""
        let latin = normalizedSlug(transliterated)
        if !latin.isEmpty {
            return latin
        }

        return ""
    }

    private static func normalizedSlug(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func inferredLaunchPreset(
        for repoURL: URL
    ) -> (startCommand: [String], environment: [String: String], note: String?)? {
        if let runningPreset = inferredLaunchPresetFromRunningProcess(for: repoURL) {
            return runningPreset
        }

        let environmentPreset = inferredLaunchPresetFromEnvironment(for: repoURL)
        if var scriptPreset = inferredLaunchPresetFromScript(for: repoURL) {
            if let environmentPreset,
               let port = environmentPreset.environment["OPENCLAW_GATEWAY_PORT"] {
                scriptPreset.environment["OPENCLAW_GATEWAY_PORT"] = port
                scriptPreset.startCommand = commandBySettingPort(scriptPreset.startCommand, port: port)
                if let note = scriptPreset.note {
                    scriptPreset.note = note + " 已从 .env 覆盖网关端口。"
                }
            }
            return scriptPreset
        }

        return environmentPreset
    }

    private static func inferredLaunchPresetFromScript(
        for repoURL: URL
    ) -> (startCommand: [String], environment: [String: String], note: String?)? {
        guard let launchScriptURL = findLaunchScript(in: repoURL),
              let script = try? String(contentsOf: launchScriptURL, encoding: .utf8),
              script.contains("scripts/run-node.mjs") else {
            return nil
        }

        let profile = firstMatch(in: script, pattern: #"PROFILE_NAME="([^"]+)""#)
            ?? firstMatch(in: script, pattern: #"--profile\s+([A-Za-z0-9._-]+)"#)
        let port = firstMatch(in: script, pattern: #"OPENCLAW_PORT:-([0-9]+)"#)
            ?? firstMatch(in: script, pattern: #"OPENCLAW_GATEWAY_PORT:-([0-9]+)"#)
            ?? firstMatch(in: script, pattern: #"--port\s+([0-9]+)"#)

        var command = ["node", "scripts/run-node.mjs"]
        if let profile, !profile.isEmpty {
            command.append(contentsOf: ["--profile", profile])
        }
        command.append("gateway")
        if let port, !port.isEmpty {
            command.append(contentsOf: ["--port", port])
            if script.contains("--verbose") {
                command.append("--verbose")
            }
        } else {
            command.append("run")
        }

        var environment: [String: String] = [:]
        if script.contains("CLAWDBOT_TS_COMPILER") {
            environment["CLAWDBOT_TS_COMPILER"] = "tsc"
        }
        if let port, !port.isEmpty, script.contains("OPENCLAW_GATEWAY_PORT") {
            environment["OPENCLAW_GATEWAY_PORT"] = port
        }

        return (
            startCommand: command,
            environment: environment,
            note: "已从 \(launchScriptURL.lastPathComponent) 推断启动参数。"
        )
    }

    private static func inferredLaunchPresetFromEnvironment(
        for repoURL: URL
    ) -> (startCommand: [String], environment: [String: String], note: String?)? {
        let envURLs = [
            repoURL.appendingPathComponent(".env"),
            repoURL.appendingPathComponent(".env.local"),
        ]

        for envURL in envURLs {
            guard let environment = parseEnvironmentFile(at: envURL) else {
                continue
            }

            let rawPort = environment["OPENCLAW_GATEWAY_PORT"] ?? environment["OPENCLAW_PORT"]
            guard let rawPort,
                  let port = Int(rawPort),
                  port > 0 else {
                continue
            }

            var startCommand = defaultStartCommand(for: repoURL)
            startCommand = commandBySettingPort(startCommand, port: String(port))

            var inferredEnvironment: [String: String] = [:]
            inferredEnvironment["OPENCLAW_GATEWAY_PORT"] = String(port)
            if let profile = environment["CLAWDBOT_PROFILE"] ?? environment["OPENCLAW_PROFILE"],
               !profile.isEmpty {
                startCommand = commandBySettingProfile(startCommand, profile: profile)
            }

            return (
                startCommand: startCommand,
                environment: inferredEnvironment,
                note: "已从 \(envURL.lastPathComponent) 推断网关端口。"
            )
        }

        return nil
    }

    private static func inferredLaunchPresetFromRunningProcess(
        for repoURL: URL
    ) -> (startCommand: [String], environment: [String: String], note: String?)? {
        let repoPath = standardizedPath(repoURL.path)
        let psOutput = ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,command="]
        ).stdout

        let candidates = psOutput
            .split(separator: "\n")
            .compactMap { parseObservedProcess(from: String($0)) }
            .filter { process in
                let lowered = process.command.lowercased()
                return lowered.contains("gateway") || lowered.contains("openclaw") || lowered.contains("clawdbot")
            }
            .filter { process in
                processMatchesRepository(process, repoPath: repoPath)
            }
            .sorted { lhs, rhs in
                processPriority(lhs.command) > processPriority(rhs.command)
            }

        for process in candidates {
            if let preset = launchPreset(fromRunningCommand: process.command) {
                return (
                    startCommand: preset.startCommand,
                    environment: preset.environment,
                    note: "已从当前运行中的 OpenClaw 进程推断启动参数。"
                )
            }
        }

        return nil
    }

    private static func findLaunchScript(in repoURL: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: repoURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = children
            .filter { $0.pathExtension == "command" || $0.lastPathComponent.hasSuffix(".sh") }
            .sorted { lhs, rhs in
                let lhsPriority = launchScriptPriority(for: lhs)
                let rhsPriority = launchScriptPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }

        for candidate in candidates {
            guard let script = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            if script.contains("scripts/run-node.mjs") {
                return candidate
            }
        }

        return nil
    }

    private static func launchScriptPriority(for url: URL) -> Int {
        if url.pathExtension == "command" {
            return 0
        }
        if url.lastPathComponent.contains("openclaw") {
            return 1
        }
        return 2
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
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

    private static func commandBySettingPort(_ command: [String], port: String) -> [String] {
        var updated = command
        if let portIndex = updated.firstIndex(of: "--port") {
            if updated.indices.contains(portIndex + 1) {
                updated[portIndex + 1] = port
            } else {
                updated.append(port)
            }
            return updated
        }

        updated.append(contentsOf: ["--port", port])
        return updated
    }

    private static func commandBySettingProfile(_ command: [String], profile: String) -> [String] {
        var updated = command
        if let profileIndex = updated.firstIndex(of: "--profile") {
            if updated.indices.contains(profileIndex + 1) {
                updated[profileIndex + 1] = profile
            } else {
                updated.append(profile)
            }
            return updated
        }

        if let gatewayIndex = updated.firstIndex(of: "gateway") {
            updated.insert(contentsOf: ["--profile", profile], at: gatewayIndex)
            return updated
        }

        updated.append(contentsOf: ["--profile", profile])
        return updated
    }

    private static func parseEnvironmentFile(at url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else {
                continue
            }
            values[key] = value
        }

        return values.isEmpty ? nil : values
    }

    private static func parseObservedProcess(from line: String) -> (pid: Int32, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let splitIndex = trimmed.firstIndex(where: \.isWhitespace),
              let pid = Int32(trimmed[..<splitIndex]) else {
            return nil
        }

        let command = trimmed[splitIndex...].trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            return nil
        }

        return (pid: pid, command: command)
    }

    private static func processMatchesRepository(
        _ process: (pid: Int32, command: String),
        repoPath: String
    ) -> Bool {
        let command = process.command.lowercased()
        if command.contains(repoPath) {
            return true
        }

        if let currentDirectory = processCurrentDirectory(pid: process.pid),
           currentDirectory == repoPath {
            return true
        }

        return processTextReferences(pid: process.pid).contains { reference in
            reference == repoPath || reference.hasPrefix("\(repoPath)/")
        }
    }

    private static func processCurrentDirectory(pid: Int32) -> String? {
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
            .map { standardizedPath(String($0.dropFirst())) }
    }

    private static func processTextReferences(pid: Int32) -> [String] {
        let result = ProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-d", "txt", "-p", String(pid), "-Fn"]
        )
        guard result.exitCode == 0 else {
            return []
        }

        return result.stdout
            .split(separator: "\n")
            .filter { $0.hasPrefix("n") }
            .map { standardizedPath(String($0.dropFirst())) }
    }

    private static func processPriority(_ command: String) -> Int {
        var priority = 0
        if command.contains("scripts/run-node.mjs") {
            priority += 10
        }
        if command.contains("--profile") {
            priority += 4
        }
        if command.contains("--port") {
            priority += 4
        }
        if command.contains("--verbose") {
            priority += 1
        }
        return priority
    }

    private static func launchPreset(
        fromRunningCommand command: String
    ) -> (startCommand: [String], environment: [String: String])? {
        guard command.contains("scripts/run-node.mjs") else {
            return nil
        }

        var startCommand = ["node", "scripts/run-node.mjs"]

        if command.contains(" --dev") {
            startCommand.append("--dev")
        }
        if let profile = firstMatch(in: command, pattern: #"--profile(?:=|\s+)([A-Za-z0-9._-]+)"#) {
            startCommand.append(contentsOf: ["--profile", profile])
        }

        startCommand.append("gateway")
        if command.contains(" gateway run") {
            startCommand.append("run")
        }

        if let bind = firstMatch(in: command, pattern: #"--bind(?:=|\s+)([A-Za-z0-9._-]+)"#) {
            startCommand.append(contentsOf: ["--bind", bind])
        }
        if let port = firstMatch(in: command, pattern: #"--port(?:=|\s+)(\d+)"#) {
            startCommand.append(contentsOf: ["--port", port])

            return (
                startCommand: appendKnownFlags(to: startCommand, from: command),
                environment: ["OPENCLAW_GATEWAY_PORT": port]
            )
        }

        return (
            startCommand: appendKnownFlags(to: startCommand, from: command),
            environment: [:]
        )
    }

    private static func appendKnownFlags(to command: [String], from source: String) -> [String] {
        var updated = command
        for flag in ["--verbose", "--force", "--allow-unconfigured"] where source.contains(flag) {
            updated.append(flag)
        }
        return updated
    }

    private static func shortStableHash(for value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%08llx", hash & 0xffff_ffff)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }
}
