import Foundation

/// The bounded read behind previewing a file a terminal line named.
///
/// The path comes from remote terminal output, so it is untrusted. It never
/// reaches a shell: the read is SFTP alone, where a path is data. Only a
/// regular file is read, from one open handle whose type and size were
/// checked with `fstat`, and never more than ``maximumBytes``.
enum RemoteFilePreview {
    /// Large enough for screenshots, PDFs, and logs; small enough that a
    /// mistaken tap on a build artifact cannot pull a disk image over a
    /// phone connection.
    static let maximumBytes = 25 * 1024 * 1024
}

enum RemoteFilePreviewError: Error, Equatable, Sendable, LocalizedError {
    /// The path is not absolute once `~` and the working directory are
    /// applied, or its home or working directory is unknown.
    case unresolvablePath
    case missing
    case directory
    case notRegularFile
    case unreadable
    case tooLarge(size: UInt64, limit: Int)
    /// A `file:` link names another machine (`file://build-box/…`), so
    /// there is nothing on this Host to read.
    case onAnotherMachine(host: String)

    var errorDescription: String? {
        switch self {
        case .unresolvablePath:
            "Waycar couldn't tell which folder this path is in."
        case .missing:
            "There is no file at this path on the Host."
        case .directory:
            "This path is a folder, not a file."
        case .notRegularFile:
            "This path is a device, pipe, or socket, not a file."
        case .unreadable:
            "You don't have permission to read this file on the Host."
        case .tooLarge(let size, let limit):
            "This file is \(Self.bytes(size)), larger than the \(Self.bytes(UInt64(limit))) preview limit."
        case .onAnotherMachine(let host):
            "This link names a file on “\(host)”. Only links to this Host, with no host name "
                + "or localhost, can be previewed."
        }
    }

    /// Whether another reading of the same tapped text is still worth a
    /// read: this one could not be placed, or named nothing or a folder.
    /// Any other refusal is about a file that is there.
    var leavesAnotherReadingToTry: Bool {
        switch self {
        case .unresolvablePath, .missing, .directory: true
        case .notRegularFile, .unreadable, .tooLarge, .onAnotherMachine: false
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
