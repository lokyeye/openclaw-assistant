import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let store = ConfigurationStore()
    private lazy var supervisor = InstanceSupervisor(store: store)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?
    private var hasAppliedStartupAutomation = false
    private var lastObservedStatuses: [String: InstanceStatus] = [:]
    private var nextAutoRestartAttemptAt: [String: Date] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.imagePosition = .noImage
            button.title = "Claw"
            button.toolTip = "OpenClaw 小助手"
            button.setAccessibilityLabel("OpenClaw 小助手")
        }

        statusItem.menu = loadingMenu()

        // Let the app enter the menu bar first, then do the heavier refresh work.
        DispatchQueue.main.async { [weak self] in
            self?.finishLaunchingRefresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
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
        let title = menuBarTitle(for: reports)

        statusItem.button?.imagePosition = .noImage
        statusItem.button?.image = nil
        statusItem.button?.title = title
        statusItem.button?.toolTip = tooltip(for: reports)
        statusItem.menu = buildMenu(reports: reports)
        return reports
    }

    private func loadingMenu() -> NSMenu {
        let menu = NSMenu()
        let loading = NSMenuItem(title: "正在初始化…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)
        return menu
    }

    private func buildMenu(reports: [InstanceReport]) -> NSMenu {
        let menu = NSMenu()

        let runningCount = reports.filter { $0.status == .running || $0.status == .starting }.count
        let header = NSMenuItem(title: "OpenClaw 小助手  已运行 \(runningCount)/\(reports.count)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let fullScanItem = NSMenuItem(title: "全量扫描仓库", action: #selector(fullRescanRepositories), keyEquivalent: "")
        fullScanItem.target = self
        menu.addItem(fullScanItem)

        menu.addItem(NSMenuItem.separator())

        let startAll = NSMenuItem(title: "启动全部龙虾", action: #selector(startAllInstances), keyEquivalent: "")
        startAll.target = self
        menu.addItem(startAll)

        let restartAll = NSMenuItem(title: "重启全部龙虾", action: #selector(restartAllInstances), keyEquivalent: "")
        restartAll.target = self
        menu.addItem(restartAll)

        let stopAll = NSMenuItem(title: "停止全部龙虾", action: #selector(stopAllInstances), keyEquivalent: "")
        stopAll.target = self
        menu.addItem(stopAll)

        menu.addItem(NSMenuItem.separator())

        if reports.isEmpty {
            let empty = NSMenuItem(title: "没发现 OpenClaw 实例，先去编辑配置。", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for report in reports {
                menu.addItem(instanceMenuItem(for: report))
            }
        }

        menu.addItem(NSMenuItem.separator())

        let editConfig = NSMenuItem(title: "编辑实例配置", action: #selector(openConfigFile), keyEquivalent: ",")
        editConfig.target = self
        menu.addItem(editConfig)

        let openSupport = NSMenuItem(title: "打开运行目录", action: #selector(openSupportDirectory), keyEquivalent: "")
        openSupport.target = self
        menu.addItem(openSupport)

        menu.addItem(NSMenuItem.separator())

        let configuration = store.loadConfiguration()
        menu.addItem(toggleMenuItem(
            title: "开机自动启动小助手",
            enabled: configuration.launchAtLogin,
            action: #selector(toggleLaunchAtLogin)
        ))
        menu.addItem(toggleMenuItem(
            title: "打开小助手时自动启动 OpenClaw",
            enabled: configuration.autoStartInstancesOnLaunch,
            action: #selector(toggleAutoStartInstancesOnLaunch)
        ))
        menu.addItem(toggleMenuItem(
            title: "实例崩溃后自动重新拉起",
            enabled: configuration.autoRestartCrashedInstances,
            action: #selector(toggleAutoRestartCrashedInstances)
        ))

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
        let running = reports.filter { $0.status == .running || $0.status == .starting }.count
        let crashed = reports.filter { $0.status == .crashed }.count
        let missing = reports.filter { $0.status == .missingProject }.count

        if crashed > 0 {
            return "Claw !\(crashed)"
        }
        if missing > 0 {
            return "Claw ?\(missing)"
        }
        return "Claw \(running)/\(total)"
    }

    @objc private func refreshNow() {
        let reports = refreshUI()
        handleAutomaticRecovery(reports: reports)
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        let reports = refreshUI()
        handleAutomaticRecovery(reports: reports)
    }

    @objc private func fullRescanRepositories() {
        executeAction("全量扫描") {
            try store.fullRescan()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        updateAutomationSetting(title: "开机自启动") { configuration in
            configuration.launchAtLogin.toggle()
        } afterSave: { configuration in
            try LaunchAtLoginManager.sync(enabled: configuration.launchAtLogin)
        }
    }

    @objc private func toggleAutoStartInstancesOnLaunch() {
        updateAutomationSetting(title: "自动启动 OpenClaw") { configuration in
            configuration.autoStartInstancesOnLaunch.toggle()
        }
    }

    @objc private func toggleAutoRestartCrashedInstances() {
        updateAutomationSetting(title: "自动保活") { configuration in
            configuration.autoRestartCrashedInstances.toggle()
        }
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
        guard let report = supervisor.reports().first(where: { $0.instance.id == instanceID }) else {
            presentErrorAlert(title: "打开管理页", message: "未找到实例：\(instanceID)")
            return
        }

        guard let url = managementURL(for: report) else {
            presentErrorAlert(title: "打开管理页", message: "无法推断 \(report.instance.name) 的管理页地址。")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func removeInstance(withID instanceID: String) {
        guard let report = supervisor.reports().first(where: { $0.instance.id == instanceID }) else {
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
