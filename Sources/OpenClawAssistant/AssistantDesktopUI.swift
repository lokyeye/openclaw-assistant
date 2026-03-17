import AppKit
import SwiftUI

enum AssistantRoute: Equatable {
    case overview
    case instanceDetail(String)
    case attention
    case settings
}

enum AssistantAttentionSeverity {
    case info
    case warning
    case critical

    var label: String {
        switch self {
        case .info:
            return "提醒"
        case .warning:
            return "留意"
        case .critical:
            return "异常"
        }
    }

    var color: Color {
        switch self {
        case .info:
            return Color(red: 0.33, green: 0.58, blue: 0.87)
        case .warning:
            return Color(red: 0.92, green: 0.64, blue: 0.24)
        case .critical:
            return Color(red: 0.84, green: 0.31, blue: 0.33)
        }
    }
}

struct AssistantAttentionItem: Identifiable {
    let id: String
    let severity: AssistantAttentionSeverity
    let title: String
    let summary: String
    let detail: String
    let timestamp: Date?
    let instanceID: String?
    let configURL: URL?
    let logURL: URL?
    let repoPath: String?
    let ignoredRepoPath: String?
    let launchdLabels: [String]
}

struct AssistantWorkspaceSnapshot {
    var reports: [InstanceReport]
    var configuration: AssistantConfiguration
    var attentionItems: [AssistantAttentionItem]
    var managementURLsByInstanceID: [String: URL]
    var configURLsByInstanceID: [String: URL]
    var modelSummaryByInstanceID: [String: String]
    var managedLaunchdLabelsByInstanceID: [String: [String]]
    var generatedAt: Date

    static let empty = AssistantWorkspaceSnapshot(
        reports: [],
        configuration: .default,
        attentionItems: [],
        managementURLsByInstanceID: [:],
        configURLsByInstanceID: [:],
        modelSummaryByInstanceID: [:],
        managedLaunchdLabelsByInstanceID: [:],
        generatedAt: .distantPast
    )
}

struct AssistantModelSheetState: Identifiable {
    let instanceID: String
    let catalog: OpenClawInstanceModelCatalog

    var id: String { instanceID }
}

@MainActor
final class AssistantWorkspaceActions {
    let showOverview: () -> Void
    let showAttention: () -> Void
    let showSettings: () -> Void
    let showInstanceDetail: (String) -> Void
    let refresh: () -> Void
    let startAll: () -> Void
    let stopAll: () -> Void
    let startInstance: (String) -> Void
    let restartInstance: (String) -> Void
    let stopInstance: (String) -> Void
    let removeInstance: (String) -> Void
    let openManagementPage: (String) -> Void
    let openLogFile: (String) -> Void
    let openConfigFile: (String) -> Void
    let openRepoFolder: (String) -> Void
    let openModelSheet: (String) -> Void
    let applyModelSelections: (_ instanceID: String, _ assignments: [String: String], _ restartIfRunning: Bool) -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let setAutoStartOnLaunch: (Bool) -> Void
    let setAutoRestartCrashed: (Bool) -> Void
    let fullRescan: () -> Void
    let restoreIgnoredRepoPath: (String) -> Void

    init(
        showOverview: @escaping () -> Void,
        showAttention: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        showInstanceDetail: @escaping (String) -> Void,
        refresh: @escaping () -> Void,
        startAll: @escaping () -> Void,
        stopAll: @escaping () -> Void,
        startInstance: @escaping (String) -> Void,
        restartInstance: @escaping (String) -> Void,
        stopInstance: @escaping (String) -> Void,
        removeInstance: @escaping (String) -> Void,
        openManagementPage: @escaping (String) -> Void,
        openLogFile: @escaping (String) -> Void,
        openConfigFile: @escaping (String) -> Void,
        openRepoFolder: @escaping (String) -> Void,
        openModelSheet: @escaping (String) -> Void,
        applyModelSelections: @escaping (_ instanceID: String, _ assignments: [String: String], _ restartIfRunning: Bool) -> Void,
        setLaunchAtLogin: @escaping (Bool) -> Void,
        setAutoStartOnLaunch: @escaping (Bool) -> Void,
        setAutoRestartCrashed: @escaping (Bool) -> Void,
        fullRescan: @escaping () -> Void,
        restoreIgnoredRepoPath: @escaping (String) -> Void
    ) {
        self.showOverview = showOverview
        self.showAttention = showAttention
        self.showSettings = showSettings
        self.showInstanceDetail = showInstanceDetail
        self.refresh = refresh
        self.startAll = startAll
        self.stopAll = stopAll
        self.startInstance = startInstance
        self.restartInstance = restartInstance
        self.stopInstance = stopInstance
        self.removeInstance = removeInstance
        self.openManagementPage = openManagementPage
        self.openLogFile = openLogFile
        self.openConfigFile = openConfigFile
        self.openRepoFolder = openRepoFolder
        self.openModelSheet = openModelSheet
        self.applyModelSelections = applyModelSelections
        self.setLaunchAtLogin = setLaunchAtLogin
        self.setAutoStartOnLaunch = setAutoStartOnLaunch
        self.setAutoRestartCrashed = setAutoRestartCrashed
        self.fullRescan = fullRescan
        self.restoreIgnoredRepoPath = restoreIgnoredRepoPath
    }
}

@MainActor
final class AssistantWorkspaceModel: ObservableObject {
    @Published private(set) var snapshot: AssistantWorkspaceSnapshot
    @Published var route: AssistantRoute = .overview
    @Published var selectedInstanceID: String?
    @Published var modelSheet: AssistantModelSheetState?

    let actions: AssistantWorkspaceActions

    init(actions: AssistantWorkspaceActions, snapshot: AssistantWorkspaceSnapshot = .empty) {
        self.actions = actions
        self.snapshot = snapshot
    }

    func apply(snapshot: AssistantWorkspaceSnapshot) {
        self.snapshot = snapshot
        reconcileSelection()
    }

    func show(route: AssistantRoute) {
        self.route = route
        if case let .instanceDetail(instanceID) = route {
            selectedInstanceID = instanceID
        }
        reconcileSelection()
    }

    func selectInstance(_ instanceID: String, navigateToDetail: Bool) {
        selectedInstanceID = instanceID
        if navigateToDetail {
            route = .instanceDetail(instanceID)
        }
    }

    func presentModelSheet(_ state: AssistantModelSheetState) {
        modelSheet = state
    }

    func dismissModelSheet() {
        modelSheet = nil
    }

    private func reconcileSelection() {
        let reports = snapshot.reports
        if reports.isEmpty {
            selectedInstanceID = nil
            if case .instanceDetail = route {
                route = .overview
            }
            return
        }

        if let selectedInstanceID,
           reports.contains(where: { $0.id == selectedInstanceID }) {
            return
        }

        selectedInstanceID = reports.first?.id
        if case .instanceDetail = route, let selectedInstanceID {
            route = .instanceDetail(selectedInstanceID)
        }
    }
}

@MainActor
final class AssistantWindowController: NSWindowController {
    init(model: AssistantWorkspaceModel) {
        let rootView = AssistantRootView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenClaw 小助手"
        window.setContentSize(NSSize(width: 1360, height: 900))
        window.minSize = NSSize(width: 1120, height: 760)
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reveal() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AssistantRootView: View {
    @ObservedObject var model: AssistantWorkspaceModel
    @State private var searchText = ""
    @State private var selectedAttentionID: String?

    private var filteredReports: [InstanceReport] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return model.snapshot.reports
        }

        return model.snapshot.reports.filter { report in
            report.instance.name.localizedCaseInsensitiveContains(query) ||
            report.instance.repoPath.localizedCaseInsensitiveContains(query) ||
            report.instance.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedReport: InstanceReport? {
        if let selectedInstanceID = model.selectedInstanceID,
           let report = model.snapshot.reports.first(where: { $0.id == selectedInstanceID }) {
            return report
        }
        return model.snapshot.reports.first
    }

    private var selectedAttention: AssistantAttentionItem? {
        if let selectedAttentionID,
           let item = model.snapshot.attentionItems.first(where: { $0.id == selectedAttentionID }) {
            return item
        }
        return model.snapshot.attentionItems.first
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.94, blue: 0.93),
                    Color(red: 0.97, green: 0.98, blue: 0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                header
                HStack(alignment: .top, spacing: 20) {
                    sidebar
                    routeContent
                }
            }
            .padding(24)
        }
        .sheet(item: $model.modelSheet) { state in
            AssistantModelSheet(
                state: state,
                report: model.snapshot.reports.first(where: { $0.id == state.instanceID }),
                action: model.actions.applyModelSelections,
                onDismiss: model.dismissModelSheet
            )
        }
        .preferredColorScheme(.light)
        .onAppear {
            if selectedAttentionID == nil {
                selectedAttentionID = model.snapshot.attentionItems.first?.id
            }
        }
        .onChange(of: model.snapshot.attentionItems.map(\.id)) { ids in
            guard let first = ids.first else {
                selectedAttentionID = nil
                return
            }
            if let selectedAttentionID, ids.contains(selectedAttentionID) {
                return
            }
            self.selectedAttentionID = first
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenClaw 小助手")
                    .font(.system(size: 28, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                AssistantHeaderChip(title: "总览", selected: isOverviewRoute) {
                    model.actions.showOverview()
                }
                AssistantHeaderChip(title: "提醒中心", selected: model.route == .attention) {
                    model.actions.showAttention()
                }
                AssistantHeaderChip(title: "设置", selected: model.route == .settings) {
                    model.actions.showSettings()
                }
            }

            Button("立即刷新") {
                model.actions.refresh()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var sidebar: some View {
        AssistantSurface {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("我正在替你盯着这些实例")
                        .font(.system(size: 16, weight: .semibold))
                    Text("点击左边实例可以直接进详情，常用开关和批量动作都挪到主界面里了。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                TextField("搜索实例、路径或 ID", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    AssistantMiniMetric(
                        title: "运行中",
                        value: "\(runningCount)",
                        tint: Color(red: 0.27, green: 0.66, blue: 0.43)
                    )
                    AssistantMiniMetric(
                        title: "待留意",
                        value: "\(model.snapshot.attentionItems.count)",
                        tint: Color(red: 0.87, green: 0.52, blue: 0.35)
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("实例列表")
                        .font(.system(size: 14, weight: .semibold))
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if filteredReports.isEmpty {
                                Text("没有匹配到实例")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(filteredReports, id: \.id) { report in
                                    AssistantInstanceRow(
                                        report: report,
                                        selected: model.selectedInstanceID == report.id,
                                        managementURL: model.snapshot.managementURLsByInstanceID[report.id],
                                        modelSummary: model.snapshot.modelSummaryByInstanceID[report.id],
                                        onSelect: {
                                            model.actions.showInstanceDetail(report.id)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private var routeContent: some View {
        switch model.route {
        case .overview:
            AssistantOverviewPage(
                snapshot: model.snapshot,
                selectedReport: selectedReport,
                actions: model.actions
            )
        case let .instanceDetail(instanceID):
            AssistantInstanceDetailPage(
                report: model.snapshot.reports.first(where: { $0.id == instanceID }),
                snapshot: model.snapshot,
                actions: model.actions
            )
        case .attention:
            AssistantAttentionPage(
                items: model.snapshot.attentionItems,
                selectedItem: selectedAttention,
                selectedAttentionID: $selectedAttentionID,
                actions: model.actions
            )
        case .settings:
            AssistantSettingsPage(
                snapshot: model.snapshot,
                actions: model.actions
            )
        }
    }

    private var headerSubtitle: String {
        if model.snapshot.reports.isEmpty {
            return "还没发现实例，我会继续帮你扫描。"
        }

        let attention = model.snapshot.attentionItems.count
        if attention > 0 {
            return "当前有 \(attention) 条提醒，先从需要处理的实例开始。"
        }

        return "当前共有 \(model.snapshot.reports.count) 个实例，\(runningCount) 个正在运行。"
    }

    private var runningCount: Int {
        model.snapshot.reports.filter { $0.status == .running }.count
    }

    private var isOverviewRoute: Bool {
        if case .overview = model.route {
            return true
        }
        return false
    }
}

private struct AssistantOverviewPage: View {
    let snapshot: AssistantWorkspaceSnapshot
    let selectedReport: InstanceReport?
    let actions: AssistantWorkspaceActions

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AssistantSurface {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("欢迎回来，我已经先替你把今天要看的事情排好了。")
                                .font(.system(size: 24, weight: .semibold))
                            Text("左边是所有 OpenClaw 实例，中间是整体情况，右边我给你留了当前实例最常用的动作。")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 14) {
                                AssistantStatCard(
                                    title: "正在运行",
                                    value: "\(snapshot.reports.filter { $0.status == .running }.count)/\(snapshot.reports.count)",
                                    hint: "我会持续检查运行状态",
                                    tint: Color(red: 0.42, green: 0.72, blue: 0.52)
                                )
                                AssistantStatCard(
                                    title: "需要留意",
                                    value: "\(snapshot.attentionItems.count)",
                                    hint: "崩溃、忽略规则、托管提醒",
                                    tint: Color(red: 0.93, green: 0.67, blue: 0.33)
                                )
                                AssistantStatCard(
                                    title: "自动照看",
                                    value: snapshot.configuration.autoRestartCrashedInstances ? "已开启" : "未开启",
                                    hint: "实例异常退出时自动尝试拉起",
                                    tint: Color(red: 0.62, green: 0.55, blue: 0.84)
                                )
                            }
                        }
                    }

                    AssistantSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("最近事件")
                                .font(.system(size: 18, weight: .semibold))

                            if snapshot.reports.isEmpty {
                                Text("还没有实例事件。")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(snapshot.reports.prefix(6), id: \.id) { report in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Circle()
                                                .fill(statusColor(for: report.status))
                                                .frame(width: 9, height: 9)
                                            Text(report.instance.name)
                                                .font(.system(size: 14, weight: .semibold))
                                            Spacer()
                                            Text(report.status.label)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(report.recentLogLine ?? "最近没有新的日志摘要。")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        Text("最近活动 \(Formatter.relativeString(for: report.lastActivityAt))")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }

            AssistantSurface {
                VStack(alignment: .leading, spacing: 18) {
                    Text("当前实例")
                        .font(.system(size: 18, weight: .semibold))

                    if let selectedReport {
                        AssistantSelectedInstanceCard(
                            report: selectedReport,
                            snapshot: snapshot,
                            actions: actions
                        )
                    } else {
                        Text("先在左边选一个实例，我会把常用动作放在这里。")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 360)
        }
    }
}

private struct AssistantInstanceDetailPage: View {
    let report: InstanceReport?
    let snapshot: AssistantWorkspaceSnapshot
    let actions: AssistantWorkspaceActions

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AssistantSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            if let report {
                                HStack(alignment: .center, spacing: 12) {
                                    Circle()
                                        .fill(statusColor(for: report.status))
                                        .frame(width: 12, height: 12)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(report.instance.name)
                                            .font(.system(size: 24, weight: .semibold))
                                        Text(report.status.label)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("回到总览") {
                                        actions.showOverview()
                                    }
                                }

                                HStack(spacing: 14) {
                                    AssistantDetailPill(title: "PID", value: report.displayPID)
                                    AssistantDetailPill(title: "分支", value: report.repoBranch ?? "-")
                                    AssistantDetailPill(title: "端口", value: portLabel(for: report))
                                }
                            } else {
                                Text("没找到这个实例，可能已经被移除。")
                                    .font(.system(size: 15))
                            }
                        }
                    }

                    AssistantSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("运行信息")
                                .font(.system(size: 18, weight: .semibold))

                            if let report {
                                AssistantInfoRow(label: "项目路径", value: report.instance.repoPath)
                                AssistantInfoRow(label: "启动命令", value: report.instance.startCommand.joined(separator: " "))
                                AssistantInfoRow(
                                    label: "管理页",
                                    value: snapshot.managementURLsByInstanceID[report.id]?.absoluteString ?? "未识别"
                                )
                                AssistantInfoRow(
                                    label: "模型",
                                    value: snapshot.modelSummaryByInstanceID[report.id] ?? "暂未识别"
                                )
                                AssistantInfoRow(
                                    label: "最近活动",
                                    value: Formatter.relativeString(for: report.lastActivityAt)
                                )
                            } else {
                                Text("这里会展示实例的命令、地址、配置和最近状态。")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    AssistantSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("最近日志")
                                .font(.system(size: 18, weight: .semibold))

                            if let report, let line = report.recentLogLine, !line.isEmpty {
                                Text(line)
                                    .font(.system(size: 13, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(Color(red: 0.19, green: 0.2, blue: 0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .foregroundStyle(Color.white.opacity(0.9))
                            } else {
                                Text("还没有可展示的日志摘要。")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            AssistantSurface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("我来帮你处理")
                        .font(.system(size: 18, weight: .semibold))

                    if let report {
                        actionButton(title: "打开管理页", systemImage: "safari") {
                            actions.openManagementPage(report.id)
                        }
                        .disabled(snapshot.managementURLsByInstanceID[report.id] == nil)

                        actionButton(title: "打开智能体编组…", systemImage: "sparkles") {
                            actions.openModelSheet(report.id)
                        }

                        actionButton(title: "重启实例", systemImage: "arrow.clockwise") {
                            actions.restartInstance(report.id)
                        }

                        actionButton(title: "停止实例", systemImage: "stop.fill") {
                            actions.stopInstance(report.id)
                        }

                        actionButton(title: "打开日志", systemImage: "doc.text") {
                            actions.openLogFile(report.id)
                        }

                        actionButton(title: "打开配置文件", systemImage: "slider.horizontal.3") {
                            actions.openConfigFile(report.id)
                        }

                        actionButton(title: "打开项目文件夹", systemImage: "folder") {
                            actions.openRepoFolder(report.id)
                        }

                        actionButton(title: "从列表移除", systemImage: "trash") {
                            actions.removeInstance(report.id)
                        }
                    } else {
                        Text("这里会放实例的直接操作。")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 320)
        }
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private func portLabel(for report: InstanceReport) -> String {
        snapshot.managementURLsByInstanceID[report.id]?.port.map(String.init) ?? "-"
    }
}

private struct AssistantAttentionPage: View {
    let items: [AssistantAttentionItem]
    let selectedItem: AssistantAttentionItem?
    @Binding var selectedAttentionID: String?
    let actions: AssistantWorkspaceActions

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            AssistantSurface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("提醒与异常")
                        .font(.system(size: 18, weight: .semibold))
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if items.isEmpty {
                                Text("目前没有新的提醒。")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(items) { item in
                                    Button {
                                        selectedAttentionID = item.id
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Circle()
                                                    .fill(item.severity.color)
                                                    .frame(width: 9, height: 9)
                                                Text(item.title)
                                                    .font(.system(size: 14, weight: .semibold))
                                                Spacer()
                                                Text(item.severity.label)
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text(item.summary)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(14)
                                        .background(
                                            (selectedAttentionID == item.id ? Color.white.opacity(0.92) : Color.white.opacity(0.72)),
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 360)

            AssistantSurface {
                VStack(alignment: .leading, spacing: 16) {
                    if let selectedItem {
                        HStack {
                            Circle()
                                .fill(selectedItem.severity.color)
                                .frame(width: 11, height: 11)
                            Text(selectedItem.title)
                                .font(.system(size: 22, weight: .semibold))
                        }

                        Text(selectedItem.detail)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)

                        if let timestamp = selectedItem.timestamp {
                            Text("最近发生在 \(Formatter.relativeString(for: timestamp))")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            if let instanceID = selectedItem.instanceID {
                                Button("打开实例详情") {
                                    actions.showInstanceDetail(instanceID)
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if let configURL = selectedItem.configURL {
                                Button("打开配置文件") {
                                    NSWorkspace.shared.open(configURL)
                                }
                                .buttonStyle(.bordered)
                            }

                            if let logURL = selectedItem.logURL {
                                Button("打开日志") {
                                    if !FileManager.default.fileExists(atPath: logURL.path) {
                                        FileManager.default.createFile(atPath: logURL.path, contents: nil)
                                    }
                                    NSWorkspace.shared.open(logURL)
                                }
                                .buttonStyle(.bordered)
                            }

                            if let repoPath = selectedItem.repoPath, let instanceID = selectedItem.instanceID {
                                Button("打开项目文件夹") {
                                    _ = repoPath
                                    actions.openRepoFolder(instanceID)
                                }
                                .buttonStyle(.bordered)
                            }

                            if let ignoredRepoPath = selectedItem.ignoredRepoPath {
                                Button("恢复到自动发现列表") {
                                    actions.restoreIgnoredRepoPath(ignoredRepoPath)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        if !selectedItem.launchdLabels.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text("托管服务")
                                    .font(.system(size: 14, weight: .semibold))
                                ForEach(selectedItem.launchdLabels, id: \.self) { label in
                                    Text(label)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text("选一条提醒，我把原因和可操作入口放到这里。")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AssistantSettingsPage: View {
    let snapshot: AssistantWorkspaceSnapshot
    let actions: AssistantWorkspaceActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AssistantSurface {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("通用与启动")
                            .font(.system(size: 20, weight: .semibold))

                        Toggle("开机自动启动小助手", isOn: Binding(
                            get: { snapshot.configuration.launchAtLogin },
                            set: { actions.setLaunchAtLogin($0) }
                        ))

                        Toggle("打开小助手时自动启动 OpenClaw", isOn: Binding(
                            get: { snapshot.configuration.autoStartInstancesOnLaunch },
                            set: { actions.setAutoStartOnLaunch($0) }
                        ))

                        Toggle("实例崩溃后自动重新拉起", isOn: Binding(
                            get: { snapshot.configuration.autoRestartCrashedInstances },
                            set: { actions.setAutoRestartCrashed($0) }
                        ))
                    }
                }

                AssistantSurface {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("自动发现规则")
                            .font(.system(size: 20, weight: .semibold))

                        HStack(spacing: 12) {
                            Button("全量扫描仓库") {
                                actions.fullRescan()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("刷新当前列表") {
                                actions.refresh()
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("忽略列表里的仓库平时不会自动扫回来，只有手动恢复或执行全量扫描时才会重新进入视野。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                AssistantSurface {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("忽略与恢复")
                            .font(.system(size: 20, weight: .semibold))

                        if snapshot.configuration.ignoredRepoPaths.isEmpty {
                            Text("当前没有被忽略的仓库。")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(snapshot.configuration.ignoredRepoPaths, id: \.self) { path in
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(path)
                                            .font(.system(size: 13, design: .monospaced))
                                        Text("恢复后它会重新参与自动发现。")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("恢复") {
                                        actions.restoreIgnoredRepoPath(path)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(14)
                                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AssistantModelSheet: View {
    private enum SheetStage {
        case board
        case search
        case review
    }

    private enum SearchScope: CaseIterable, Identifiable {
        case all
        case openAI
        case bailian
        case routed
        case local
        case recent

        var id: Self { self }

        var title: String {
            switch self {
            case .all:
                return "全部来源"
            case .openAI:
                return "OpenAI 系列"
            case .bailian:
                return "百炼 / Bailian"
            case .routed:
                return "DashScope / SiliconFlow"
            case .local:
                return "本地 / 私有 / 其他"
            case .recent:
                return "最近使用"
            }
        }

        var subtitle: String {
            switch self {
            case .all:
                return "先把当前实例识别到的所有供应商都收进来。"
            case .openAI:
                return "gpt-* 和 codex 这类 OpenAI 系列模型。"
            case .bailian:
                return "glm、qwen、MiniMax 等百炼托管模型。"
            case .routed:
                return "第三方代理到 Qwen 或国产模型。"
            case .local:
                return "Ollama、LM Studio、私有 provider。"
            case .recent:
                return "优先看当前已经在用的模型。"
            }
        }
    }

    private enum ModelSourceGroup: CaseIterable, Identifiable {
        case openAI
        case bailian
        case routed
        case local

        var id: Self { self }

        var title: String {
            switch self {
            case .openAI:
                return "OpenAI 系列"
            case .bailian:
                return "百炼 / Bailian"
            case .routed:
                return "DashScope / SiliconFlow"
            case .local:
                return "本地 / 私有 / 其他"
            }
        }

        var hint: String {
            switch self {
            case .openAI:
                return "把 openai/gpt-* 和 openai-codex/* 这类 OpenAI 模型放一起，卡内可继续下滚。"
            case .bailian:
                return "把 Bailian 托管的 glm、qwen、MiniMax 系列放一起，卡内可继续下滚。"
            case .routed:
                return "把第三方代理到 Qwen 或国产模型的通路放一起，卡内可继续下滚。"
            case .local:
                return "把 Ollama、本地、私有 provider 和特殊设备模型放一起，卡内可继续下滚。"
            }
        }
    }

    private struct ReviewRow: Identifiable {
        let id: String
        let agentName: String
        let fromModelID: String
        let toModelID: String
        let summary: String
        let statusTitle: String
        let statusTint: Color
        let statusBackground: Color
    }

    let state: AssistantModelSheetState
    let report: InstanceReport?
    let action: (_ instanceID: String, _ assignments: [String: String], _ restartIfRunning: Bool) -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stage: SheetStage = .board
    @State private var selectedAgentID: String
    @State private var draftModelIDs: [String: String]
    @State private var searchText = ""
    @State private var searchScope: SearchScope = .all
    @State private var lastEditedAgentID: String?
    @State private var lastEditedModelID: String?
    private let minimumSheetSize = NSSize(width: 1040, height: 720)
    private let idealSheetSize = NSSize(width: 1280, height: 820)

    init(
        state: AssistantModelSheetState,
        report: InstanceReport?,
        action: @escaping (_ instanceID: String, _ assignments: [String: String], _ restartIfRunning: Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.state = state
        self.report = report
        self.action = action
        self.onDismiss = onDismiss

        let initialAgent = state.catalog.agents.first
        let initialDrafts = Dictionary(
            uniqueKeysWithValues: state.catalog.agents.map { agent in
                (agent.agentID, agent.currentModelID ?? agent.availableModels.first?.id ?? "")
            }
        )
        _selectedAgentID = State(initialValue: initialAgent?.agentID ?? "")
        _draftModelIDs = State(initialValue: initialDrafts)
        _lastEditedAgentID = State(initialValue: initialAgent?.agentID)
        _lastEditedModelID = State(initialValue: initialAgent?.currentModelID)
    }

    private var instanceName: String {
        report?.instance.name ?? "实例"
    }

    private var selectedAgent: OpenClawAgentModelInfo? {
        state.catalog.agents.first(where: { $0.agentID == selectedAgentID }) ?? state.catalog.agents.first
    }

    private var originalModelIDs: [String: String] {
        Dictionary(
            uniqueKeysWithValues: state.catalog.agents.map { agent in
                (agent.agentID, agent.currentModelID ?? "")
            }
        )
    }

    private var pendingAssignments: [String: String] {
        draftModelIDs.filter { agentID, modelID in
            originalModelIDs[agentID] != modelID && !modelID.isEmpty
        }
    }

    private var pendingChangeCount: Int {
        pendingAssignments.count
    }

    private var allOptions: [OpenClawModelOption] {
        var deduped: [String: OpenClawModelOption] = [:]
        for agent in state.catalog.agents {
            for option in agent.availableModels {
                deduped[option.id] = deduped[option.id] ?? option
            }
            if let currentModelID = agent.currentModelID, deduped[currentModelID] == nil {
                deduped[currentModelID] = OpenClawModelOption(id: currentModelID, name: nil)
            }
        }

        return deduped.values.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    private var isRunning: Bool {
        report?.status == .running || report?.status == .starting
    }

    private var boardSections: [(ModelSourceGroup, [OpenClawModelOption])] {
        ModelSourceGroup.allCases.map { group in
            (group, providerOptions(for: group))
        }
    }

    private var filteredSearchOptions: [OpenClawModelOption] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return allOptions.filter { option in
            guard matchesSearchScope(option, scope: searchScope) else {
                return false
            }

            guard !trimmedQuery.isEmpty else {
                return true
            }

            let haystack = [
                option.id,
                option.name ?? "",
                sourceGroup(for: option).title,
                sourceGroup(for: option).hint
            ]
            .joined(separator: " ")

            return haystack.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var reviewRows: [ReviewRow] {
        state.catalog.agents.compactMap { agent in
            guard let toModelID = pendingAssignments[agent.agentID] else {
                return nil
            }

            let fromModelID = agent.currentModelID ?? "未设置模型"
            let summary: String
            if fromModelID == toModelID {
                summary = "模型不变，主要更新来源分组归类。"
            } else {
                summary = "\(fromModelID) → \(toModelID)"
            }

            let statusTitle: String
            let statusTint: Color
            let statusBackground: Color
            if isRunning {
                statusTitle = "运行中，应用后重启"
                statusTint = Color(red: 0.43, green: 0.29, blue: 0.08)
                statusBackground = Color(red: 0.99, green: 0.94, blue: 0.83)
            } else {
                statusTitle = "离线实例，只写配置"
                statusTint = Color(red: 0.18, green: 0.42, blue: 0.26)
                statusBackground = Color(red: 0.92, green: 0.97, blue: 0.93)
            }

            return ReviewRow(
                id: agent.agentID,
                agentName: agent.displayName,
                fromModelID: fromModelID,
                toModelID: toModelID,
                summary: summary,
                statusTitle: statusTitle,
                statusTint: statusTint,
                statusBackground: statusBackground
            )
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            VStack(alignment: .leading, spacing: 18) {
                header(
                    compact: size.width < 1220,
                    stackedControls: size.width < 980
                )

                if let lastEditedAgentID,
                   let lastEditedModelID,
                   let agent = state.catalog.agents.first(where: { $0.agentID == lastEditedAgentID }) {
                    dragFocusStrip(
                        agent: agent,
                        modelID: lastEditedModelID,
                        stacked: size.width < 980
                    )
                }

                stageContent(for: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.95, blue: 0.93),
                        Color(red: 0.95, green: 0.98, blue: 0.94)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(
            minWidth: minimumSheetSize.width,
            idealWidth: idealSheetSize.width,
            minHeight: minimumSheetSize.height,
            idealHeight: idealSheetSize.height
        )
        .background(
            AssistantWindowConfigurator(
                minSize: minimumSheetSize,
                idealSize: idealSheetSize
            )
        )
    }

    @ViewBuilder
    private func header(compact: Bool, stackedControls: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stageTitle)
                        .font(.system(size: 24, weight: .semibold))
                    Text(stageSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if stackedControls {
                    VStack(alignment: .leading, spacing: 10) {
                        stageSwitcher
                        HStack(spacing: 8) {
                            if pendingChangeCount > 0 {
                                pendingChangeBadge
                            }
                            Button("打开配置文件") {
                                NSWorkspace.shared.open(state.catalog.configURL)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        stageSwitcher
                        Spacer(minLength: 0)
                        if pendingChangeCount > 0 {
                            pendingChangeBadge
                        }
                        Button("打开配置文件") {
                            NSWorkspace.shared.open(state.catalog.configURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stageTitle)
                        .font(.system(size: 24, weight: .semibold))
                    Text(stageSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    stageSwitcher

                    if pendingChangeCount > 0 {
                        pendingChangeBadge
                    }

                    Button("打开配置文件") {
                        NSWorkspace.shared.open(state.catalog.configURL)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func stageContent(for size: CGSize) -> some View {
        switch stage {
        case .board:
            boardStage(size: size)
        case .search:
            searchStage(size: size)
        case .review:
            reviewStage(size: size)
        }
    }

    @ViewBuilder
    private func boardStage(size: CGSize) -> some View {
        let stacksVertically = size.width < 1180
        let sidebarWidth = min(max(250, size.width * 0.23), 300)
        let libraryWidth = stacksVertically ? size.width : max(0, size.width - sidebarWidth - 18)
        let libraryHeight = max(420, size.height - 160)

        if stacksVertically {
            VStack(alignment: .leading, spacing: 18) {
                agentColumn(showSearchHint: false)
                    .frame(maxWidth: .infinity)
                boardLibraryContent(availableWidth: libraryWidth)
                    .frame(maxWidth: .infinity, minHeight: libraryHeight, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HStack(alignment: .top, spacing: 18) {
                agentColumn(showSearchHint: false)
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                boardLibraryContent(availableWidth: libraryWidth)
                    .frame(maxWidth: .infinity, minHeight: libraryHeight, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func boardLibraryContent(availableWidth: CGFloat) -> some View {
        let compact = availableWidth < 980
        let cardHeight = sourceGroupCardHeight(for: availableWidth)

        return AssistantSurface {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("我先按模型来源把它们收成 4 个模型库了。")
                        .font(.system(size: 20, weight: .semibold))
                    Text("不是按用途分组，而是按 OpenAI、百炼、代理线路、本地这些来源来放。每个来源卡内部也能独立上下滚动，看更多模型。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if pendingChangeCount > 0 {
                    stagedChangePanel(availableWidth: availableWidth)
                }

                ScrollView {
                    LazyVGrid(
                        columns: boardGridColumns(for: availableWidth),
                        spacing: 12
                    ) {
                        ForEach(boardSections, id: \.0.id) { section in
                            sourceGroupCard(
                                group: section.0,
                                options: section.1,
                                compact: compact,
                                cardHeight: cardHeight
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                boardFooter(availableWidth: availableWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func searchStage(size: CGSize) -> some View {
        let stacksVertically = size.width < 1180
        let filtersWidth = min(max(240, size.width * 0.22), 280)
        let resultsWidth = stacksVertically ? size.width : max(0, size.width - filtersWidth - 18)

        if stacksVertically {
            VStack(alignment: .leading, spacing: 18) {
                searchFiltersPanel
                searchResultsPanel(availableWidth: resultsWidth)
            }
        } else {
            HStack(alignment: .top, spacing: 18) {
                searchFiltersPanel
                    .frame(width: filtersWidth)
                searchResultsPanel(availableWidth: resultsWidth)
            }
        }
    }

    private var searchFiltersPanel: some View {
        AssistantSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("筛选条件")
                    .font(.system(size: 16, weight: .semibold))

                ForEach(SearchScope.allCases) { scope in
                    Button {
                        searchScope = scope
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scope.title)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.primary)
                            Text(scopeLabel(for: scope))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            (searchScope == scope ? Color(red: 0.9, green: 0.97, blue: 0.9) : Color.white.opacity(0.72)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
    }

    private func searchResultsPanel(availableWidth: CGFloat) -> some View {
        AssistantSurface {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("当前操作智能体")
                        .font(.system(size: 14, weight: .semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(state.catalog.agents, id: \.agentID) { agent in
                                Button {
                                    selectedAgentID = agent.agentID
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(agent.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                        Text(displayedModelTitle(for: agent))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        (selectedAgentID == agent.agentID ? Color.white.opacity(0.94) : Color.white.opacity(0.72)),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                TextField("搜索模型名、供应商或系列关键词", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    searchChip(title: "OpenAI", tint: Color(red: 0.97, green: 0.94, blue: 0.83))
                    searchChip(title: "百炼", tint: Color(red: 0.92, green: 0.97, blue: 0.93))
                    searchChip(title: "本地", tint: Color(red: 0.94, green: 0.95, blue: 0.98))
                }

                ScrollView {
                    LazyVGrid(
                        columns: searchGridColumns(for: availableWidth),
                        spacing: 12
                    ) {
                        ForEach(filteredSearchOptions, id: \.id) { option in
                            searchResultCard(option)
                        }
                    }
                }

                searchFooter(availableWidth: availableWidth)
            }
        }
    }

    private func reviewStage(size: CGSize) -> some View {
        AssistantSurface {
            VStack(alignment: .leading, spacing: 16) {
                reviewSummarySection(availableWidth: size.width)

                if reviewRows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("这一轮还没有暂存变更。")
                            .font(.system(size: 16, weight: .semibold))
                        Text("先回到编组面板拖一轮，或者在搜索页点几个模型进来，我再帮你复核。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(reviewRows) { row in
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(row.agentName)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(row.summary)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(row.statusTitle)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(row.statusTint)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(row.statusBackground, in: Capsule(style: .continuous))
                                }
                                .padding(14)
                                .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                }

                reviewFooter(availableWidth: size.width)
            }
        }
    }

    private func agentColumn(showSearchHint: Bool) -> some View {
        AssistantSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("智能体仓")
                    .font(.system(size: 16, weight: .semibold))
                Text(showSearchHint ? "先选一个智能体，再把搜索结果带回编组。" : "左边挑智能体，或直接拖去右侧模型框。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(state.catalog.agents, id: \.agentID) { agent in
                            Button {
                                selectedAgentID = agent.agentID
                                lastEditedAgentID = agent.agentID
                                lastEditedModelID = draftModelIDs[agent.agentID] ?? agent.currentModelID
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(agent.displayName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                        Spacer()
                                        if pendingAssignments[agent.agentID] != nil {
                                            Text("待应用")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(Color(red: 0.74, green: 0.42, blue: 0.2))
                                        }
                                    }
                                    Text(displayedModelTitle(for: agent))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(
                                    (selectedAgentID == agent.agentID ? Color(red: 0.9, green: 0.97, blue: 0.9) : Color.white.opacity(0.72)),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .draggable(agent.agentID)
                        }
                    }
                }
            }
        }
    }

    private func stagedChangePanel(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本轮暂存变更 · \(pendingChangeCount) 项")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("你可以继续拖，最后再统一应用。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: stagedChangeColumns(for: availableWidth), spacing: 10) {
                ForEach(reviewRows.prefix(3)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.agentName) → \(row.toModelID)")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(row.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.98, green: 0.97, blue: 0.93), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func dragFocusStrip(agent: OpenClawAgentModelInfo, modelID: String, stacked: Bool) -> some View {
        let sourcePill = HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.83, green: 0.54, blue: 0.2))
                .frame(width: 10, height: 10)
            Text("拖拽中 · \(agent.displayName)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.29, blue: 0.13))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.99, green: 0.94, blue: 0.83), in: Capsule(style: .continuous))

        let targetPill = HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.28, green: 0.58, blue: 0.36))
                .frame(width: 10, height: 10)
            Text("目标 · \(modelID)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.26))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.92, green: 0.97, blue: 0.93), in: Capsule(style: .continuous))

        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    sourcePill
                    targetPill
                }
            } else {
                HStack(spacing: 10) {
                    sourcePill

                    Text("→")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)

                    targetPill
                }
            }
        }
    }

    private func sourceGroupCard(group: ModelSourceGroup, options: [OpenClawModelOption], compact: Bool, cardHeight: CGFloat) -> some View {
        let scrollHeight = max(compact ? 142 : 118, cardHeight - (compact ? 118 : 124))

        return VStack(alignment: .leading, spacing: 10) {
            Text(group.title)
                .font(.system(size: 16, weight: .semibold))
            Text(group.hint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这个来源下暂时还没有识别到模型。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("去搜索更多模型") {
                        stage = .search
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ForEach(options, id: \.id) { option in
                            boardTile(option, group: group)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: scrollHeight)

                Text("卡内可继续上下滚动查看更多")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(
            maxWidth: .infinity,
            minHeight: cardHeight,
            maxHeight: cardHeight,
            alignment: .topLeading
        )
        .background(Color.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func boardTile(_ model: OpenClawModelOption, group: ModelSourceGroup) -> some View {
        let isSelected = draftModelIDs[selectedAgentID] == model.id
        let assignedAgents = assignedAgents(for: model.id)

        return Button {
            assign(modelID: model.id, to: selectedAgentID)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.id)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(modelSubtitle(for: model, group: group))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.42, green: 0.72, blue: 0.52))
                    }
                }

                if assignedAgents.isEmpty {
                    Text("点击分配给当前智能体，或把左侧智能体拖到这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(assignedAgents.prefix(2), id: \.agentID) { agent in
                            Text(agent.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.9), in: Capsule(style: .continuous))
                        }
                        if assignedAgents.count > 2 {
                            Text("+\(assignedAgents.count - 2)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(14)
            .background(
                (isSelected ? Color(red: 0.9, green: 0.97, blue: 0.9) : Color.white.opacity(0.78)),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            guard let agentID = items.first else {
                return false
            }
            assign(modelID: model.id, to: agentID)
            return true
        }
    }

    private func searchResultCard(_ option: OpenClawModelOption) -> some View {
        let isSelected = draftModelIDs[selectedAgentID] == option.id
        let group = sourceGroup(for: option)
        let assignedAgents = assignedAgents(for: option.id)

        return Button {
            assign(modelID: option.id, to: selectedAgentID)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(option.id)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(searchResultSubtitle(for: option))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isSelected {
                        Text("已暂存到 \(selectedAgent?.displayName ?? "当前智能体")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.26))
                    }
                }

                if !assignedAgents.isEmpty {
                    Text("当前已编组：\(assignedAgents.map(\.displayName).joined(separator: "、"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
            .padding(14)
            .background(
                (isSelected ? Color(red: 0.9, green: 0.97, blue: 0.9) : Color.white.opacity(0.82)),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func reviewSummaryCard(title: String, value: String, tint: Color, foreground: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.72))
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stageButton(title: String, active: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    active ? Color.white.opacity(0.94) : Color.white.opacity(0.58),
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func searchChip(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint, in: Capsule(style: .continuous))
    }

    private var stageTitle: String {
        switch stage {
        case .board:
            return "\(instanceName) 智能体 / 模型 编组"
        case .search:
            return "搜索 / 筛选 模型"
        case .review:
            return "应用前复核"
        }
    }

    private var stageSubtitle: String {
        switch stage {
        case .board:
            return state.catalog.configURL.path
        case .search:
            return "先按模型来源 / 系列收窄范围，再把候选带回编组面板。"
        case .review:
            return "先看清这轮会影响哪些智能体，再决定保存还是应用并重启。"
        }
    }

    private func scopeLabel(for scope: SearchScope) -> String {
        if scope == .all {
            return "当前显示 \(filteredCount(for: scope)) 个可选项"
        }
        return scope.subtitle
    }

    private var stageSwitcher: some View {
        HStack(spacing: 8) {
            stageButton(title: "编组", active: stage == .board) {
                stage = .board
            }
            stageButton(title: "搜索", active: stage == .search) {
                stage = .search
            }
            stageButton(title: "复核", active: stage == .review, enabled: pendingChangeCount > 0) {
                stage = .review
            }
        }
    }

    private var pendingChangeBadge: some View {
        Text("已暂存 \(pendingChangeCount) 项")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(red: 0.98, green: 0.91, blue: 0.76), in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private func boardFooter(availableWidth: CGFloat) -> some View {
        if availableWidth < 980 {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    isRunning
                    ? "当前实例正在运行。你可以继续拖放和暂存，最后再统一应用并重启。"
                    : "当前实例未运行。你可以先把这轮编组都排好，最后只保存配置。"
                )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if pendingChangeCount > 0 {
                        Button("还原暂存") {
                            resetDrafts()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("搜索更多模型") {
                        stage = .search
                    }
                    .buttonStyle(.bordered)
                    Button("前往复核") {
                        stage = .review
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingChangeCount == 0)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                Text(
                    isRunning
                    ? "当前实例正在运行。你可以继续拖放和暂存，最后再统一应用并重启。"
                    : "当前实例未运行。你可以先把这轮编组都排好，最后只保存配置。"
                )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                Spacer()
                if pendingChangeCount > 0 {
                    Button("还原暂存") {
                        resetDrafts()
                    }
                    .buttonStyle(.bordered)
                }
                Button("搜索更多模型") {
                    stage = .search
                }
                .buttonStyle(.bordered)
                Button("前往复核") {
                    stage = .review
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingChangeCount == 0)
            }
        }
    }

    @ViewBuilder
    private func searchFooter(availableWidth: CGFloat) -> some View {
        if availableWidth < 980 {
            VStack(alignment: .leading, spacing: 12) {
                Text("已帮你按来源缩小范围。点卡片就会把模型暂存到当前智能体，然后你可以带回编组面板继续拖放。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("回到编组") {
                        stage = .board
                    }
                    .buttonStyle(.bordered)
                    Button("去复核这轮变更") {
                        stage = .review
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingChangeCount == 0)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                Text("已帮你按来源缩小范围。点卡片就会把模型暂存到当前智能体，然后你可以带回编组面板继续拖放。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("回到编组") {
                    stage = .board
                }
                .buttonStyle(.bordered)
                Button("去复核这轮变更") {
                    stage = .review
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingChangeCount == 0)
            }
        }
    }

    private func reviewSummarySection(availableWidth: CGFloat) -> some View {
        LazyVGrid(columns: reviewSummaryColumns(for: availableWidth), spacing: 12) {
            reviewSummaryCard(
                title: "本轮变更",
                value: "\(pendingChangeCount) 个智能体",
                tint: Color.white,
                foreground: .primary
            )
            reviewSummaryCard(
                title: "实例状态",
                value: isRunning ? "当前实例运行中" : "当前实例离线",
                tint: Color(red: 0.99, green: 0.94, blue: 0.83),
                foreground: Color(red: 0.43, green: 0.29, blue: 0.08)
            )
            reviewSummaryCard(
                title: "保存方式",
                value: isRunning ? "可保存，或应用后重启" : "只会写配置，不会启动",
                tint: Color(red: 0.92, green: 0.97, blue: 0.93),
                foreground: Color(red: 0.18, green: 0.42, blue: 0.26)
            )
        }
    }

    @ViewBuilder
    private func reviewFooter(availableWidth: CGFloat) -> some View {
        if availableWidth < 980 {
            VStack(alignment: .leading, spacing: 12) {
                Text("如果你现在点应用并重启，正在运行的实例会按这轮配置重新拉起。离线实例只会写入配置。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("回到面板继续调") {
                        stage = .board
                    }
                    .buttonStyle(.bordered)
                    Button("只保存这轮") {
                        apply(restartIfRunning: false)
                    }
                    .buttonStyle(.bordered)
                    .disabled(pendingChangeCount == 0)
                    Button("应用并重启实例") {
                        apply(restartIfRunning: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isRunning || pendingChangeCount == 0)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                Text("如果你现在点应用并重启，正在运行的实例会按这轮配置重新拉起。离线实例只会写入配置。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("回到面板继续调") {
                    stage = .board
                }
                .buttonStyle(.bordered)
                Button("只保存这轮") {
                    apply(restartIfRunning: false)
                }
                .buttonStyle(.bordered)
                .disabled(pendingChangeCount == 0)
                Button("应用并重启实例") {
                    apply(restartIfRunning: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isRunning || pendingChangeCount == 0)
            }
        }
    }

    private func boardGridColumns(for availableWidth: CGFloat) -> [GridItem] {
        let columnCount: Int
        switch availableWidth {
        case ..<760:
            columnCount = 1
        case ..<1040:
            columnCount = 2
        default:
            columnCount = 4
        }

        return Array(
            repeating: GridItem(.flexible(minimum: 180), spacing: 12, alignment: .top),
            count: columnCount
        )
    }

    private func sourceGroupCardHeight(for availableWidth: CGFloat) -> CGFloat {
        switch availableWidth {
        case ..<760:
            return 300
        case ..<1040:
            return 340
        case ..<1380:
            return 360
        default:
            return 400
        }
    }

    private func searchGridColumns(for availableWidth: CGFloat) -> [GridItem] {
        let columnCount: Int
        switch availableWidth {
        case ..<780:
            columnCount = 1
        case ..<1180:
            columnCount = 2
        default:
            columnCount = 3
        }

        return Array(repeating: GridItem(.flexible(minimum: 220, maximum: 420), spacing: 12), count: columnCount)
    }

    private func stagedChangeColumns(for availableWidth: CGFloat) -> [GridItem] {
        let columnCount: Int
        switch availableWidth {
        case ..<760:
            columnCount = 1
        case ..<1080:
            columnCount = 2
        default:
            columnCount = 3
        }

        return Array(repeating: GridItem(.flexible(minimum: 180, maximum: 360), spacing: 10), count: columnCount)
    }

    private func reviewSummaryColumns(for availableWidth: CGFloat) -> [GridItem] {
        let columnCount: Int
        switch availableWidth {
        case ..<820:
            columnCount = 1
        case ..<1220:
            columnCount = 2
        default:
            columnCount = 3
        }

        return Array(repeating: GridItem(.flexible(minimum: 220, maximum: 420), spacing: 12), count: columnCount)
    }

    private func filteredCount(for scope: SearchScope) -> Int {
        allOptions.filter { matchesSearchScope($0, scope: scope) }.count
    }

    private func matchesSearchScope(_ option: OpenClawModelOption, scope: SearchScope) -> Bool {
        switch scope {
        case .all:
            return true
        case .openAI:
            return sourceGroup(for: option) == .openAI
        case .bailian:
            return sourceGroup(for: option) == .bailian
        case .routed:
            return sourceGroup(for: option) == .routed
        case .local:
            return sourceGroup(for: option) == .local
        case .recent:
            return Set(originalModelIDs.values).contains(option.id)
        }
    }

    private func sourceGroup(for option: OpenClawModelOption) -> ModelSourceGroup {
        let provider = option.id.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        let haystack = "\(option.id) \(option.name ?? "")".lowercased()

        switch provider {
        case "openai":
            return .openAI
        case "openai-codex":
            return .openAI
        case "bailian":
            return .bailian
        case "dashscope", "siliconflow":
            return .routed
        case "ollama", "win-handheld":
            return .local
        default:
            if haystack.contains("ollama") || haystack.contains("lm studio") || haystack.contains("local") {
                return .local
            }
            return .local
        }
    }

    private func providerOptions(for group: ModelSourceGroup) -> [OpenClawModelOption] {
        let assignedIDs = Set(draftModelIDs.values)
        let currentIDs = Set(originalModelIDs.values)
        return allOptions
            .filter { sourceGroup(for: $0) == group }
            .sorted { lhs, rhs in
                let lhsAssigned = assignedIDs.contains(lhs.id)
                let rhsAssigned = assignedIDs.contains(rhs.id)
                if lhsAssigned != rhsAssigned {
                    return lhsAssigned
                }

                let lhsCurrent = currentIDs.contains(lhs.id)
                let rhsCurrent = currentIDs.contains(rhs.id)
                if lhsCurrent != rhsCurrent {
                    return lhsCurrent
                }

                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    private func assignedAgents(for modelID: String) -> [OpenClawAgentModelInfo] {
        state.catalog.agents.filter { draftModelIDs[$0.agentID] == modelID }
    }

    private func displayedModelTitle(for agent: OpenClawAgentModelInfo) -> String {
        let modelID = draftModelIDs[agent.agentID] ?? agent.currentModelID ?? "未设置模型"
        return modelID.isEmpty ? "未设置模型" : modelID
    }

    private func modelSubtitle(for model: OpenClawModelOption, group: ModelSourceGroup) -> String {
        if let name = model.name, !name.isEmpty {
            return name
        }
        return group.hint
    }

    private func searchResultSubtitle(for option: OpenClawModelOption) -> String {
        if let name = option.name, !name.isEmpty {
            return name
        }
        return sourceGroup(for: option).hint
    }

    private func assign(modelID: String, to agentID: String) {
        guard !agentID.isEmpty else {
            return
        }

        draftModelIDs[agentID] = modelID
        selectedAgentID = agentID
        lastEditedAgentID = agentID
        lastEditedModelID = modelID
    }

    private func resetDrafts() {
        draftModelIDs = originalModelIDs
        if let first = state.catalog.agents.first?.agentID {
            selectedAgentID = first
            lastEditedAgentID = first
            lastEditedModelID = originalModelIDs[first]
        } else {
            lastEditedAgentID = nil
            lastEditedModelID = nil
        }
    }

    private func apply(restartIfRunning: Bool) {
        guard !pendingAssignments.isEmpty else {
            return
        }

        action(state.instanceID, pendingAssignments, restartIfRunning)
        close()
    }

    private func close() {
        onDismiss()
        dismiss()
    }
}

private struct AssistantWindowConfigurator: NSViewRepresentable {
    let minSize: NSSize
    let idealSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindowIfNeeded(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindowIfNeeded(for: nsView)
        }
    }

    private func configureWindowIfNeeded(for view: NSView) {
        guard let window = view.window else {
            return
        }

        window.styleMask.insert(.resizable)
        window.minSize = minSize

        let currentSize = window.frame.size
        if currentSize.width < minSize.width || currentSize.height < minSize.height {
            let targetWidth = max(max(currentSize.width, idealSize.width), minSize.width)
            let targetHeight = max(max(currentSize.height, idealSize.height), minSize.height)
            window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        }
    }
}

private struct AssistantSelectedInstanceCard: View {
    let report: InstanceReport
    let snapshot: AssistantWorkspaceSnapshot
    let actions: AssistantWorkspaceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(for: report.status))
                    .frame(width: 11, height: 11)
                Text(report.instance.name)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(report.status.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            AssistantInfoRow(label: "管理页", value: snapshot.managementURLsByInstanceID[report.id]?.absoluteString ?? "未识别")
            AssistantInfoRow(label: "模型", value: snapshot.modelSummaryByInstanceID[report.id] ?? "暂未识别")
            AssistantInfoRow(label: "最近日志", value: report.recentLogLine ?? "还没有日志摘要")

            HStack(spacing: 10) {
                Button("启动") {
                    actions.startInstance(report.id)
                }
                .buttonStyle(.borderedProminent)

                Button("重启") {
                    actions.restartInstance(report.id)
                }
                .buttonStyle(.bordered)

                Button("停止") {
                    actions.stopInstance(report.id)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 10) {
                Button("打开管理页") {
                    actions.openManagementPage(report.id)
                }
                .buttonStyle(.bordered)
                .disabled(snapshot.managementURLsByInstanceID[report.id] == nil)

                Button("打开智能体编组…") {
                    actions.openModelSheet(report.id)
                }
                .buttonStyle(.bordered)

                Button("查看实例详情") {
                    actions.showInstanceDetail(report.id)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct AssistantInstanceRow: View {
    let report: InstanceReport
    let selected: Bool
    let managementURL: URL?
    let modelSummary: String?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(statusColor(for: report.status))
                        .frame(width: 10, height: 10)
                    Text(report.instance.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text(report.status.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text((managementURL?.port).map { "端口 \($0)" } ?? "端口未识别")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(modelSummary ?? profileLabel(for: report.instance))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (selected ? Color.white.opacity(0.95) : Color.white.opacity(0.72)),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func profileLabel(for instance: OpenClawInstance) -> String {
        if let profileIndex = instance.startCommand.firstIndex(of: "--profile"),
           instance.startCommand.indices.contains(profileIndex + 1) {
            return "profile \(instance.startCommand[profileIndex + 1])"
        }
        if let profile = instance.env["OPENCLAW_PROFILE"], !profile.isEmpty {
            return "profile \(profile)"
        }
        return "默认配置"
    }
}

private struct AssistantHeaderChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    selected ? Color.white.opacity(0.94) : Color.white.opacity(0.56),
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct AssistantSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.62))
                .shadow(color: Color.black.opacity(0.05), radius: 18, x: 0, y: 12)
        )
    }
}

private struct AssistantStatCard: View {
    let title: String
    let value: String
    let hint: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold))
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AssistantMiniMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AssistantInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13))
        }
    }
}

private struct AssistantDetailPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.76), in: Capsule(style: .continuous))
    }
}

private func statusColor(for status: InstanceStatus) -> Color {
    switch status {
    case .running, .starting:
        return Color(red: 0.31, green: 0.73, blue: 0.44)
    case .stopped:
        return Color(red: 0.88, green: 0.44, blue: 0.41)
    case .crashed:
        return Color(red: 0.82, green: 0.28, blue: 0.33)
    case .missingProject:
        return Color(red: 0.91, green: 0.65, blue: 0.24)
    case .disabled:
        return Color(red: 0.55, green: 0.55, blue: 0.58)
    }
}
