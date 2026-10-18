import Foundation
import Testing
@testable import Tern

// MARK: - Release notes

@Test func releaseNotesReadTheAppcastHTML() {
    let notes = ReleaseNotes("""
    <h3>Reading</h3>
    <p>Small <b>fixes</b> &amp; one   new thing.</p>
    <ul><li>Tern updates <code>itself</code>.</li><li>Drag &#8220;Tern&#8221; to Applications&#x2026;</li></ul>
    """)
    #expect(notes.lines == [
        .heading("Reading"),
        .paragraph("Small fixes & one new thing."),
        .bullet("Tern updates itself."),
        .bullet("Drag “Tern” to Applications…"),
    ])
}

@Test func releaseNotesReadPlainText() {
    let notes = ReleaseNotes("# 0.2.1\nA few fixes,\nall small.\n\n- One\n* Two")
    #expect(notes.lines == [.heading("0.2.1"), .paragraph("A few fixes, all small."), .bullet("One"), .bullet("Two")])
}

@Test func releaseNotesKeepTextOutsideBlocksAndDropEmptyOnes() {
    #expect(ReleaseNotes("Loose text<ul><li> </li></ul>").lines == [.paragraph("Loose text")])
    #expect(ReleaseNotes(nil).isEmpty)
    #expect(ReleaseNotes("  \n ").isEmpty)
}

// MARK: - Where the app lives

private let home = URL(fileURLWithPath: "/Users/someone")

private func location(_ path: String, diskImage: String? = nil, translocated: Bool = false) -> AppLocation {
    AppLocation.classify(URL(fileURLWithPath: path), home: home,
                         diskImageVolume: diskImage.map { URL(fileURLWithPath: $0) }, isTranslocated: translocated)
}

@Test func applicationsFoldersCount() {
    #expect(location("/Applications/Tern.app").kind == .applications)
    #expect(location("/Applications/Mail/Tern.app").kind == .applications)
    #expect(location("/Users/someone/Applications/Tern.app").kind == .applications)
    #expect(location("/ApplicationsOld/Tern.app").kind == .elsewhere)
    #expect(location("/Users/someone/Downloads/Tern.app").kind == .elsewhere)
}

@Test func aDiskImageIsReadOnlyAndEjectable() {
    let dmg = location("/Volumes/Tern/Tern.app", diskImage: "/Volumes/Tern")
    #expect(dmg.kind == .diskImage)
    #expect(dmg.volumeURL?.path == "/Volumes/Tern")
    #expect(dmg.isReadOnly)
    // A real drive under /Volumes is just somewhere else.
    let drive = location("/Volumes/Backup/Tern.app")
    #expect(drive.kind == .elsewhere)
    #expect(drive.volumeURL == nil)
    #expect(!drive.isReadOnly)
}

@Test func aTranslocatedCopyIsNeverInApplications() {
    let copy = location("/Applications/Tern.app", translocated: true)
    #expect(copy.kind == .elsewhere)
    #expect(copy.isReadOnly)
}

// MARK: - Release builds and the move prompt

@Test func onlyBundlesWithAFeedAndKeyAreReleases() {
    let app = URL(fileURLWithPath: "/Applications/Tern.app")
    let keys: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "abc="]
    #expect(ReleaseBuild.isRelease(info: keys, bundleURL: app))
    #expect(!ReleaseBuild.isRelease(info: keys, bundleURL: URL(fileURLWithPath: "/tmp/.build/debug")))
    #expect(!ReleaseBuild.isRelease(info: ["SUFeedURL": "https://example.com/appcast.xml"], bundleURL: app))
    #expect(!ReleaseBuild.isRelease(info: ["SUFeedURL": " ", "SUPublicEDKey": "abc="], bundleURL: app))
    #expect(!ReleaseBuild.isRelease(info: nil, bundleURL: app))
}

@Test func versionComesFromInfoPlist() {
    #expect(AppVersion(info: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2"]) == AppVersion(name: "0.2.0", build: "2"))
    #expect(AppVersion(info: nil) == AppVersion(name: "dev", build: "0"))
}

@MainActor
@Test func theMovePromptAsksOncePerVersion() {
    let options = LaunchOptions(databaseURL: URL(fileURLWithPath: "/tmp/t.sqlite"), isFake: false)
    let downloads = location("/Users/someone/Downloads/Tern.app")
    func asks(_ location: AppLocation = downloads, release: Bool = true, options: LaunchOptions = options, declined: String? = nil) -> Bool {
        MovePrompt.shouldOffer(location: location, isRelease: release, options: options, declinedBuild: declined, build: "3")
    }
    #expect(asks())
    #expect(asks(location("/Volumes/Tern/Tern.app", diskImage: "/Volumes/Tern")))
    #expect(!asks(location("/Applications/Tern.app")))
    #expect(!asks(release: false))
    #expect(!asks(declined: "3"))
    #expect(asks(declined: "2"), "a new version asks again")
    var demo = options
    demo.isFake = true
    #expect(!asks(options: demo))
    var check = options
    check.isCheck = true
    #expect(!asks(options: check))
    var snapshot = options
    snapshot.snapshotDirectory = URL(fileURLWithPath: "/tmp/shots")
    #expect(!asks(options: snapshot))
}

@Test func headlessRunsAreSnapshotsAndChecks() {
    #expect(LaunchOptions.current(arguments: ["Tern", "--check"], environment: [:]).isHeadless)
    #expect(LaunchOptions.current(arguments: ["Tern", "--snapshot", "/tmp/x"], environment: [:]).isHeadless)
    #expect(!LaunchOptions.current(arguments: ["Tern", "--fake"], environment: [:]).isHeadless)
}

// MARK: - Moving

@Test func movingCopiesTheBundleWithoutQuarantine() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tern-move-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Downloads/Tern.app/Contents")
    let applications = root.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    let plist = source.appendingPathComponent("Info.plist")
    try Data("<plist/>".utf8).write(to: plist)
    let flag = "0081;00000000;Safari;"
    #expect(setxattr(plist.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)

    let moved = try AppMover.install(source.deletingLastPathComponent(), into: applications)
    #expect(moved.path == applications.appendingPathComponent("Tern.app").path)
    let copied = moved.appendingPathComponent("Contents/Info.plist")
    #expect(try Data(contentsOf: copied) == Data("<plist/>".utf8))
    #expect(getxattr(copied.path, "com.apple.quarantine", nil, 0, 0, 0) == -1, "quarantine is gone")
    #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Tern.app"], "nothing left from staging")
    #expect(FileManager.default.fileExists(atPath: plist.path), "the original stays until the disk image is ejected or the user deletes it")
}
