import Foundation
import Testing

@testable import Waycar

@Test("directory paths accept absolute quotable paths")
func directoryPathsAcceptAbsoluteQuotablePaths() {
    #expect(HostSSHSession.validatedDirectoryPath("/") == "/")
    #expect(HostSSHSession.validatedDirectoryPath("/photos") == "/photos")
    #expect(
        HostSSHSession.validatedDirectoryPath("/a/b/c") == "/a/b/c")
    #expect(
        HostSSHSession.validatedDirectoryPath("/with space") == "/with space")
    #expect(
        HostSSHSession.validatedDirectoryPath("/dotted.name_v2-0")
            == "/dotted.name_v2-0")
}

@Test("directory paths reject empty, relative, and unquotable paths")
func directoryPathsRejectUnsafePaths() {
    #expect(HostSSHSession.validatedDirectoryPath("") == nil)
    #expect(HostSSHSession.validatedDirectoryPath("relative/path") == nil)
    #expect(HostSSHSession.validatedDirectoryPath("~") == nil)
    #expect(
        HostSSHSession.validatedDirectoryPath("/with'quote") == nil)
    #expect(
        HostSSHSession.validatedDirectoryPath("/with\\backslash") == nil)
    #expect(
        HostSSHSession.validatedDirectoryPath("/with\0nul") == nil)
    #expect(
        HostSSHSession.validatedDirectoryPath("/with\nnewline") == nil)
    #expect(
        HostSSHSession.validatedDirectoryPath("/with\ttab") == nil)
    #expect(
        HostSSHSession.validatedDirectoryPath("/with\u{7F}del") == nil)
}

@Test("invalid directory paths are not retryable")
func invalidDirectoryPathsAreNotRetryable() {
    #expect(
        TransportError.invalidDirectoryPath(path: "/x").isRetryable == false)
}
