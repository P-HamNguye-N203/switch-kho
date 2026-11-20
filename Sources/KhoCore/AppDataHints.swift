/// Extra `~/Library` folder names per bundle id, for apps whose folders are not named after
/// the app. Bundle ids were read from the apps installed on this machine, never guessed.
public enum AppDataHints {
    public static let byBundleID: [String: [String]] = [
        "com.docker.docker": ["Docker Desktop"],
        "com.google.Chrome": ["Google"],
        "com.vng.zalo": ["ZaloData", "Zalo"],
        "com.anthropic.claudefordesktop": ["Claude"],
        "com.hnc.Discord": ["discord"],
        "com.mojang.minecraftlauncher": ["minecraft"],
    ]
}
