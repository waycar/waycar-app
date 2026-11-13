import Foundation

/// What a file the current Attach's terminal printed is to the status-row
/// strip: a Markdown document the app renders itself (#147), a PDF, or an
/// image. Nothing else an Agent prints — source, plain text, video, audio —
/// is a strip file.
enum TerminalFileKind: Equatable, Hashable, Sendable, CaseIterable {
    case markdown, pdf, image

    /// The kind of the file `path` names, by its extension in any case:
    /// `.md` or `.markdown` (not `.mdx`), `.pdf`, or an image type a chat
    /// shows (`ChatMedia.kind(forPathExtension:)`). Nil for anything else,
    /// a hidden name with no extension (`.md`) included.
    static func kind(forPath path: String) -> TerminalFileKind? {
        let pathExtension = (path as NSString).pathExtension
        if TerminalFilePreviewStore.isMarkdown(pathExtension: pathExtension) {
            return .markdown
        }
        if pathExtension.lowercased() == "pdf" {
            return .pdf
        }
        if ChatMedia.kind(forPathExtension: pathExtension) == .image {
            return .image
        }
        return nil
    }

    /// Whether the file is a document, listed as soon as it is printed and
    /// read only when tapped; an image's thumbnail is fetched up front.
    var isDocument: Bool {
        switch self {
        case .markdown, .pdf: true
        case .image: false
        }
    }
}
