import Foundation

struct AssistantConfiguration: Codable {
    var refreshIntervalSeconds: Double
    var instances: [OpenClawInstance]
    var ignoredRepoPaths: [String]
    var launchAtLogin: Bool
    var autoStartInstancesOnLaunch: Bool
    var autoRestartCrashedInstances: Bool

    init(
        refreshIntervalSeconds: Double,
        instances: [OpenClawInstance],
        ignoredRepoPaths: [String] = [],
        launchAtLogin: Bool = false,
        autoStartInstancesOnLaunch: Bool = false,
        autoRestartCrashedInstances: Bool = false
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.instances = instances
        self.ignoredRepoPaths = ignoredRepoPaths
        self.launchAtLogin = launchAtLogin
        self.autoStartInstancesOnLaunch = autoStartInstancesOnLaunch
        self.autoRestartCrashedInstances = autoRestartCrashedInstances
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds
        case instances
        case ignoredRepoPaths
        case launchAtLogin
        case autoStartInstancesOnLaunch
        case autoRestartCrashedInstances
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? 3
        instances = try container.decodeIfPresent([OpenClawInstance].self, forKey: .instances) ?? []
        ignoredRepoPaths = try container.decodeIfPresent([String].self, forKey: .ignoredRepoPaths) ?? []
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        autoStartInstancesOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoStartInstancesOnLaunch) ?? false
        autoRestartCrashedInstances = try container.decodeIfPresent(Bool.self, forKey: .autoRestartCrashedInstances) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try container.encode(instances, forKey: .instances)
        try container.encode(ignoredRepoPaths, forKey: .ignoredRepoPaths)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(autoStartInstancesOnLaunch, forKey: .autoStartInstancesOnLaunch)
        try container.encode(autoRestartCrashedInstances, forKey: .autoRestartCrashedInstances)
    }

    static let `default` = AssistantConfiguration(
        refreshIntervalSeconds: 3,
        instances: [],
        ignoredRepoPaths: [],
        launchAtLogin: false,
        autoStartInstancesOnLaunch: false,
        autoRestartCrashedInstances: false
    )
}

struct OpenClawInstance: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var repoPath: String
    var startCommand: [String]
    var processMatch: [String]
    var activityPaths: [String]
    var env: [String: String]
    var notes: String?
    var disabled: Bool

    var expandedRepoPath: String {
        PathExpander.expand(repoPath)
    }
}

struct RuntimeState: Codable {
    var instances: [String: InstanceRuntimeState]

    static let empty = RuntimeState(instances: [:])
}

struct InstanceRuntimeState: Codable {
    var pid: Int32?
    var lastStartedAt: Date?
    var lastStoppedAt: Date?
    var lastCrashedAt: Date?
    var lastExitCode: Int32?
    var lastStopWasManual: Bool

    static let empty = InstanceRuntimeState(
        pid: nil,
        lastStartedAt: nil,
        lastStoppedAt: nil,
        lastCrashedAt: nil,
        lastExitCode: nil,
        lastStopWasManual: false
    )
}

enum InstanceStatus: String {
    case running
    case starting
    case stopped
    case crashed
    case missingProject
    case disabled

    var label: String {
        switch self {
        case .running:
            return "运行中"
        case .starting:
            return "启动中"
        case .stopped:
            return "已停止"
        case .crashed:
            return "已崩溃"
        case .missingProject:
            return "项目缺失"
        case .disabled:
            return "已禁用"
        }
    }
}

struct InstanceReport: Identifiable {
    var id: String { instance.id }
    let instance: OpenClawInstance
    let runtime: InstanceRuntimeState
    let status: InstanceStatus
    let observedPIDs: [Int32]
    let repoExists: Bool
    let repoBranch: String?
    let lastActivityAt: Date?
    let recentLogLine: String?
    let logFileURL: URL

    var displayPID: String {
        if let first = observedPIDs.first {
            return String(first)
        }
        if let pid = runtime.pid {
            return String(pid)
        }
        return "-"
    }
}
