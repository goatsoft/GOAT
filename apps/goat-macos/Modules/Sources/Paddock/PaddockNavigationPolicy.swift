import Foundation
import JUDAS

/// Only a deliberate web link can leave the artifact viewer. Scripts, forms, custom URL
/// schemes and popups cannot launch applications or replace the top-level preview.
public enum PaddockNavigationPolicy {
    public enum Decision { case allow, cancel, external }

    public static func decide(url: URL, userLink: Bool, mainFrame: Bool, offGrid: Bool, bundleURL: URL?) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        let web = scheme == "https" || scheme == "http"
        let local = Judas.isLoopback(url)
        if userLink {
            return web && (!offGrid || local) ? .external : .cancel
        }
        if scheme == "about" { return .allow }
        if mainFrame {
            guard url.isFileURL, let bundleURL, bundleURL.isFileURL else { return .cancel }
            // WebKit supplies an absolute URL; Bundle can retain a relative base.
            return url.standardizedFileURL == bundleURL.standardizedFileURL ? .allow : .cancel
        }
        if web { return !offGrid || local ? .allow : .cancel }
        return ["data", "blob"].contains(scheme) ? .allow : .cancel
    }
}
