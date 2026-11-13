import Foundation

/// A Host Markdown file read for the rendered preview sheet (#147). The text
/// is remote-chosen and untrusted; it is only ever parsed and displayed,
/// never executed, and its images are never fetched.
struct MarkdownFilePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Absolute, resolved Host path that was read.
    let remotePath: String
    /// File content, UTF-8 decoded lossily.
    let text: String
    /// Scratch copy for the share sheet; `TerminalFilePreviewStore` owns and
    /// removes it.
    let localURL: URL

    /// Last path component of `remotePath`, used as the sheet title.
    var name: String {
        (remotePath as NSString).lastPathComponent
    }

    /// `remotePath`'s parent directory; relative links inside the document
    /// resolve against it.
    var directory: String {
        (remotePath as NSString).deletingLastPathComponent
    }
}

/// What a file link inside a rendered Markdown document opened as: another
/// Markdown document pushed onto the sheet, or anything else in Quick Look.
enum LinkedFilePreview: Equatable, Sendable {
    case markdown(MarkdownFilePreview)
    case quickLook(URL)
}
