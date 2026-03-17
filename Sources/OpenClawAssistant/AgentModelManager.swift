import Foundation

struct OpenClawModelOption: Hashable {
    let id: String
    let name: String?

    var displayTitle: String {
        guard let name,
              !name.isEmpty,
              name.caseInsensitiveCompare(id) != .orderedSame else {
            return id
        }
        return "\(id)  \(name)"
    }
}

struct OpenClawAgentModelInfo: Hashable {
    let agentID: String
    let displayName: String
    let currentModelID: String?
    let availableModels: [OpenClawModelOption]
}

struct OpenClawInstanceModelCatalog {
    let configURL: URL
    let agents: [OpenClawAgentModelInfo]
}

final class AgentModelManager {
    private let implicitDefaultAgentID = "default"

    func catalog(for instance: OpenClawInstance) throws -> OpenClawInstanceModelCatalog {
        let configURL = try resolveConfigURL(for: instance)
        let root = try loadRootObject(from: configURL)
        return buildCatalog(root: root, configURL: configURL)
    }

    func configURLIfAvailable(for instance: OpenClawInstance) -> URL? {
        try? resolveConfigURL(for: instance)
    }

    @discardableResult
    func setPrimaryModel(
        _ modelID: String,
        forAgent agentID: String,
        in instance: OpenClawInstance
    ) throws -> OpenClawInstanceModelCatalog {
        try setPrimaryModels([agentID: modelID], in: instance)
    }

    @discardableResult
    func setPrimaryModels(
        _ assignments: [String: String],
        in instance: OpenClawInstance
    ) throws -> OpenClawInstanceModelCatalog {
        guard !assignments.isEmpty else {
            return try catalog(for: instance)
        }

        let configURL = try resolveConfigURL(for: instance)
        var root = try loadRootObject(from: configURL)
        let existingCatalog = buildCatalog(root: root, configURL: configURL)
        var didChange = false

        for (agentID, modelID) in assignments.sorted(by: { $0.key < $1.key }) {
            let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedModelID.isEmpty else {
                throw AgentModelManagerError.invalidModelIdentifier
            }

            guard let agent = existingCatalog.agents.first(where: { $0.agentID == agentID }) else {
                throw AgentModelManagerError.agentNotFound(agentID)
            }

            let knownModelIDs = Set(agent.availableModels.map(\.id))
            if !knownModelIDs.contains(normalizedModelID) && agent.currentModelID != normalizedModelID {
                throw AgentModelManagerError.modelNotAvailable(normalizedModelID)
            }

            if agent.currentModelID == normalizedModelID {
                continue
            }

            var agents = root["agents"] as? [String: Any] ?? [:]
            if agentID == implicitDefaultAgentID {
                var defaults = agents["defaults"] as? [String: Any] ?? [:]
                defaults["model"] = updatedModelValue(defaults["model"], newPrimary: normalizedModelID)
                agents["defaults"] = defaults
                root["agents"] = agents
            } else {
                var list = agents["list"] as? [[String: Any]] ?? []
                guard let index = list.firstIndex(where: {
                    (($0["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == agentID
                }) else {
                    throw AgentModelManagerError.agentNotFound(agentID)
                }

                var entry = list[index]
                entry["model"] = updatedModelValue(entry["model"], newPrimary: normalizedModelID)
                list[index] = entry
                agents["list"] = list
                root["agents"] = agents
            }
            didChange = true
        }

        if didChange {
            try saveRootObject(root, to: configURL)
            return buildCatalog(root: root, configURL: configURL)
        }

        return existingCatalog
    }

    private func buildCatalog(root: [String: Any], configURL: URL) -> OpenClawInstanceModelCatalog {
        let agentsRoot = root["agents"] as? [String: Any] ?? [:]
        let defaults = agentsRoot["defaults"] as? [String: Any] ?? [:]
        let defaultModelID = resolvePrimaryModelID(from: defaults["model"])

        var modelOptions = collectModelOptions(from: root)
        if let defaultModelID {
            modelOptions[defaultModelID] = modelOptions[defaultModelID] ?? OpenClawModelOption(id: defaultModelID, name: nil)
        }

        let list = agentsRoot["list"] as? [[String: Any]] ?? []
        let agents: [OpenClawAgentModelInfo]

        if list.isEmpty {
            let currentModelID = defaultModelID
            if let currentModelID {
                modelOptions[currentModelID] = modelOptions[currentModelID] ?? OpenClawModelOption(id: currentModelID, name: nil)
            }
            agents = [
                OpenClawAgentModelInfo(
                    agentID: implicitDefaultAgentID,
                    displayName: "默认智能体",
                    currentModelID: currentModelID,
                    availableModels: sortedModelOptions(modelOptions, currentModelID: currentModelID)
                )
            ]
        } else {
            agents = list.compactMap { entry in
                guard let rawID = entry["id"] as? String else {
                    return nil
                }
                let agentID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !agentID.isEmpty else {
                    return nil
                }

                let displayName = (entry["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let currentModelID = resolvePrimaryModelID(from: entry["model"]) ?? defaultModelID
                if let currentModelID {
                    modelOptions[currentModelID] = modelOptions[currentModelID] ?? OpenClawModelOption(id: currentModelID, name: nil)
                }

                return OpenClawAgentModelInfo(
                    agentID: agentID,
                    displayName: (displayName?.isEmpty == false ? displayName! : agentID),
                    currentModelID: currentModelID,
                    availableModels: sortedModelOptions(modelOptions, currentModelID: currentModelID)
                )
            }
        }

        return OpenClawInstanceModelCatalog(configURL: configURL, agents: agents)
    }

    private func collectModelOptions(from root: [String: Any]) -> [String: OpenClawModelOption] {
        var options: [String: OpenClawModelOption] = [:]

        if let defaultsModels = ((root["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any] {
            for (key, value) in defaultsModels {
                let alias = (value as? [String: Any])?["alias"] as? String
                options[key] = OpenClawModelOption(id: key, name: alias)
            }
        }

        if let providers = ((root["models"] as? [String: Any])?["providers"] as? [String: Any]) {
            for (providerID, value) in providers {
                guard let provider = value as? [String: Any],
                      let models = provider["models"] as? [[String: Any]] else {
                    continue
                }

                for model in models {
                    guard let localModelID = model["id"] as? String else {
                        continue
                    }
                    let fullModelID = "\(providerID)/\(localModelID)"
                    let name = model["name"] as? String
                    options[fullModelID] = OpenClawModelOption(id: fullModelID, name: name)
                }
            }
        }

        return options
    }

    private func sortedModelOptions(
        _ options: [String: OpenClawModelOption],
        currentModelID: String?
    ) -> [OpenClawModelOption] {
        options.values.sorted { lhs, rhs in
            if lhs.id == currentModelID { return true }
            if rhs.id == currentModelID { return false }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    private func updatedModelValue(_ existing: Any?, newPrimary: String) -> Any {
        if var dictionary = existing as? [String: Any] {
            dictionary["primary"] = newPrimary
            return dictionary
        }
        return [
            "primary": newPrimary
        ]
    }

    private func resolvePrimaryModelID(from value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let dictionary = value as? [String: Any],
           let primary = dictionary["primary"] as? String {
            let trimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    private func resolveConfigURL(for instance: OpenClawInstance) throws -> URL {
        let candidates = configPathCandidates(for: instance)
            .map { URL(fileURLWithPath: PathExpander.expand($0)) }

        if let configURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return configURL
        }

        throw AgentModelManagerError.configNotFound(instance.name)
    }

    private func configPathCandidates(for instance: OpenClawInstance) -> [String] {
        var candidates: [String] = []

        if let explicit = instance.env["OPENCLAW_CONFIG_PATH"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let explicit = instance.env["CLAWDBOT_CONFIG_PATH"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let stateDir = instance.env["OPENCLAW_STATE_DIR"], !stateDir.isEmpty {
            candidates.append((stateDir as NSString).appendingPathComponent("openclaw.json"))
        }

        let repoCandidate = URL(fileURLWithPath: instance.expandedRepoPath)
            .appendingPathComponent("data/.openclaw/openclaw.json")
            .path
        candidates.append(repoCandidate)

        if let profile = inferredProfile(for: instance), !profile.isEmpty {
            candidates.append("~/.openclaw-\(profile)/openclaw.json")
        }

        candidates.append("~/.openclaw/openclaw.json")

        var deduped: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            let normalized = PathExpander.expand(candidate)
            if seen.insert(normalized).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private func inferredProfile(for instance: OpenClawInstance) -> String? {
        if let profileIndex = instance.startCommand.firstIndex(of: "--profile"),
           instance.startCommand.indices.contains(profileIndex + 1) {
            return instance.startCommand[profileIndex + 1]
        }

        if let profile = instance.env["OPENCLAW_PROFILE"], !profile.isEmpty {
            return profile
        }

        return nil
    }

    private func loadRootObject(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = object as? [String: Any] else {
            throw AgentModelManagerError.invalidConfigFile(url.path)
        }
        return root
    }

    private func saveRootObject(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

private enum AgentModelManagerError: LocalizedError {
    case configNotFound(String)
    case invalidConfigFile(String)
    case agentNotFound(String)
    case modelNotAvailable(String)
    case invalidModelIdentifier

    var errorDescription: String? {
        switch self {
        case let .configNotFound(instanceName):
            return "没找到 \(instanceName) 的 openclaw.json 配置文件。"
        case let .invalidConfigFile(path):
            return "配置文件不是有效的 JSON：\(path)"
        case let .agentNotFound(agentID):
            return "未找到智能体：\(agentID)"
        case let .modelNotAvailable(modelID):
            return "该模型不在当前实例可识别的候选列表里：\(modelID)"
        case .invalidModelIdentifier:
            return "模型标识不能为空。"
        }
    }
}
