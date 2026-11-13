import Foundation

/// The help pages' home on the web: waycar.dev, where the bundled pages are
/// published at `/help/<slug>`.
enum HelpWeb {
    static let base: URL = {
        guard let url = URL(string: "https://waycar.dev") else {
            preconditionFailure("https://waycar.dev is a valid URL literal")
        }
        return url
    }()

    /// `https://waycar.dev/help/<slug>`; nil unless `slug` is a help slug
    /// (lowercase letters and digits joined by single hyphens).
    static func pageURL(_ slug: String) -> URL? {
        guard isSlug(slug) else { return nil }
        return base.appending(path: "help").appending(path: slug)
    }

    /// The site's help slug shape, as its content schema enforces it.
    static func isSlug(_ text: String) -> Bool {
        !text.isEmpty
            && text.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part.unicodeScalars.allSatisfy(slugScalars.contains)
            }
    }

    private static let slugScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
}
