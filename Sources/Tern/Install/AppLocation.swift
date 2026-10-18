import DiskArbitration
import Foundation

/// Where the running copy of Tern lives, for the offer to move it to Applications and for the updater (Sparkle
/// can't replace a copy on a read-only disk image).
struct AppLocation: Equatable {
    enum Kind: Equatable {
        /// /Applications or ~/Applications, or a folder inside them.
        case applications
        /// On a mounted disk image (Tern's DMG).
        case diskImage
        /// Somewhere else: Downloads, the Desktop, another drive.
        case elsewhere
    }

    var kind: Kind
    /// Where the bundle really is; for a copy Gatekeeper translocated, the original it was opened from.
    var bundleURL: URL
    /// The disk image's mount point, to eject after moving.
    var volumeURL: URL?
    /// Gatekeeper is running Tern from a randomised read-only path (App Translocation).
    var isTranslocated = false

    /// Sparkle can't update a copy on a disk image or translocated by Gatekeeper.
    var isReadOnly: Bool { kind == .diskImage || isTranslocated }

    /// The folder name for "Tern is running from Downloads."
    var folderName: String {
        FileManager.default.displayName(atPath: bundleURL.deletingLastPathComponent().path)
    }

    /// Where the running app is now.
    static func current(bundleURL: URL = Bundle.main.bundleURL) -> AppLocation {
        let original = Translocation.originalURL(of: bundleURL)
        let source = original ?? bundleURL
        let volume = (try? source.resourceValues(forKeys: [.volumeURLKey]))?.volume
        return classify(source, home: FileManager.default.homeDirectoryForCurrentUser,
                        diskImageVolume: volume.flatMap { isDiskImage($0) ? $0 : nil },
                        isTranslocated: original != nil || bundleURL.path.contains("/AppTranslocation/"))
    }

    /// Sorts a path into a kind; the system lookups are the caller's.
    static func classify(_ bundleURL: URL, home: URL, diskImageVolume: URL?, isTranslocated: Bool) -> AppLocation {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let folders = ["/Applications", home.appendingPathComponent("Applications").resolvingSymlinksInPath().standardizedFileURL.path]
        let kind: Kind
        if let volume = diskImageVolume, path.hasPrefix(volume.standardizedFileURL.path) {
            kind = .diskImage
        } else if !isTranslocated, folders.contains(where: { path.hasPrefix($0 + "/") }) {
            kind = .applications
        } else {
            kind = .elsewhere
        }
        return AppLocation(kind: kind, bundleURL: bundleURL, volumeURL: kind == .diskImage ? diskImageVolume : nil,
                           isTranslocated: isTranslocated)
    }

    /// True when the volume is a mounted disk image rather than a real drive.
    private static func isDiskImage(_ volume: URL) -> Bool {
        guard volume.path != "/", let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any]
        else { return false }
        return (description[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces) == "Disk Image"
    }
}

/// Gatekeeper's App Translocation runs a quarantined app that was never moved from a read-only random path. The
/// calls that map it back to the original are in Security.framework but not in its public headers.
private enum Translocation {
    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> Bool
    private typealias OriginalPath = @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?

    static func originalURL(of url: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(security) }
        guard let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        var translocated = false
        guard unsafeBitCast(isSymbol, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated else { return nil }
        return unsafeBitCast(originalSymbol, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
