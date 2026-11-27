import Foundation

/// Reading the GitHub "latest release" answer. Kept here, without networking, so it is tested.
public enum ReleaseFeed {
    public static let repository = "maxbenschop/maben-sweep"
    public static let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// The file in each release that installed copies update from.
    public static let assetName = "Maben-Sweep.zip"

    public struct Release: Equatable, Sendable {
        public let version: String
        public let notes: String
        public let zip: URL
        /// The page to open in the browser: always an `https://github.com/…` address.
        public let page: URL
    }

    /// This repository's releases, for when the feed names a page that isn't on GitHub.
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    /// An `https://github.com/…` address. What the feed says is only data: the app downloads
    /// from and opens nothing else, whatever the answer contains. (As in Maben Awake.)
    static func isOnGitHub(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && url.user == nil && (url.port ?? 443) == 443 && !url.pathComponents.contains("..")
    }

    /// Nil for anything that isn't a published release with the update file attached. The file
    /// has to be a download of this repository's releases on github.com, over https.
    public static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              isOnGitHub(zip), zip.path.hasPrefix("/\(repository)/releases/download/")
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // The page is opened in the browser, so it is this repository's own releases page unless
        // GitHub names another of its pages.
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)).flatMap { isOnGitHub($0) ? $0 : nil } ?? releasesPage
        return Release(version: version, notes: (json["body"] as? String) ?? "", zip: zip, page: page)
    }

    /// Release notes for showing: Markdown, where a link only stays a link when it goes to an
    /// `https` address. Any other link is shown as plain text.
    public static func attributedNotes(_ notes: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(notes)
        }
        for run in text.runs {
            if let link = run.link, link.scheme?.lowercased() != "https" { text[run.range].link = nil }
        }
        return text
    }

    /// Numeric comparison of dotted versions: 1.10 > 1.9, 1.0.1 > 1.0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
