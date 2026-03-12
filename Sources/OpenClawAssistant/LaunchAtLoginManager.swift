import Darwin
import Foundation

enum LaunchAtLoginManager {
    private static let label = "ai.openclaw.assistant.launch-at-login"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func sync(enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        let bundleURL = try launchBundleURL()
        let desiredData = try launchAgentData(for: bundleURL)

        try FileSystem.ensureDirectory(launchAgentURL.deletingLastPathComponent())

        let existingData = try? Data(contentsOf: launchAgentURL)
        guard existingData != desiredData else {
            return
        }

        try desiredData.write(to: launchAgentURL, options: .atomic)
        reloadLaunchAgent()
    }

    private static func uninstall() throws {
        bootoutLaunchAgent()
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private static func reloadLaunchAgent() {
        bootoutLaunchAgent()
        _ = ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", launchDomain, launchAgentURL.path]
        )
    }

    private static func bootoutLaunchAgent() {
        _ = ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", launchDomain, launchAgentURL.path]
        )
    }

    private static func launchAgentData(for bundleURL: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "LimitLoadToSessionType": ["Aqua"],
            "ProgramArguments": ["/usr/bin/open", bundleURL.path],
            "RunAtLoad": true,
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private static func launchBundleURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let pathComponents = executableURL.pathComponents

        if let buildIndex = pathComponents.firstIndex(of: ".build"), buildIndex > 1 {
            var root = URL(fileURLWithPath: "/")
            for component in pathComponents[1..<buildIndex] {
                root.appendPathComponent(component, isDirectory: true)
            }

            let candidates = [
                root.appendingPathComponent("OpenClaw小助手.app", isDirectory: true),
                root.appendingPathComponent("dist/OpenClawAssistant.app", isDirectory: true),
            ]

            if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return existing
            }
        }

        throw LaunchAtLoginError.bundleNotFound
    }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var launchDomain: String {
        "gui/\(getuid())"
    }
}

private enum LaunchAtLoginError: LocalizedError {
    case bundleNotFound

    var errorDescription: String? {
        switch self {
        case .bundleNotFound:
            return "找不到可用于开机启动的 OpenClaw 小助手 app bundle。"
        }
    }
}
