import Foundation

final class ConfigurationStore {
    let supportDirectory: URL
    let configURL: URL
    let runtimeURL: URL
    let logsDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        supportDirectory = appSupport.appendingPathComponent("OpenClawAssistant", isDirectory: true)
        configURL = supportDirectory.appendingPathComponent("instances.json")
        runtimeURL = supportDirectory.appendingPathComponent("runtime.json")
        logsDirectory = supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    func bootstrapIfNeeded(fullRescan: Bool = false) throws {
        try FileSystem.ensureDirectory(supportDirectory)
        try FileSystem.ensureDirectory(logsDirectory)

        let configuration: AssistantConfiguration
        if !FileSystem.fileExists(atPath: configURL.path) {
            configuration = AssistantConfiguration(
                refreshIntervalSeconds: 3,
                instances: OpenClawDiscovery.discoverDefaultInstances()
            )
        } else {
            var existing = loadConfiguration()
            existing.ignoredRepoPaths = normalizedPaths(existing.ignoredRepoPaths)

            let refreshed = OpenClawDiscovery.refreshAutoDiscoveredInstances(existing.instances)
            let discovered = OpenClawDiscovery.discoverAdditionalInstances(
                existing: refreshed,
                ignoredRepoPaths: existing.ignoredRepoPaths,
                includeIgnored: fullRescan
            )
            let mergedInstances = (refreshed + discovered)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let visiblePaths = Set(mergedInstances.map { normalizedPath($0.expandedRepoPath) })
            let filteredIgnoredPaths = fullRescan
                ? existing.ignoredRepoPaths.filter { !visiblePaths.contains($0) }
                : existing.ignoredRepoPaths

            if mergedInstances != existing.instances || filteredIgnoredPaths != existing.ignoredRepoPaths {
                existing.instances = mergedInstances
                existing.ignoredRepoPaths = filteredIgnoredPaths
                try save(configuration: existing)
            }
            configuration = existing
        }

        if !FileSystem.fileExists(atPath: configURL.path) {
            try save(configuration: configuration)
        }

        if !FileSystem.fileExists(atPath: runtimeURL.path) {
            try save(runtime: .empty)
        }
    }

    func loadConfiguration() -> AssistantConfiguration {
        guard let data = try? Data(contentsOf: configURL),
              let configuration = try? JSONDecoder().decode(AssistantConfiguration.self, from: data) else {
            return .default
        }
        return configuration
    }

    func save(configuration: AssistantConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configURL, options: .atomic)
    }

    func loadRuntime() -> RuntimeState {
        guard let data = try? Data(contentsOf: runtimeURL),
              let runtime = try? JSONDecoder().decode(RuntimeState.self, from: data) else {
            return .empty
        }
        return runtime
    }

    func save(runtime: RuntimeState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runtime)
        try data.write(to: runtimeURL, options: .atomic)
    }

    func logURL(for instance: OpenClawInstance) -> URL {
        logsDirectory.appendingPathComponent("\(instance.id).log")
    }

    func removeInstance(instanceID: String) throws {
        var configuration = loadConfiguration()
        guard let removed = configuration.instances.first(where: { $0.id == instanceID }) else {
            throw ConfigurationError.instanceNotFound(instanceID)
        }

        configuration.instances.removeAll { $0.id == instanceID }
        let normalizedPath = normalizedPath(removed.expandedRepoPath)
        if !configuration.ignoredRepoPaths.contains(normalizedPath) {
            configuration.ignoredRepoPaths.append(normalizedPath)
            configuration.ignoredRepoPaths = normalizedPaths(configuration.ignoredRepoPaths)
        }
        try save(configuration: configuration)

        var runtime = loadRuntime()
        runtime.instances.removeValue(forKey: instanceID)
        try save(runtime: runtime)
    }

    func fullRescan() throws {
        try bootstrapIfNeeded(fullRescan: true)
    }

    @discardableResult
    func updateConfiguration(_ mutate: (inout AssistantConfiguration) -> Void) throws -> AssistantConfiguration {
        var configuration = loadConfiguration()
        mutate(&configuration)
        configuration.ignoredRepoPaths = normalizedPaths(configuration.ignoredRepoPaths)
        configuration.instances.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try save(configuration: configuration)
        return configuration
    }

    private func normalizedPaths(_ paths: [String]) -> [String] {
        Array(Set(paths.map(normalizedPath))).sorted()
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: PathExpander.expand(path)).standardizedFileURL.path.lowercased()
    }
}

private enum ConfigurationError: LocalizedError {
    case instanceNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .instanceNotFound(instanceID):
            return "未找到实例: \(instanceID)"
        }
    }
}
