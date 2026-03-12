import AppKit
import Darwin

let launchArguments = CommandLine.arguments
    .dropFirst()
    .filter { !$0.hasPrefix("-psn_") }

if !launchArguments.isEmpty {
    exit(AssistantCLI.run(arguments: Array(launchArguments)))
}

let application = NSApplication.shared
let delegate = AppController()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
