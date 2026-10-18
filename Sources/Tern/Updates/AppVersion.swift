import Foundation

/// The running build's version, from Info.plist (build.sh writes both numbers from version.env).
struct AppVersion: Equatable {
    /// What people see, e.g. "0.2.0" (`CFBundleShortVersionString`).
    let name: String
    /// Goes up by one with every release; Sparkle compares it to tell which build is newer (`CFBundleVersion`).
    let build: String

    init(name: String, build: String) {
        self.name = name
        self.build = build
    }

    init(info: [String: Any]?) {
        name = info?["CFBundleShortVersionString"] as? String ?? "dev"
        build = info?["CFBundleVersion"] as? String ?? "0"
    }

    static let current = AppVersion(info: Bundle.main.infoDictionary)
}

/// Release builds carry Sparkle's feed URL and public key in Info.plist (build.sh adds them only when
/// `TERN_RELEASE=1`). Development builds don't, so they never look for updates or offer to move themselves.
enum ReleaseBuild {
    static func isRelease(info: [String: Any]?, bundleURL: URL) -> Bool {
        func present(_ key: String) -> Bool {
            !((info?[key] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        return bundleURL.pathExtension == "app" && present("SUFeedURL") && present("SUPublicEDKey")
    }

    static let isCurrent = isRelease(info: Bundle.main.infoDictionary, bundleURL: Bundle.main.bundleURL)
}
