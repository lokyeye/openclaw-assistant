import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    @MainActor
    private final class AgentModelPickerController: NSObject {
        let catalog: OpenClawInstanceModelCatalog
        let view: NSView
        let agentPopup: NSPopUpButton
        let modelPopup: NSPopUpButton
        private let hintLabel: NSTextField

        init(catalog: OpenClawInstanceModelCatalog) {
            self.catalog = catalog

            let view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 112))
            let agentLabel = NSTextField(labelWithString: "智能体")
            agentLabel.frame = NSRect(x: 0, y: 82, width: 80, height: 20)

            let agentPopup = NSPopUpButton(frame: NSRect(x: 88, y: 78, width: 342, height: 26), pullsDown: false)
            let modelLabel = NSTextField(labelWithString: "模型")
            modelLabel.frame = NSRect(x: 0, y: 42, width: 80, height: 20)

            let modelPopup = NSPopUpButton(frame: NSRect(x: 88, y: 38, width: 342, height: 26), pullsDown: false)
            let hintLabel = NSTextField(labelWithString: "")
            hintLabel.frame = NSRect(x: 0, y: 0, width: 430, height: 30)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.lineBreakMode = .byTruncatingMiddle

            self.view = view
            self.agentPopup = agentPopup
            self.modelPopup = modelPopup
            self.hintLabel = hintLabel

            super.init()

            agentPopup.target = self
            agentPopup.action = #selector(agentSelectionDidChange(_:))

            view.addSubview(agentLabel)
            view.addSubview(agentPopup)
            view.addSubview(modelLabel)
            view.addSubview(modelPopup)
            view.addSubview(hintLabel)

            reloadAgentPopup()
            reloadModelPopup()
            hintLabel.stringValue = catalog.configURL.path
        }

        var selectedAgent: OpenClawAgentModelInfo? {
            let index = agentPopup.indexOfSelectedItem
            guard catalog.agents.indices.contains(index) else {
                return nil
            }
            return catalog.agents[index]
        }

        var selectedModelID: String? {
            modelPopup.selectedItem?.representedObject as? String
        }

        @objc private func agentSelectionDidChange(_ sender: NSPopUpButton) {
            reloadModelPopup()
        }

        private func reloadAgentPopup() {
            agentPopup.removeAllItems()
            for agent in catalog.agents {
                agentPopup.addItem(withTitle: agent.displayName)
            }
            if !catalog.agents.isEmpty {
                agentPopup.selectItem(at: 0)
            }
        }

        private func reloadModelPopup() {
            modelPopup.removeAllItems()
            guard let agent = selectedAgent else {
                return
            }

            for option in agent.availableModels {
                modelPopup.addItem(withTitle: option.displayTitle)
                modelPopup.lastItem?.representedObject = option.id
            }

            if let currentModelID = agent.currentModelID,
               let index = agent.availableModels.firstIndex(where: { $0.id == currentModelID }) {
                modelPopup.selectItem(at: index)
            } else if !agent.availableModels.isEmpty {
                modelPopup.selectItem(at: 0)
            }
        }
    }

    private struct CrashGuidance {
        let summary: String
        let suggestion: String?
        let configFileURL: URL?
    }

    private struct CachedModelCatalog {
        let configURL: URL
        let modifiedAt: Date?
        let catalog: OpenClawInstanceModelCatalog
        let summary: String
    }

    private struct CachedLaunchdLabels {
        let labels: [String]
        let fetchedAt: Date
    }

    private let store = ConfigurationStore()
    private lazy var supervisor = InstanceSupervisor(store: store)
    private let agentModelManager = AgentModelManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var workspaceActions = AssistantWorkspaceActions(
        showOverview: { [weak self] in
            self?.showMainWindow(route: .overview)
        },
        showAttention: { [weak self] in
            self?.showMainWindow(route: .attention)
        },
        showSettings: { [weak self] in
            self?.showMainWindow(route: .settings)
        },
        showInstanceDetail: { [weak self] instanceID in
            self?.showMainWindow(route: .instanceDetail(instanceID))
        },
        refresh: { [weak self] in
            self?.refreshNow()
        },
        startAll: { [weak self] in
            self?.startAllInstances()
        },
        stopAll: { [weak self] in
            self?.stopAllInstances()
        },
        startInstance: { [weak self] instanceID in
            self?.startInstance(withID: instanceID)
        },
        restartInstance: { [weak self] instanceID in
            self?.restartInstance(withID: instanceID)
        },
        stopInstance: { [weak self] instanceID in
            self?.stopInstance(withID: instanceID)
        },
        removeInstance: { [weak self] instanceID in
            self?.removeInstance(withID: instanceID)
        },
        openManagementPage: { [weak self] instanceID in
            self?.openManagementPage(forInstanceID: instanceID)
        },
        openLogFile: { [weak self] instanceID in
            self?.openLogFile(forInstanceID: instanceID)
        },
        openConfigFile: { [weak self] instanceID in
            self?.openConfigFile(forInstanceID: instanceID)
        },
        openRepoFolder: { [weak self] instanceID in
            self?.openRepoFolder(forInstanceID: instanceID)
        },
        openModelSheet: { [weak self] instanceID in
            self?.openAgentModelSheet(forInstanceID: instanceID)
        },
        applyModelSelections: { [weak self] instanceID, assignments, restartIfRunning in
            self?.switchAgentModels(
                instanceID: instanceID,
                assignments: assignments,
                restartIfRunning: restartIfRunning
            )
        },
        setLaunchAtLogin: { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        },
        setAutoStartOnLaunch: { [weak self] enabled in
            self?.setAutoStartInstancesOnLaunch(enabled)
        },
        setAutoRestartCrashed: { [weak self] enabled in
            self?.setAutoRestartCrashedInstances(enabled)
        },
        fullRescan: { [weak self] in
            self?.fullRescanRepositories()
        },
        restoreIgnoredRepoPath: { [weak self] path in
            self?.restoreIgnoredRepoPath(path)
        }
    )
    private lazy var workspaceModel = AssistantWorkspaceModel(actions: workspaceActions)
    private lazy var mainWindowController = AssistantWindowController(model: workspaceModel)
    private var refreshTimer: Timer?
    private var hasAppliedStartupAutomation = false
    private var lastObservedStatuses: [String: InstanceStatus] = [:]
    private var nextAutoRestartAttemptAt: [String: Date] = [:]
    private var alertingCrashInstances: Set<String> = []
    private var acknowledgedCrashSignatures: [String: String] = [:]
    private var isMenuOpen = false
    private var needsMenuRefreshAfterClose = false
    private var currentReports: [InstanceReport] = []
    private var currentReportsByID: [String: InstanceReport] = [:]
    private var modelCatalogCache: [String: CachedModelCatalog] = [:]
    private var launchdLabelsCache: [String: CachedLaunchdLabels] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = mainWindowController

        if let button = statusItem.button {
            button.imagePosition = .noImage
            button.title = "Claw"
            button.toolTip = "OpenClaw 小助手"
            button.setAccessibilityLabel("OpenClaw 小助手")
        }

        statusItem.menu = loadingMenu()
        showMainWindow(route: .overview)

        // Let the app enter the menu bar first, then do the heavier refresh work.
        DispatchQueue.main.async { [weak self] in
            self?.finishLaunchingRefresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(route: workspaceModel.route)
        return true
    }

    private func finishLaunchingRefresh() {
        do {
            try store.bootstrapIfNeeded()
        } catch {
            presentErrorAlert(title: "初始化失败", message: error.localizedDescription)
        }

        syncLaunchAtLoginConfiguration()
        let reports = refreshUI()
        handleStartupAutomationIfNeeded(reports: reports)
        scheduleRefreshTimer()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()

        let interval = max(store.loadConfiguration().refreshIntervalSeconds, 1)
        refreshTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(refreshTimerFired(_:)), userInfo: nil, repeats: true)
        refreshTimer?.tolerance = min(interval * 0.25, 1)
    }

    @discardableResult
    private func refreshUI() -> [InstanceReport] {
        let reports = supervisor.reports()
        currentReports = reports
        currentReportsByID = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0) })
        let title = menuBarTitle(for: reports)

        statusItem.button?.imagePosition = .noImage
        statusItem.button?.image = nil
        statusItem.button?.title = title
        statusItem.button?.toolTip = tooltip(for: reports)
        publishWorkspaceSnapshot(reports: reports)
        if isMenuOpen {
            needsMenuRefreshAfterClose = true
        } else {
            statusItem.menu = buildMenu(reports: reports)
            presentCrashAlertsIfNeeded(reports: reports)
        }
        return reports
    }

    private func loadingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let loading = NSMenuItem(title: "正在初始化…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)
        menu.addItem(NSMenuItem.separator())

        let openMainWindow = NSMenuItem(title: "打开 OpenClaw 小助手", action: #selector(openMainWindow), keyEquivalent: "")
        openMainWindow.target = self
        menu.addItem(openMainWindow)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)
        return menu
    }

    private func buildMenu(reports: [InstanceReport]) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let runningCount = reports.filter { $0.status == .running }.count
        let header = NSMenuItem(title: "OpenClaw 小助手  已运行 \(runningCount)/\(reports.count)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let openMainWindow = NSMenuItem(title: "打开 OpenClaw 小助手", action: #selector(openMainWindow), keyEquivalent: "")
        openMainWindow.target = self
        menu.addItem(openMainWindow)

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let startAll = NSMenuItem(title: "启动全部 OpenClaw", action: #selector(startAllInstances), keyEquivalent: "")
        startAll.target = self
        menu.addItem(startAll)

        let stopAll = NSMenuItem(title: "停止全部 OpenClaw", action: #selector(stopAllInstances), keyEquivalent: "")
        stopAll.target = self
        menu.addItem(stopAll)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)

        return menu
    }

    private func instanceMenuItem(for report: InstanceReport) -> NSMenuItem {
        let title = report.instance.name
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = statusDotImage(for: report.status)
        let submenu = NSMenu()
        let managementURL = managementURL(for: report)

        submenu.addItem(disabledItem("状态: \(report.status.label)"))
        let automationEnabled = store.loadConfiguration().autoRestartCrashedInstances
        if automationEnabled && (report.status == .crashed || report.status == .starting) {
            submenu.addItem(disabledItem("保活: 已开启，正在自动重试"))
        }
        submenu.addItem(disabledItem("PID: \(report.displayPID)"))
        submenu.addItem(disabledItem("分支: \(report.repoBranch ?? "-")"))
        submenu.addItem(disabledItem("项目路径: \(report.instance.repoPath)"))
        if let managementURL {
            submenu.addItem(disabledItem("管理页: \(managementURL.absoluteString)"))
        }
        submenu.addItem(disabledItem("最近活动: \(Formatter.relativeString(for: report.lastActivityAt))"))

        if let recentLogLine = report.recentLogLine {
            submenu.addItem(disabledItem("最近日志: \(recentLogLine.prefix(90))"))
        }

        if let note = report.instance.notes, !note.isEmpty {
            submenu.addItem(disabledItem("备注: \(note)"))
        }

        if let modelsMenuItem = agentModelsActionItem(for: report) {
            submenu.addItem(NSMenuItem.separator())
            submenu.addItem(modelsMenuItem)
        }

        if report.status == .crashed,
           let guidance = crashGuidance(for: report) {
            submenu.addItem(NSMenuItem.separator())
            submenu.addItem(disabledItem("原因: \(guidance.summary)"))
            if let suggestion = guidance.suggestion, !suggestion.isEmpty {
                submenu.addItem(disabledItem("建议: \(suggestion)"))
            }

            if let configFileURL = guidance.configFileURL {
                let openConfig = NSMenuItem(title: "打开配置文件", action: #selector(openCrashConfigFile(_:)), keyEquivalent: "")
                openConfig.target = self
                openConfig.representedObject = configFileURL.path
                submenu.addItem(openConfig)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let start = NSMenuItem(title: "启动", action: #selector(startInstance(_:)), keyEquivalent: "")
        start.target = self
        start.representedObject = report.instance.id
        submenu.addItem(start)

        let restart = NSMenuItem(title: "重启", action: #selector(restartInstance(_:)), keyEquivalent: "")
        restart.target = self
        restart.representedObject = report.instance.id
        submenu.addItem(restart)

        let stop = NSMenuItem(title: "停止", action: #selector(stopInstance(_:)), keyEquivalent: "")
        stop.target = self
        stop.representedObject = report.instance.id
        submenu.addItem(stop)

        submenu.addItem(NSMenuItem.separator())

        let openRepo = NSMenuItem(title: "打开项目文件夹", action: #selector(openRepoFolder(_:)), keyEquivalent: "")
        openRepo.target = self
        openRepo.representedObject = report.instance.expandedRepoPath
        submenu.addItem(openRepo)

        let openLog = NSMenuItem(title: "打开日志文件", action: #selector(openLogFile(_:)), keyEquivalent: "")
        openLog.target = self
        openLog.representedObject = report.logFileURL.path
        submenu.addItem(openLog)

        let openManagementPage = NSMenuItem(title: "打开管理页", action: #selector(openManagementPage(_:)), keyEquivalent: "")
        openManagementPage.target = self
        openManagementPage.representedObject = report.instance.id
        openManagementPage.isEnabled = managementURL != nil
        submenu.addItem(openManagementPage)

        submenu.addItem(NSMenuItem.separator())

        let remove = NSMenuItem(title: "从列表移除", action: #selector(removeInstance(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = report.instance.id
        submenu.addItem(remove)

        item.submenu = submenu
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggleMenuItem(title: String, enabled: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
        return item
    }

    private func statusDotImage(for status: InstanceStatus) -> NSImage {
        let color: NSColor
        switch status {
        case .running, .starting:
            color = NSColor.systemGreen
        case .stopped, .crashed, .missingProject, .disabled:
            color = NSColor.systemRed
        }

        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func managementURL(for report: InstanceReport) -> URL? {
        guard let port = managementPort(for: report) else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    private func managementPort(for report: InstanceReport) -> Int? {
        if let port = observedManagementPort(for: report) {
            return port
        }

        return configuredManagementPort(for: report.instance)
    }

    private func configuredManagementPort(for instance: OpenClawInstance) -> Int? {
        if let envPort = instance.env["OPENCLAW_GATEWAY_PORT"],
           let port = Int(envPort),
           port > 0 {
            return port
        }

        if let portArgumentIndex = instance.startCommand.firstIndex(of: "--port"),
           instance.startCommand.indices.contains(portArgumentIndex + 1),
           let port = Int(instance.startCommand[portArgumentIndex + 1]),
           port > 0 {
            return port
        }

        return 18789
    }

    private func observedManagementPort(for report: InstanceReport) -> Int? {
        for pid in report.observedPIDs {
            if let port = observedManagementPort(forPID: pid) {
                return port
            }
        }

        return nil
    }

    private func observedManagementPort(forPID pid: Int32) -> Int? {
        let commandResult = ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="]
        )
        if let port = firstMatch(in: commandResult.stdout, pattern: #"--port(?:=|\s+)(\d+)"#)
            .flatMap(Int.init),
           port > 0 {
            return port
        }

        let lsofResult = ProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", String(pid), "-Fn"]
        )
        guard lsofResult.exitCode == 0 else {
            return nil
        }

        for line in lsofResult.stdout.split(separator: "\n") where line.hasPrefix("n") {
            let endpoint = String(line.dropFirst())
            guard let port = endpoint.split(separator: ":").last.flatMap({ Int($0) }),
                  port > 0 else {
                continue
            }
            return port
        }

        return nil
    }

    private func tooltip(for reports: [InstanceReport]) -> String {
        if reports.isEmpty {
            return "OpenClaw 小助手: 还没有实例"
        }
        return reports
            .map { "\($0.instance.name): \($0.status.label)" }
            .joined(separator: "\n")
    }

    private func menuBarTitle(for reports: [InstanceReport]) -> String {
        guard !reports.isEmpty else {
            return "Claw 0"
        }

        let total = reports.count
        let running = reports.filter { $0.status == .running }.count
        let crashed = reports.filter { $0.status == .crashed }.count
        let missing = reports.filter { $0.status == .missingProject }.count
        let starting = reports.filter { $0.status == .starting }.count

        if crashed > 0 {
            return "Claw !\(crashed)"
        }
        if missing > 0 {
            return "Claw ?\(missing)"
        }
        if starting > 0 {
            return "Claw \(running)/\(total)"
        }
        return "Claw \(running)/\(total)"
    }

    @objc private func refreshNow() {
        let reports = refreshUI()
        handleAutomaticRecovery(reports: reports)
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        guard workspaceModel.modelSheet == nil else {
            return
        }
        let reports = refreshUI()
        handleAutomaticRecovery(reports: reports)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        guard needsMenuRefreshAfterClose else {
            return
        }

        needsMenuRefreshAfterClose = false
        let reports = refreshUI()
        handleAutomaticRecovery(reports: reports)
    }

    @objc private func openMainWindow() {
        showMainWindow(route: workspaceModel.route)
    }

    @objc private func fullRescanRepositories() {
        executeAction("全量扫描") {
            try store.fullRescan()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!store.loadConfiguration().launchAtLogin)
    }

    @objc private func toggleAutoStartInstancesOnLaunch() {
        setAutoStartInstancesOnLaunch(!store.loadConfiguration().autoStartInstancesOnLaunch)
    }

    @objc private func toggleAutoRestartCrashedInstances() {
        setAutoRestartCrashedInstances(!store.loadConfiguration().autoRestartCrashedInstances)
    }

    @objc private func startAllInstances() {
        executeAction("启动全部") {
            try supervisor.startAll()
        }
    }

    @objc private func restartAllInstances() {
        executeAction("重启全部") {
            try supervisor.restartAll()
        }
    }

    @objc private func stopAllInstances() {
        executeAction("停止全部") {
            try supervisor.stopAll()
        }
    }

    @objc private func startInstance(_ sender: NSMenuItem) {
        guard let instanceID = sender.representedObject as? String else { return }
        startInstance(withID: instanceID)
    }

    @objc private func restartInstance(_ sender: NSMenuItem) {
        guard let instanceID = sender.representedObject as? String else { return }
        restartInstance(withID: instanceID)
    }

    @objc private func stopInstance(_ sender: NSMenuItem) {
        guard let instanceID = sender.representedObject as? String else { return }
        stopInstance(withID: instanceID)
    }

    @objc private func openManagementPage(_ sender: NSMenuItem) {
        guard let instanceID = sender.representedObject as? String else { return }
        openManagementPage(forInstanceID: instanceID)
    }

    @objc private func openAgentModelPicker(_ sender: NSMenuItem) {
        guard let instanceID = sender.representedObject as? String else { return }
        openAgentModelSheet(forInstanceID: instanceID)
    }

    @objc private func openCrashConfigFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func removeInstance(_ sender: NSMenuItem) {
        guard let instanceID = sender.representedObject as? String else { return }
        removeInstance(withID: instanceID)
    }

    @objc private func openConfigFile() {
        NSWorkspace.shared.open(store.configURL)
    }

    @objc private func openSupportDirectory() {
        NSWorkspace.shared.open(store.supportDirectory)
    }

    @objc private func openRepoFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openLogFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }

    private func openLogFile(forInstanceID instanceID: String) {
        guard let report = report(forInstanceID: instanceID) else {
            presentErrorAlert(title: "打开日志", message: "未找到实例：\(instanceID)")
            return
        }

        let path = report.logFileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        NSWorkspace.shared.open(report.logFileURL)
    }

    private func openConfigFile(forInstanceID instanceID: String) {
        guard let report = report(forInstanceID: instanceID) else {
            presentErrorAlert(title: "打开配置文件", message: "未找到实例：\(instanceID)")
            return
        }

        guard let configURL = agentModelManager.configURLIfAvailable(for: report.instance) else {
            presentErrorAlert(title: "打开配置文件", message: "没有识别到 \(report.instance.name) 的配置文件。")
            return
        }

        NSWorkspace.shared.open(configURL)
    }

    private func openRepoFolder(forInstanceID instanceID: String) {
        guard let report = report(forInstanceID: instanceID) else {
            presentErrorAlert(title: "打开项目文件夹", message: "未找到实例：\(instanceID)")
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: report.instance.expandedRepoPath))
    }

    private func startInstance(withID instanceID: String) {
        executeAction("启动实例") {
            try supervisor.start(instanceID: instanceID)
        }
    }

    private func restartInstance(withID instanceID: String) {
        executeAction("重启实例") {
            try supervisor.restart(instanceID: instanceID)
        }
    }

    private func stopInstance(withID instanceID: String) {
        executeAction("停止实例") {
            try supervisor.stop(instanceID: instanceID)
        }
    }

    private func openManagementPage(forInstanceID instanceID: String) {
        guard let report = report(forInstanceID: instanceID) else {
            presentErrorAlert(title: "打开管理页", message: "未找到实例：\(instanceID)")
            return
        }

        guard let url = managementURL(for: report) else {
            presentErrorAlert(title: "打开管理页", message: "无法推断 \(report.instance.name) 的管理页地址。")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func openAgentModelSheet(forInstanceID instanceID: String) {
        guard let report = report(forInstanceID: instanceID) else {
            presentErrorAlert(title: "切换模型", message: "未找到实例：\(instanceID)")
            return
        }

        do {
            let catalog = try modelCatalog(for: report.instance)
            guard !catalog.agents.isEmpty else {
                presentErrorAlert(title: "切换模型", message: "这个实例没有识别到可切换的智能体。")
                return
            }
            workspaceModel.presentModelSheet(
                AssistantModelSheetState(instanceID: report.instance.id, catalog: catalog)
            )
            showMainWindow(route: .instanceDetail(report.instance.id))
        } catch {
            presentErrorAlert(title: "切换模型失败", message: error.localizedDescription)
        }
    }

    private func switchAgentModels(
        instanceID: String,
        assignments: [String: String],
        restartIfRunning: Bool
    ) {
        guard let report = report(forInstanceID: instanceID) else {
            presentErrorAlert(title: "切换模型", message: "未找到实例：\(instanceID)")
            return
        }

        do {
            let existingCatalog = try modelCatalog(for: report.instance)
            let changedAssignments = assignments.filter { agentID, modelID in
                existingCatalog.agents.first(where: { $0.agentID == agentID })?.currentModelID != modelID
            }
            if changedAssignments.isEmpty {
                return
            }

            _ = try agentModelManager.setPrimaryModels(changedAssignments, in: report.instance)
            invalidateModelCatalog(forInstanceID: instanceID)
            if restartIfRunning && (report.status == .running || report.status == .starting) {
                try supervisor.restart(instanceID: instanceID)
            }

            let refreshedReports = refreshUI()
            handleAutomaticRecovery(reports: refreshedReports)
        } catch {
            presentErrorAlert(title: "切换模型失败", message: error.localizedDescription)
        }
    }

    private func removeInstance(withID instanceID: String) {
        guard let report = report(forInstanceID: instanceID) else {
            presentErrorAlert(title: "移除实例", message: "未找到实例：\(instanceID)")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "从列表移除 \(report.instance.name)？"
        alert.informativeText = "这会把它从配置里删除，并记录到忽略列表。之后自动扫描不会再把它加回来，除非执行“全量扫描仓库”。当前正在运行的进程不会被停止。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        executeAction("移除实例") {
            try store.removeInstance(instanceID: instanceID)
        }
    }

    private func executeAction(_ title: String, work: () throws -> Void) {
        do {
            try work()
            let reports = refreshUI()
            handleAutomaticRecovery(reports: reports)
        } catch {
            presentErrorAlert(title: title, message: error.localizedDescription)
        }
    }

    private func agentModelsActionItem(for report: InstanceReport) -> NSMenuItem? {
        guard let catalog = try? modelCatalog(for: report.instance) else {
            return nil
        }

        if catalog.agents.isEmpty {
            return disabledItem("智能体编组：未识别到可切换智能体")
        }

        let item = NSMenuItem(title: "打开智能体编组…", action: #selector(openAgentModelPicker(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = report.instance.id
        return item
    }

    private func updateAutomationSetting(
        title: String,
        mutate: (inout AssistantConfiguration) -> Void,
        afterSave: ((AssistantConfiguration) throws -> Void)? = nil
    ) {
        do {
            let configuration = try store.updateConfiguration { configuration in
                mutate(&configuration)
            }
            try afterSave?(configuration)
            let reports = refreshUI()
            handleAutomaticRecovery(reports: reports)
        } catch {
            presentErrorAlert(title: title, message: error.localizedDescription)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        updateAutomationSetting(title: "开机自启动") { configuration in
            configuration.launchAtLogin = enabled
        } afterSave: { configuration in
            try LaunchAtLoginManager.sync(enabled: configuration.launchAtLogin)
        }
    }

    private func setAutoStartInstancesOnLaunch(_ enabled: Bool) {
        updateAutomationSetting(title: "自动启动 OpenClaw") { configuration in
            configuration.autoStartInstancesOnLaunch = enabled
        }
    }

    private func setAutoRestartCrashedInstances(_ enabled: Bool) {
        updateAutomationSetting(title: "自动保活") { configuration in
            configuration.autoRestartCrashedInstances = enabled
        }
    }

    private func restoreIgnoredRepoPath(_ path: String) {
        executeAction("恢复忽略仓库") {
            try store.restoreIgnoredRepoPath(path)
        }
    }

    private func report(forInstanceID instanceID: String) -> InstanceReport? {
        if let report = currentReportsByID[instanceID] {
            return report
        }

        let refreshedReports = supervisor.reports()
        currentReports = refreshedReports
        currentReportsByID = Dictionary(uniqueKeysWithValues: refreshedReports.map { ($0.id, $0) })
        return currentReportsByID[instanceID]
    }

    private func cachedLaunchdLabels(for instanceID: String) -> [String] {
        let now = Date()
        if let cached = launchdLabelsCache[instanceID],
           now.timeIntervalSince(cached.fetchedAt) < 30 {
            return cached.labels
        }

        let labels = supervisor.managedLaunchdLabels(for: instanceID)
        launchdLabelsCache[instanceID] = CachedLaunchdLabels(labels: labels, fetchedAt: now)
        return labels
    }

    private func snapshotManagementURL(for report: InstanceReport) -> URL? {
        guard let port = configuredManagementPort(for: report.instance) else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    private func cachedModelCatalog(for instance: OpenClawInstance) throws -> CachedModelCatalog {
        guard let configURL = agentModelManager.configURLIfAvailable(for: instance) else {
            throw NSError(domain: "OpenClawAssistant", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "没找到 \(instance.name) 的 openclaw.json 配置文件。"
            ])
        }

        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date) ?? nil
        if let cached = modelCatalogCache[instance.id],
           cached.configURL.path == configURL.path,
           cached.modifiedAt == modifiedAt {
            return cached
        }

        let catalog = try agentModelManager.catalog(for: instance)
        let cached = CachedModelCatalog(
            configURL: catalog.configURL,
            modifiedAt: modifiedAt,
            catalog: catalog,
            summary: modelSummary(for: catalog)
        )
        modelCatalogCache[instance.id] = cached
        return cached
    }

    private func modelCatalog(for instance: OpenClawInstance) throws -> OpenClawInstanceModelCatalog {
        try cachedModelCatalog(for: instance).catalog
    }

    private func invalidateModelCatalog(forInstanceID instanceID: String) {
        modelCatalogCache.removeValue(forKey: instanceID)
    }

    private func showMainWindow(route: AssistantRoute) {
        workspaceModel.show(route: route)
        mainWindowController.reveal()
    }

    private func publishWorkspaceSnapshot(reports: [InstanceReport]) {
        let configuration = store.loadConfiguration()

        var managementURLs: [String: URL] = [:]
        var configURLs: [String: URL] = [:]
        var modelSummaries: [String: String] = [:]
        var managedLaunchdLabels: [String: [String]] = [:]

        for report in reports {
            if let managementURL = snapshotManagementURL(for: report) {
                managementURLs[report.id] = managementURL
            }

            if let cachedCatalog = try? cachedModelCatalog(for: report.instance) {
                configURLs[report.id] = cachedCatalog.configURL
                modelSummaries[report.id] = cachedCatalog.summary
            }

            let labels = cachedLaunchdLabels(for: report.id)
            if !labels.isEmpty {
                managedLaunchdLabels[report.id] = labels
            }
        }

        let attentionItems = buildAttentionItems(
            reports: reports,
            configuration: configuration,
            configURLsByInstanceID: configURLs,
            managedLaunchdLabelsByInstanceID: managedLaunchdLabels
        )

        workspaceModel.apply(
            snapshot: AssistantWorkspaceSnapshot(
                reports: reports,
                configuration: configuration,
                attentionItems: attentionItems,
                managementURLsByInstanceID: managementURLs,
                configURLsByInstanceID: configURLs,
                modelSummaryByInstanceID: modelSummaries,
                managedLaunchdLabelsByInstanceID: managedLaunchdLabels,
                generatedAt: Date()
            )
        )
    }

    private func modelSummary(for catalog: OpenClawInstanceModelCatalog) -> String {
        let currentModels = catalog.agents.compactMap(\.currentModelID)
        guard let firstModel = currentModels.first else {
            return "\(catalog.agents.count) 个智能体"
        }

        if catalog.agents.count == 1 {
            return firstModel
        }

        return "\(catalog.agents.count) 个智能体 · \(firstModel)"
    }

    private func buildAttentionItems(
        reports: [InstanceReport],
        configuration: AssistantConfiguration,
        configURLsByInstanceID: [String: URL],
        managedLaunchdLabelsByInstanceID: [String: [String]]
    ) -> [AssistantAttentionItem] {
        var items: [AssistantAttentionItem] = []

        for report in reports {
            if report.status == .crashed {
                let guidance = crashGuidance(for: report)
                items.append(
                    AssistantAttentionItem(
                        id: "crash:\(report.id):\(crashSignature(for: report, guidance: guidance))",
                        severity: .critical,
                        title: "\(report.instance.name) 已崩溃",
                        summary: guidance?.summary ?? summarizedCrashReason(for: report),
                        detail: crashAlertMessage(for: report, guidance: guidance),
                        timestamp: report.runtime.lastCrashedAt ?? report.lastActivityAt,
                        instanceID: report.id,
                        configURL: guidance?.configFileURL ?? configURLsByInstanceID[report.id],
                        logURL: report.logFileURL,
                        repoPath: report.instance.expandedRepoPath,
                        ignoredRepoPath: nil,
                        launchdLabels: managedLaunchdLabelsByInstanceID[report.id] ?? []
                    )
                )
            }

            if report.status == .missingProject {
                items.append(
                    AssistantAttentionItem(
                        id: "missing:\(report.id)",
                        severity: .warning,
                        title: "\(report.instance.name) 项目不可用",
                        summary: "当前路径不存在可运行的 OpenClaw 项目。",
                        detail: "仓库路径 \(report.instance.repoPath) 目前不可用，启动和重启操作都会失败。先确认目录是否还在，或者从列表里移除它。",
                        timestamp: report.lastActivityAt,
                        instanceID: report.id,
                        configURL: configURLsByInstanceID[report.id],
                        logURL: report.logFileURL,
                        repoPath: report.instance.expandedRepoPath,
                        ignoredRepoPath: nil,
                        launchdLabels: []
                    )
                )
            }

            if let labels = managedLaunchdLabelsByInstanceID[report.id], !labels.isEmpty {
                items.append(
                    AssistantAttentionItem(
                        id: "launchd:\(report.id)",
                        severity: .info,
                        title: "\(report.instance.name) 由系统托管",
                        summary: "启动和停止会同时接管对应的 LaunchAgent。",
                        detail: "这个实例背后有 launchd 服务在保活。你在小助手里执行启动和停止时，我会同步处理这些托管服务，避免看起来像“点了没反应”。",
                        timestamp: report.runtime.lastStartedAt,
                        instanceID: report.id,
                        configURL: configURLsByInstanceID[report.id],
                        logURL: report.logFileURL,
                        repoPath: report.instance.expandedRepoPath,
                        ignoredRepoPath: nil,
                        launchdLabels: labels
                    )
                )
            }
        }

        for path in configuration.ignoredRepoPaths {
            items.append(
                AssistantAttentionItem(
                    id: "ignored:\(path)",
                    severity: .info,
                    title: "有仓库被放进忽略列表",
                    summary: path,
                    detail: "这个仓库已经被记录到忽略列表，平时自动扫描不会再把它加回来。你可以在这里恢复，或者之后执行全量扫描。",
                    timestamp: nil,
                    instanceID: nil,
                    configURL: nil,
                    logURL: nil,
                    repoPath: nil,
                    ignoredRepoPath: path,
                    launchdLabels: []
                )
            )
        }

        return items.sorted { lhs, rhs in
            let lhsDate = lhs.timestamp ?? .distantPast
            let rhsDate = rhs.timestamp ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func syncLaunchAtLoginConfiguration() {
        let configuration = store.loadConfiguration()
        do {
            try LaunchAtLoginManager.sync(enabled: configuration.launchAtLogin)
        } catch {
            logMaintenanceError("同步开机启动失败", error: error)
        }
    }

    private func handleStartupAutomationIfNeeded(reports: [InstanceReport]) {
        lastObservedStatuses = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0.status) })

        guard !hasAppliedStartupAutomation else {
            return
        }
        hasAppliedStartupAutomation = true

        let configuration = store.loadConfiguration()
        guard configuration.autoStartInstancesOnLaunch else {
            return
        }

        do {
            try supervisor.startAll()
            let refreshedReports = refreshUI()
            lastObservedStatuses = Dictionary(uniqueKeysWithValues: refreshedReports.map { ($0.id, $0.status) })
        } catch {
            logMaintenanceError("自动启动实例失败", error: error)
        }
    }

    private func handleAutomaticRecovery(reports: [InstanceReport]) {
        defer {
            lastObservedStatuses = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0.status) })
        }

        let configuration = store.loadConfiguration()
        guard configuration.autoRestartCrashedInstances else {
            return
        }

        let now = Date()
        var attemptedRecovery = false

        for report in reports {
            if report.status == .running || report.status == .starting {
                nextAutoRestartAttemptAt.removeValue(forKey: report.id)
                continue
            }

            guard shouldAutoRestart(report: report, previousStatus: lastObservedStatuses[report.id]) else {
                continue
            }

            if let nextAllowedAt = nextAutoRestartAttemptAt[report.id], now < nextAllowedAt {
                continue
            }

            nextAutoRestartAttemptAt[report.id] = now.addingTimeInterval(30)

            do {
                try supervisor.start(instanceID: report.id)
                attemptedRecovery = true
            } catch {
                logMaintenanceError("自动重启 \(report.instance.name) 失败", error: error)
            }
        }

        if attemptedRecovery {
            let refreshedReports = refreshUI()
            lastObservedStatuses = Dictionary(uniqueKeysWithValues: refreshedReports.map { ($0.id, $0.status) })
        }
    }

    private func shouldAutoRestart(report: InstanceReport, previousStatus: InstanceStatus?) -> Bool {
        guard !report.instance.disabled, report.repoExists else {
            return false
        }
        guard !report.runtime.lastStopWasManual else {
            return false
        }

        if report.status == .crashed {
            return true
        }

        if report.status == .stopped,
           let previousStatus,
           previousStatus == .running || previousStatus == .starting {
            return true
        }

        return false
    }

    private func logMaintenanceError(_ title: String, error: Error) {
        FileHandle.standardError.write(Data("[OpenClawAssistant] \(title): \(error.localizedDescription)\n".utf8))
    }

    private func presentCrashAlertsIfNeeded(reports: [InstanceReport]) {
        for report in reports {
            switch report.status {
            case .running, .stopped, .missingProject, .disabled:
                alertingCrashInstances.remove(report.id)
            case .starting:
                continue
            case .crashed:
                let guidance = crashGuidance(for: report)
                let signature = crashSignature(for: report, guidance: guidance)
                guard !alertingCrashInstances.contains(report.id) else {
                    continue
                }
                guard acknowledgedCrashSignatures[report.id] != signature else {
                    continue
                }
                alertingCrashInstances.insert(report.id)
                presentCrashAlert(for: report, guidance: guidance, signature: signature)
            }
        }
    }

    private func presentCrashAlert(for report: InstanceReport, guidance: CrashGuidance?, signature: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(report.instance.name) 已崩溃"
        alert.informativeText = crashAlertMessage(for: report, guidance: guidance)

        defer {
            acknowledgedCrashSignatures[report.id] = signature
            alertingCrashInstances.remove(report.id)
        }

        if let configFileURL = guidance?.configFileURL {
            alert.addButton(withTitle: "打开配置文件")
            alert.addButton(withTitle: "打开日志")
            alert.addButton(withTitle: "知道了")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(configFileURL)
            }
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(report.logFileURL)
            }
            return
        }

        alert.addButton(withTitle: "打开日志")
        alert.addButton(withTitle: "知道了")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(report.logFileURL)
        }
    }

    private func crashSignature(for report: InstanceReport, guidance: CrashGuidance?) -> String {
        let basis = guidance?.summary
            ?? report.recentLogLine
            ?? summarizedCrashReason(for: report)
        let normalizedBasis = basis.trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalizedBasis.isEmpty ? report.status.label : normalizedBasis)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func crashAlertMessage(for report: InstanceReport, guidance: CrashGuidance?) -> String {
        let reason = guidance?.summary ?? summarizedCrashReason(for: report)
        var lines = ["实例启动后又退出了。"]

        if !reason.isEmpty {
            lines.append("原因：\(reason)")
        }

        if let suggestion = guidance?.suggestion, !suggestion.isEmpty {
            lines.append("建议：\(suggestion)")
        } else if let recentLogLine = report.recentLogLine, !recentLogLine.isEmpty {
            lines.append("最近日志：\(recentLogLine)")
        }

        if store.loadConfiguration().autoRestartCrashedInstances {
            lines.append("自动保活已开启，小助手会继续尝试重新拉起它。")
        }

        lines.append("日志文件：\(report.logFileURL.path)")
        return lines.joined(separator: "\n")
    }

    private func crashGuidance(for report: InstanceReport) -> CrashGuidance? {
        let lines = FileSystem.lastNonEmptyLines(in: report.logFileURL, limit: 40)
        let extractedConfigFilePath = extractedConfigFilePath(from: lines)
        let inferredConfigFileURL = inferredConfigFileURL(
            for: report.instance,
            extractedPath: extractedConfigFilePath
        )
        let configFilePath = extractedConfigFilePath ?? inferredConfigFileURL?.path

        if let configFilePath {
            return CrashGuidance(
                summary: "配置文件不兼容：\(configFilePath)",
                suggestion: "先打开配置文件和日志，把报错交给其他工具处理。",
                configFileURL: inferredConfigFileURL
            )
        }

        if lines.contains(where: { $0.localizedCaseInsensitiveContains("doctor --fix") }) {
            return CrashGuidance(
                summary: summarizedCrashReason(for: report),
                suggestion: "先打开日志定位问题，再把这条报错交给其他工具处理。",
                configFileURL: inferredConfigFileURL
            )
        }

        let recent = report.recentLogLine ?? lines.first ?? "实例启动后立即退出，可能是配置不兼容或运行环境问题。"

        return CrashGuidance(
            summary: recent,
            suggestion: inferredConfigFileURL == nil
                ? "先打开日志查看最近错误，再决定是否要调整实例配置。"
                : "先打开配置文件和日志，把报错交给其他工具处理。",
            configFileURL: inferredConfigFileURL
        )
    }

    private func summarizedCrashReason(for report: InstanceReport) -> String {
        let lines = FileSystem.lastNonEmptyLines(in: report.logFileURL, limit: 20)

        if let configLine = lines.first(where: {
            $0.localizedCaseInsensitiveContains("invalid config at") ||
            $0.localizedCaseInsensitiveContains("config invalid")
        }) {
            return configLine
        }

        if let doctorLine = lines.first(where: {
            $0.localizedCaseInsensitiveContains("doctor --fix")
        }) {
            return doctorLine
        }

        return report.recentLogLine ?? ""
    }

    private func extractedConfigFilePath(from lines: [String]) -> String? {
        for line in lines {
            if let path = firstMatch(in: line, pattern: #"Invalid config at\s+([^:]+):"#) {
                return path
            }
            if let path = firstMatch(in: line, pattern: #"File:\s+(.+openclaw\.json)"#) {
                return path
            }
        }
        return nil
    }

    private func inferredConfigFileURL(for instance: OpenClawInstance, extractedPath: String?) -> URL? {
        let explicitPath: String?
        if let extractedPath, !extractedPath.isEmpty {
            explicitPath = extractedPath
        } else if let envPath = instance.env["OPENCLAW_CONFIG_PATH"], !envPath.isEmpty {
            explicitPath = envPath
        } else if let envPath = instance.env["CLAWDBOT_CONFIG_PATH"], !envPath.isEmpty {
            explicitPath = envPath
        } else {
            explicitPath = nil
        }

        if let explicitPath {
            let url = URL(fileURLWithPath: PathExpander.expand(explicitPath))
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate: URL
        if let profile = inferredProfile(for: instance, configFilePath: nil), !profile.isEmpty {
            candidate = home.appendingPathComponent(".openclaw-\(profile)/openclaw.json")
        } else {
            candidate = home.appendingPathComponent(".openclaw/openclaw.json")
        }

        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func inferredProfile(for instance: OpenClawInstance, configFilePath: String?) -> String? {
        if let profileIndex = instance.startCommand.firstIndex(of: "--profile"),
           instance.startCommand.indices.contains(profileIndex + 1) {
            return instance.startCommand[profileIndex + 1]
        }

        if let profile = instance.env["OPENCLAW_PROFILE"], !profile.isEmpty {
            return profile
        }

        guard let configFilePath else {
            return nil
        }

        let expanded = PathExpander.expand(configFilePath)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent().lastPathComponent
        guard parent.hasPrefix(".openclaw-") else {
            return nil
        }
        return String(parent.dropFirst(".openclaw-".count))
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
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
