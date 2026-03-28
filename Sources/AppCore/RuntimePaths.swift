import Foundation

public enum RuntimePaths {
    public static var launchedFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static func workspaceRootCandidate(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicit = environment["OMNIVOICE_WORKSPACE_ROOT"], !explicit.isEmpty {
            return explicit
        }

        if let explicit = environment["PLAYGROUND_WORKSPACE_ROOT"], !explicit.isEmpty {
            return explicit
        }

        let currentDirectory = fileManager.currentDirectoryPath
        if fileManager.fileExists(atPath: "\(currentDirectory)/Package.swift") {
            return currentDirectory
        }

        guard launchedFromAppBundle else {
            return nil
        }

        let bundleURL = Bundle.main.bundleURL
        let candidate = bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        if fileManager.fileExists(atPath: "\(candidate)/Package.swift") {
            return candidate
        }

        return nil
    }

    public static func defaultConfigPath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let environmentPath = environment["OMNIVOICE_CONFIG_PATH"], !environmentPath.isEmpty {
            return environmentPath
        }

        if let environmentPath = environment["PLAYGROUND_CONFIG_PATH"], !environmentPath.isEmpty {
            return environmentPath
        }

        if let workspaceRoot = workspaceRootCandidate(fileManager: fileManager, environment: environment) {
            return "\(workspaceRoot)/Config/app-config.json"
        }

        if let applicationSupportRoot = applicationSupportRoot(fileManager: fileManager) {
            return "\(applicationSupportRoot)/Config/app-config.json"
        }

        return "Config/app-config.json"
    }

    public static func defaultHistoryPath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let environmentPath = environment["OMNIVOICE_HISTORY_PATH"], !environmentPath.isEmpty {
            return environmentPath
        }

        if let environmentPath = environment["PLAYGROUND_HISTORY_PATH"], !environmentPath.isEmpty {
            return environmentPath
        }

        if let workspaceRoot = workspaceRootCandidate(fileManager: fileManager, environment: environment) {
            return "\(workspaceRoot)/Data/history.jsonl"
        }

        if let applicationSupportRoot = applicationSupportRoot(fileManager: fileManager) {
            return "\(applicationSupportRoot)/Data/history.jsonl"
        }

        return "Data/history.jsonl"
    }

    public static func resolveReadableAppRelativePath(
        _ path: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard !path.isEmpty else {
            return path
        }

        if path.hasPrefix("/") {
            return path
        }

        if let workspaceRoot = workspaceRootCandidate(fileManager: fileManager, environment: environment) {
            let workspacePath = "\(workspaceRoot)/\(path)"
            if fileManager.fileExists(atPath: workspacePath) {
                return workspacePath
            }
        }

        if let applicationSupportRoot = applicationSupportRoot(fileManager: fileManager) {
            let applicationSupportPath = "\(applicationSupportRoot)/\(path)"
            if fileManager.fileExists(atPath: applicationSupportPath) {
                return applicationSupportPath
            }
        }

        if let resourcePath = bundledResourcePath(path), fileManager.fileExists(atPath: resourcePath) {
            return resourcePath
        }

        if let applicationSupportRoot = applicationSupportRoot(fileManager: fileManager) {
            return "\(applicationSupportRoot)/\(path)"
        }

        return path
    }

    public static func resolveWritableAppRelativePath(
        _ path: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard !path.isEmpty else {
            return path
        }

        if path.hasPrefix("/") {
            return path
        }

        if let workspaceRoot = workspaceRootCandidate(fileManager: fileManager, environment: environment) {
            return "\(workspaceRoot)/\(path)"
        }

        if let applicationSupportRoot = applicationSupportRoot(fileManager: fileManager) {
            return "\(applicationSupportRoot)/\(path)"
        }

        return path
    }

    public static func bundledConfigPath() -> String? {
        bundledResourcePath("Config/app-config.json")
    }

    private static func bundledResourcePath(_ relativePath: String) -> String? {
        Bundle.main.resourceURL?.appendingPathComponent(relativePath).path
    }

    private static func applicationSupportRoot(
        fileManager: FileManager = .default
    ) -> String? {
        guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let appName =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
            Bundle.main.bundleURL.deletingPathExtension().lastPathComponent

        guard !appName.isEmpty else {
            return nil
        }

        let currentRoot = baseURL.appendingPathComponent(appName, isDirectory: true).path
        if fileManager.fileExists(atPath: currentRoot) {
            return currentRoot
        }

        for legacyName in legacyApplicationSupportNames(currentAppName: appName) {
            let legacyRoot = baseURL.appendingPathComponent(legacyName, isDirectory: true).path
            if fileManager.fileExists(atPath: legacyRoot) {
                return legacyRoot
            }
        }

        return currentRoot
    }

    private static func legacyApplicationSupportNames(currentAppName: String) -> [String] {
        guard currentAppName != "Playground" else {
            return []
        }

        return ["Playground"]
    }
}
