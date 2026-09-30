import Foundation

enum AppInfo {
    static let name = "Headroom"
    static let publisher = "Keystone Science"
    static let contributors = "Nathan Stone · Jackson Stone"
    static let repositoryURL = URL(string: "https://github.com/TheMakerOfWorlds/codex-vitals")!
    static let homepageURL = repositoryURL
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let updateFeedURL = URL(string: "https://raw.githubusercontent.com/TheMakerOfWorlds/codex-vitals/main/updates/appcast.xml")!

    static var isPersonalBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CodexVitalsPersonalBuild") as? Bool ?? false
    }

    static var versionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "Unknown"
        }
        let label = version.hasPrefix("v") ? version : "v\(version)"
        return isPersonalBuild ? "\(label) · Personal" : label
    }
}
