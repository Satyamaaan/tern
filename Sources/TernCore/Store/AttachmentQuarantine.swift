import CoreServices
import Foundation

/// Marks files saved from mail as downloaded, the way Mail and Safari do: Gatekeeper then checks
/// them, and macOS asks before an app, script, `.terminal` or `.fileloc` from an email runs.
public enum AttachmentQuarantine {
    /// Sets the quarantine flag on `url` (agent "Tern", type email attachment) unless it already has
    /// one. Says nothing about the sender. Returns false when it couldn't be set.
    @discardableResult
    public static func mark(_ url: URL) -> Bool {
        var url = url
        if isMarked(url) { return true }
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Tern",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        do {
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    /// True when `url` carries a quarantine flag.
    public static func isMarked(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties ?? nil) != nil
    }
}
