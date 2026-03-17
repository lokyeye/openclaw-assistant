import Foundation

final class DataBuffer: @unchecked Sendable {
    private var storage = Data()

    func append(_ data: Data) {
        storage.append(data)
    }

    var data: Data {
        storage
    }
}

enum PathExpander {
    static func expand(_ value: String) -> String {
        (value as NSString).expandingTildeInPath
    }
}

enum ProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String] = [:]
    ) -> Result {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        var mergedEnvironment = ProcessInfo.processInfo.environment
        environment.forEach { mergedEnvironment[$0.key] = $0.value }
        process.environment = mergedEnvironment

        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()
        let stdoutFinished = DispatchSemaphore(value: 0)
        let stderrFinished = DispatchSemaphore(value: 0)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stdoutFinished.signal()
                return
            }
            stdoutBuffer.append(chunk)
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stderrFinished.signal()
                return
            }
            stderrBuffer.append(chunk)
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return Result(
                exitCode: 1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        stdoutFinished.wait()
        stderrFinished.wait()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutBuffer.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.data, encoding: .utf8) ?? ""
        )
    }
}

enum FileSystem {
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func directoryExists(atPath path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    static func latestModificationDate(for paths: [String]) -> Date? {
        let fileManager = FileManager.default
        let urls = paths.map { URL(fileURLWithPath: PathExpander.expand($0)) }
        var newest: Date?

        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else { continue }

            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate {
                newest = maxDate(newest, modified)
            }

            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let childURL as URL in enumerator {
                guard let values = try? childURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate else {
                    continue
                }
                newest = maxDate(newest, modified)
            }
        }

        return newest
    }

    static func lastNonEmptyLine(in url: URL) -> String? {
        lastNonEmptyLines(in: url, limit: 1).first
    }

    static func lastNonEmptyLines(in url: URL, limit: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer {
            try? handle.close()
        }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let chunkSize = min(fileSize, 16 * 1024)
        guard chunkSize > 0 else { return [] }

        try? handle.seek(toOffset: fileSize - chunkSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return text
            .split(separator: "\n")
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { String($0) }
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }
}

enum Formatter {
    private static func relativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }

    static func relativeString(for date: Date?) -> String {
        guard let date else { return "-" }
        return relativeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
