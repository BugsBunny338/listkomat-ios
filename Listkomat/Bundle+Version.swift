import Foundation

extension Bundle {
    /// Marketing version shown to users, e.g. "2.0.1" (CFBundleShortVersionString).
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Build number, bumped on every App Store upload (CFBundleVersion).
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// "2.0.1 (8)" — version plus build, the form that makes a bug report actionable.
    var versionAndBuild: String {
        "\(appVersion) (\(buildNumber))"
    }
}
