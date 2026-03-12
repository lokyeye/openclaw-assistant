import Foundation

enum AssistantCLI {
    private struct SettingsPayload: Codable {
        let launchAtLogin: Bool
        let launchAtLoginRegistered: Bool
        let autoStartInstancesOnLaunch: Bool
        let autoRestartCrashedInstances: Bool
    }

    private struct StatusCounts: Codable {
        let total: Int
        let running: Int
        let starting: Int
        let stopped: Int
        let crashed: Int
        let missingProject: Int
        let disabled: Int
    }

    private struct StatusInstance: Codable {
        let id: String
        let name: String
        let status: String
        let statusLabel: String
        let pid: Int32?
        let observedPIDs: [Int32]
        let repoPath: String
        let repoExists: Bool
        let repoBranch: String?
        let disabled: Bool
        let notes: String?
        let lastActivityAt: Date?
        let recentLogLine: String?
        let logFilePath: String
    }

    private struct StatusPayload: Codable {
        let generatedAt: Date
        let supportDirectory: String
        let configPath: String
        let ignoredRepoPaths: [String]
        let runtimePath: String
        let settings: SettingsPayload
        let counts: StatusCounts
        let instances: [StatusInstance]
    }

    private struct ActionPayload: Codable {
        let ok: Bool
        let action: String
        let target: String
        let generatedAt: Date
        let counts: StatusCounts
        let instances: [StatusInstance]
    }

    static func run(arguments: [String]) -> Int32 {
        let store = ConfigurationStore()

        do {
            try store.bootstrapIfNeeded()
        } catch {
            return fail("初始化失败: \(error.localizedDescription)")
        }

        let supervisor = InstanceSupervisor(store: store)
        guard let command = arguments.first else {
            printUsage()
            return 0
        }

        let remaining = Array(arguments.dropFirst())

        do {
            switch command {
            case "help", "--help", "-h":
                printUsage()
                return 0
            case "status", "list":
                return try runStatus(arguments: remaining, store: store, supervisor: supervisor)
            case "settings":
                return runSettings(store: store)
            case "start":
                return try runInstanceAction(
                    action: "start",
                    arguments: remaining,
                    store: store,
                    supervisor: supervisor
                ) { target in
                    try supervisor.start(instanceID: target)
                }
            case "stop":
                return try runInstanceAction(
                    action: "stop",
                    arguments: remaining,
                    store: store,
                    supervisor: supervisor
                ) { target in
                    try supervisor.stop(instanceID: target)
                }
            case "restart":
                return try runInstanceAction(
                    action: "restart",
                    arguments: remaining,
                    store: store,
                    supervisor: supervisor
                ) { target in
                    try supervisor.restart(instanceID: target)
                }
            case "start-all":
                try supervisor.startAll()
                return emitActionResult(
                    action: "start-all",
                    target: "all",
                    store: store,
                    supervisor: supervisor
                )
            case "stop-all":
                try supervisor.stopAll()
                return emitActionResult(
                    action: "stop-all",
                    target: "all",
                    store: store,
                    supervisor: supervisor
                )
            case "restart-all":
                try supervisor.restartAll()
                return emitActionResult(
                    action: "restart-all",
                    target: "all",
                    store: store,
                    supervisor: supervisor
                )
            case "remove":
                return try runRemove(arguments: remaining, store: store, supervisor: supervisor)
            case "full-scan":
                try store.fullRescan()
                return emitActionResult(
                    action: "full-scan",
                    target: "all",
                    store: store,
                    supervisor: supervisor
                )
            case "set":
                return try runSet(arguments: remaining, store: store)
            case "paths":
                return emitJSON(
                    [
                        "supportDirectory": store.supportDirectory.path,
                        "configPath": store.configURL.path,
                        "runtimePath": store.runtimeURL.path,
                    ]
                )
            default:
                return fail("不支持的命令: \(command)\n\n\(usageText)")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func runStatus(
        arguments: [String],
        store: ConfigurationStore,
        supervisor: InstanceSupervisor
    ) throws -> Int32 {
        let target = arguments.first(where: { !$0.hasPrefix("-") })
        let reports = supervisor.reports()
        let filtered = try filteredReports(for: target, in: reports)

        let payload = StatusPayload(
            generatedAt: Date(),
            supportDirectory: store.supportDirectory.path,
            configPath: store.configURL.path,
            ignoredRepoPaths: store.loadConfiguration().ignoredRepoPaths,
            runtimePath: store.runtimeURL.path,
            settings: makeSettingsPayload(from: store.loadConfiguration()),
            counts: makeCounts(from: filtered),
            instances: filtered.map(makeStatusInstance)
        )
        return emitJSON(payload)
    }

    private static func runSettings(store: ConfigurationStore) -> Int32 {
        emitJSON(makeSettingsPayload(from: store.loadConfiguration()))
    }

    private static func runInstanceAction(
        action: String,
        arguments: [String],
        store: ConfigurationStore,
        supervisor: InstanceSupervisor,
        perform: (String) throws -> Void
    ) throws -> Int32 {
        guard let target = arguments.first else {
            return fail("缺少实例 ID。\n\n\(usageText)")
        }

        let configuration = store.loadConfiguration()
        guard configuration.instances.contains(where: { $0.id == target }) else {
            return fail("未找到实例: \(target)")
        }

        try perform(target)
        return emitActionResult(
            action: action,
            target: target,
            store: store,
            supervisor: supervisor
        )
    }

    private static func emitActionResult(
        action: String,
        target: String,
        store: ConfigurationStore,
        supervisor: InstanceSupervisor
    ) -> Int32 {
        let reports = supervisor.reports()
        let instances = target == "all"
            ? reports
            : reports.filter { $0.instance.id == target }

        let payload = ActionPayload(
            ok: true,
            action: action,
            target: target,
            generatedAt: Date(),
            counts: makeCounts(from: reports),
            instances: instances.map(makeStatusInstance)
        )
        return emitJSON(payload)
    }

    private static func runRemove(
        arguments: [String],
        store: ConfigurationStore,
        supervisor: InstanceSupervisor
    ) throws -> Int32 {
        guard let target = arguments.first else {
            return fail("缺少实例 ID。\n\n\(usageText)")
        }

        try store.removeInstance(instanceID: target)
        return emitActionResult(
            action: "remove",
            target: target,
            store: store,
            supervisor: supervisor
        )
    }

    private static func runSet(
        arguments: [String],
        store: ConfigurationStore
    ) throws -> Int32 {
        guard arguments.count >= 2 else {
            return fail("用法: OpenClawAssistant set <launch-at-login|auto-start-on-launch|auto-restart-crashed> <on|off>")
        }

        let key = arguments[0]
        let value = try parseBooleanSetting(arguments[1])
        guard isSupportedSettingKey(key) else {
            return fail("不支持的设置项: \(key)")
        }

        let configuration = try store.updateConfiguration { configuration in
            switch key {
            case "launch-at-login":
                configuration.launchAtLogin = value
            case "auto-start-on-launch":
                configuration.autoStartInstancesOnLaunch = value
            case "auto-restart-crashed":
                configuration.autoRestartCrashedInstances = value
            default:
                break
            }
        }

        switch key {
        case "launch-at-login":
            try LaunchAtLoginManager.sync(enabled: value)
        case "auto-start-on-launch", "auto-restart-crashed":
            break
        default:
            break
        }

        return emitJSON(makeSettingsPayload(from: configuration))
    }

    private static func filteredReports(
        for target: String?,
        in reports: [InstanceReport]
    ) throws -> [InstanceReport] {
        guard let target else {
            return reports
        }

        let filtered = reports.filter { $0.instance.id == target }
        if filtered.isEmpty {
            throw CLIError.message("未找到实例: \(target)")
        }
        return filtered
    }

    private static func makeCounts(from reports: [InstanceReport]) -> StatusCounts {
        StatusCounts(
            total: reports.count,
            running: reports.filter { $0.status == .running }.count,
            starting: reports.filter { $0.status == .starting }.count,
            stopped: reports.filter { $0.status == .stopped }.count,
            crashed: reports.filter { $0.status == .crashed }.count,
            missingProject: reports.filter { $0.status == .missingProject }.count,
            disabled: reports.filter { $0.status == .disabled }.count
        )
    }

    private static func makeSettingsPayload(from configuration: AssistantConfiguration) -> SettingsPayload {
        SettingsPayload(
            launchAtLogin: configuration.launchAtLogin,
            launchAtLoginRegistered: LaunchAtLoginManager.isEnabled,
            autoStartInstancesOnLaunch: configuration.autoStartInstancesOnLaunch,
            autoRestartCrashedInstances: configuration.autoRestartCrashedInstances
        )
    }

    private static func makeStatusInstance(from report: InstanceReport) -> StatusInstance {
        StatusInstance(
            id: report.instance.id,
            name: report.instance.name,
            status: report.status.rawValue,
            statusLabel: report.status.label,
            pid: report.observedPIDs.first ?? report.runtime.pid,
            observedPIDs: report.observedPIDs,
            repoPath: report.instance.expandedRepoPath,
            repoExists: report.repoExists,
            repoBranch: report.repoBranch,
            disabled: report.instance.disabled,
            notes: report.instance.notes,
            lastActivityAt: report.lastActivityAt,
            recentLogLine: report.recentLogLine,
            logFilePath: report.logFileURL.path
        )
    }

    private static func emitJSON<T: Encodable>(_ value: T) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(value)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
                return 0
            }
            return fail("无法生成 UTF-8 输出")
        } catch {
            return fail("输出 JSON 失败: \(error.localizedDescription)")
        }
    }

    private static func printUsage() {
        print(usageText)
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func parseBooleanSetting(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "true", "1", "yes":
            return true
        case "off", "false", "0", "no":
            return false
        default:
            throw CLIError.message("设置值只能是 on 或 off。")
        }
    }

    private static func isSupportedSettingKey(_ key: String) -> Bool {
        ["launch-at-login", "auto-start-on-launch", "auto-restart-crashed"].contains(key)
    }

    private static let usageText = """
    OpenClawAssistant CLI

    用法:
      OpenClawAssistant status [instance-id]
      OpenClawAssistant settings
      OpenClawAssistant start <instance-id>
      OpenClawAssistant stop <instance-id>
      OpenClawAssistant restart <instance-id>
      OpenClawAssistant remove <instance-id>
      OpenClawAssistant start-all
      OpenClawAssistant stop-all
      OpenClawAssistant restart-all
      OpenClawAssistant full-scan
      OpenClawAssistant set <launch-at-login|auto-start-on-launch|auto-restart-crashed> <on|off>
      OpenClawAssistant paths

    示例:
      OpenClawAssistant status
      OpenClawAssistant settings
      OpenClawAssistant status nexus-link
      OpenClawAssistant start openclawcn
      OpenClawAssistant remove openclawcn
      OpenClawAssistant full-scan
      OpenClawAssistant set launch-at-login on
      OpenClawAssistant restart-all
    """

    private enum CLIError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case let .message(text):
                return text
            }
        }
    }
}
