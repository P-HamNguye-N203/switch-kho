import Foundation

public enum AppCatalog {
    public static var defaultDirs: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// Top-level `*.app` bundles in `dirs` (symlinks skipped).
    public static func scan(dirs: [URL] = defaultDirs) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        let fm = FileManager.default
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".app") {
                let url = dir.appendingPathComponent(name)
                if FileOps.isSymlink(url) { continue }
                if let app = read(url) { apps.append(app) }
            }
        }
        return apps
    }

    public static func read(_ url: URL) -> InstalledApp? {
        let contents = url.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String
        else { return nil }
        let fm = FileManager.default
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? fileName
        let owner = (try? fm.attributesOfItem(atPath: url.path)[.ownerAccountID] as? NSNumber)?.intValue
        return InstalledApp(
            url: url, bundleID: bundleID, name: name,
            executableName: (plist["CFBundleExecutable"] as? String) ?? fileName,
            isAppStore: fm.fileExists(atPath: contents.appendingPathComponent("_MASReceipt").path),
            hasSparkle: fm.fileExists(atPath: contents.appendingPathComponent("Frameworks/Sparkle.framework").path),
            isElectron: fm.fileExists(atPath: contents.appendingPathComponent("Frameworks/Electron Framework.framework").path),
            isAdobe: bundleID.hasPrefix("com.adobe."),
            ownerIsRoot: owner == 0,
            lastUsed: FileUsage.effective(url))
    }
}
