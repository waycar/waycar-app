import Foundation
import Testing

@testable import Waycar

/// What a link Ghostty found in remote output may become. The raw strings are
/// shaped like Ghostty's matches and OSC 8 targets.
struct TerminalLinkTargetTests {
    @Test func webLinksPassOnlyThroughTheHTTPPolicy() throws {
        #expect(
            TerminalLinkTarget("https://example.com/a?b=1#c")
                == .web(try #require(URL(string: "https://example.com/a?b=1#c"))))
        #expect(
            TerminalLinkTarget("HTTP://Example.com")
                == .web(try #require(URL(string: "HTTP://Example.com"))))
        // Untrusted output never reaches another app or a local handler.
        for refused in [
            "mailto:someone@example.com", "tel:5551234", "ssh://host/path",
            "javascript:alert(1)", "x-callback-url://run", "https://", "magnet:?xt=urn:btih:1",
        ] {
            #expect(TerminalLinkTarget(refused) == nil, "\(refused)")
        }
    }

    /// An OSC 8 target is exactly what the program asked to open: sentence
    /// trimming is for text matches, and Ghostty already does it for those.
    @Test func webTargetsAreTakenAsGiven() throws {
        #expect(
            TerminalLinkTarget("https://en.wikipedia.org/wiki/Rust_(video_game)")
                == .web(try #require(URL(string: "https://en.wikipedia.org/wiki/Rust_(video_game)"))))
    }

    @Test func pathsSplitTheirEditorPosition() {
        #expect(
            TerminalLinkTarget("src/foo/bar.swift:12:3")
                == .file(TerminalFileReference(path: "src/foo/bar.swift", line: 12, column: 3)))
        #expect(
            TerminalLinkTarget("/var/log/system.log:40")
                == .file(TerminalFileReference(path: "/var/log/system.log", line: 40)))
        #expect(
            TerminalLinkTarget("./a:b/c.txt")
                == .file(TerminalFileReference(path: "./a:b/c.txt")))
        // Only two trailing numbers are a position; a third is the name.
        #expect(
            TerminalLinkTarget("/logs/1:2:3")
                == .file(TerminalFileReference(path: "/logs/1", line: 2, column: 3)))
    }

    /// `name.ext:line` is a file and its position, not a URL scheme — but
    /// only where the name is one a bare name may be at all.
    @Test func aBareNameWithAPositionIsNotAScheme() {
        #expect(TerminalLinkTarget("foo.png:12") == .file(TerminalFileReference(path: "foo.png", line: 12)))
        // The sentence's punctuation after the position is not part of it.
        #expect(TerminalLinkTarget("foo.png:12.") == .file(TerminalFileReference(path: "foo.png", line: 12)))
        #expect(
            TerminalLinkTarget("foo.png:12:3).")
                == .file(TerminalFileReference(path: "foo.png", line: 12, column: 3)))
        #expect(
            TerminalLinkTarget("(foo.png:12:3).")
                == .file(TerminalFileReference(path: "foo.png", line: 12, column: 3)))
        for text in ["notes.txt:3", "localhost:8080", "tel:5551234", "foo.png:12:3:4"] {
            #expect(TerminalLinkTarget(text) == nil, "\(text)")
        }
        #expect(!TerminalLinkTarget.isFileURL("file:12"))
    }

    @Test func prosePunctuationIsNotPartOfAPath() {
        #expect(TerminalLinkTarget("./out.png!") == .file(TerminalFileReference(path: "./out.png")))
        #expect(TerminalLinkTarget("~/notes.md;") == .file(TerminalFileReference(path: "~/notes.md")))
        #expect(
            TerminalLinkTarget("src/main.rs:7:")
                == .file(TerminalFileReference(path: "src/main.rs", line: 7)))
        #expect(TerminalLinkTarget("(docs/a.pdf).") == .file(TerminalFileReference(path: "docs/a.pdf")))
        #expect(TerminalLinkTarget("\"~/a b.txt\"") == .file(TerminalFileReference(path: "~/a b.txt")))
        #expect(TerminalLinkTarget("docs/a.pdf)") == .file(TerminalFileReference(path: "docs/a.pdf")))
        #expect(
            TerminalLinkTarget("build/out(1).txt")
                == .file(TerminalFileReference(path: "build/out(1).txt")))
    }

    /// Ghostty's matcher runs on across a blank while text follows. After a
    /// name with a known file extension, `. ` or `, ` starts the sentence.
    @Test func theSentenceAfterAPathIsNotPartOfIt() {
        #expect(TerminalLinkTarget("/tmp/a.png. Done.") == .file(TerminalFileReference(path: "/tmp/a.png")))
        #expect(
            TerminalLinkTarget("src/a.swift:12, then b.") == .file(TerminalFileReference(path: "src/a.swift", line: 12)))
        #expect(
            TerminalLinkTarget("~/My Docs/a.b/c.png. Next")
                == .file(TerminalFileReference(path: "~/My Docs/a.b/c.png")))
        // With no known extension before it, the blank is the path's own.
        #expect(
            TerminalLinkTarget("~/v1.2. notes/x.png") == .file(TerminalFileReference(path: "~/v1.2. notes/x.png")))
    }

    /// Only a local `file:` URL names a path on this Host; a named host
    /// could be any machine the output claims.
    @Test func fileURLsNameOnlyThisHost() {
        #expect(
            TerminalLinkTarget("file:///Users/me/Screen%20Shot.png")
                == .file(TerminalFileReference(path: "/Users/me/Screen Shot.png")))
        #expect(
            TerminalLinkTarget("file://LOCALHOST/tmp/report.pdf")
                == .file(TerminalFileReference(path: "/tmp/report.pdf")))
        #expect(TerminalLinkTarget("file://build-box/etc/passwd") == nil)
        #expect(TerminalLinkTarget.isFileURL(" FILE:///tmp/a"))
        #expect(!TerminalLinkTarget.isFileURL("/tmp/file:1"))
    }

    /// The machine a refused `file:` URL names, so a tap can say why it
    /// does nothing — percent-encoded, so a character that reorders or
    /// imitates text shows as its code. Any spelling of `localhost` is this
    /// Host, as it is when the link is read.
    @Test func aFileURLOnAnotherMachineNamesIt() {
        #expect(TerminalLinkTarget.otherMachine(ofFileURL: "file://build-box/etc/passwd") == "build-box")
        #expect(TerminalLinkTarget.otherMachine(ofFileURL: "file://%E2%80%AEevil/x") == "%E2%80%AEevil")
        #expect(TerminalLinkTarget.otherMachine(ofFileURL: "file://b\u{FC}ild/x") == "b%C3%BCild")
        for text in [
            "file:///etc/hosts", "file://localhost/etc/hosts", "file://LOCALHOST/x", "file://%6Cocalhost/x",
            "https://build-box/x", "/etc/hosts",
        ] {
            #expect(TerminalLinkTarget.otherMachine(ofFileURL: text) == nil, "\(text)")
        }
        #expect(TerminalLinkTarget("file://%6Cocalhost/tmp/a.png") == .file(TerminalFileReference(path: "/tmp/a.png")))
    }

    /// A format character draws nothing, or reorders what is drawn: a path
    /// holding one is not the text on screen, so it is no link.
    @Test func pathsWithFormatCharactersAreNotFiles() {
        for text in ["~/a\u{202E}gnp.txt", "~/shot\u{200B}.png", "src/\u{2066}a.swift", "file:///tmp/a%E2%80%AEb.png"] {
            #expect(TerminalLinkTarget(text) == nil, "\(text.debugDescription)")
        }
    }

    /// A `..` after a name climbs back out of it, undoing text the path
    /// draws; leading `..` only climbs from the pane's directory. Any
    /// reading counts, fallbacks included.
    @Test func aPathClimbsBackOutWithADotDotAfterAName() {
        for path in [
            "~/ok/shot.png/../../.ssh/id_ed25519", "a/../b", "./a/../b", "~/..", "$HOME/../x",
            "../../a/../b", "~/Pictures/export../../../shot.png/../.ssh/key", "~/ok/shot.png /../x",
        ] {
            #expect(TerminalFileReference(path: path).climbsBackOut, "\(path)")
        }
        for path in ["../../x/shot.png", "/../etc/hosts", "./out/img.png", "a/./b", "a/...b/c", "export../x", "~/a..b"] {
            #expect(!TerminalFileReference(path: path).climbsBackOut, "\(path)")
        }
        #expect(TerminalFileReference(path: "~/a.png", fallbackPaths: ["x/../y.png"]).climbsBackOut)
    }

    /// The confirmation spells out where a hidden target leads: the full
    /// address, and the host a look-alike name could hide shown
    /// percent-encoded.
    @Test func confirmationsNameTheRealDestination() throws {
        let url = try #require(URL(string: "https://github.com.login.evil.example/pr/42"))
        #expect(
            TerminalLinkTarget.web(url).confirmationDetail(workingDirectory: nil, homeDirectory: nil)
                .contains("https://github.com.login.evil.example/pr/42"))
        let lookalike = try #require(URL(string: "https://g%C3%AFthub.com/"))
        let detail = TerminalLinkTarget.web(lookalike).confirmationDetail(workingDirectory: nil, homeDirectory: nil)
        #expect(detail.contains("g%C3%AFthub.com"))
        #expect(!detail.contains("g\u{EF}thub.com"))
        #expect(
            TerminalLinkTarget.file(TerminalFileReference(path: "../x/.env"))
                .confirmationDetail(workingDirectory: "/srv/app", homeDirectory: nil) == "/srv/x/.env")
        // A `~` path is shown where it lands, `..` above the home included.
        #expect(
            TerminalLinkTarget.file(TerminalFileReference(path: "~/ok/shot.png/../../../.ssh/id_ed25519"))
                .confirmationDetail(workingDirectory: "/srv/app", homeDirectory: "/home/me")
                == "/home/.ssh/id_ed25519")
    }

    /// A link with no host — a `mailto:` from a Markdown file — is shown as
    /// its address alone, not an empty `scheme://` line; an http link keeps
    /// its scheme and host line.
    @Test func aConfirmationWithoutAHostShowsOnlyTheAddress() throws {
        let mail = try #require(URL(string: "mailto:me@example.com?subject=hi"))
        #expect(
            TerminalLinkTarget.web(mail).confirmationDetail(workingDirectory: nil, homeDirectory: nil)
                == "mailto:me@example.com?subject=hi")
        let web = try #require(URL(string: "https://example.com/a"))
        #expect(
            TerminalLinkTarget.web(web).confirmationDetail(workingDirectory: nil, homeDirectory: nil)
                == "https://example.com\n\nhttps://example.com/a")
    }

    /// A path has the shape Ghostty's matcher gives one: rooted, or with a
    /// dot in it. Prose with a slash is not a file to fetch.
    @Test func pathsAreRootedOrDotted() {
        for path in ["/etc/hosts", "./build", "../x", "~/code", "$HOME/a", ".config/app", "docs/a.pdf"] {
            #expect(TerminalLinkTarget(path) == .file(TerminalFileReference(path: path)), "\(path)")
        }
        for prose in ["and/or", "I/O", "TCP/IP", "24/7", "2026/09/26", "and/or.", "~", "$TMPDIR/a"] {
            #expect(TerminalLinkTarget(prose) == nil, "\(prose)")
        }
    }

    /// A bare word with a dot is far more often prose than a file the user
    /// means; a line break or control character is never part of one path.
    @Test func wordsAndMultilineTextAreNotFiles() {
        for text in [
            "v1.2.3", "Node.js", ".png", "a shot.png", "", "   ",
            "src/a.swift\nsrc/b.swift", "a/\u{1B}[31mb",
        ] {
            #expect(TerminalLinkTarget(text) == nil, "\(text.debugDescription)")
        }
    }

    /// …except a picture, PDF, or recording named without a directory, as
    /// `ls` and agents print them (`Read(shot.png)`): Ghostty's matcher
    /// skips those, and they resolve against the pane's directory.
    @Test func bareMediaNamesAreFiles() {
        for name in ["shot.png", "Report.PDF", "clip.mov", "IMG_0001.HEIC", "a.b.jpeg"] {
            #expect(TerminalLinkTarget(name) == .file(TerminalFileReference(path: name)), "\(name)")
        }
        #expect(TerminalLinkTarget("(shot.png).") == .file(TerminalFileReference(path: "shot.png")))
        // A glob or a template names no one file.
        for pattern in ["*.png", "shot?.png", "[ab].png", "frame_%04d.png", "$f.png"] {
            #expect(TerminalLinkTarget(pattern) == nil, "\(pattern)")
        }
    }

    /// …and a Markdown document named without a directory (`README.md`),
    /// which agents print as they write it and the app renders itself. MDX
    /// is not Markdown, and a glob still names no one file.
    @Test func bareMarkdownNamesAreFiles() {
        for name in ["README.md", "notes.markdown", "CHANGELOG.MD", "Plan.Markdown"] {
            #expect(TerminalLinkTarget(name) == .file(TerminalFileReference(path: name)), "\(name)")
        }
        #expect(TerminalLinkTarget("`README.md`.") == .file(TerminalFileReference(path: "README.md")))
        #expect(TerminalLinkTarget("README.md:12") == .file(TerminalFileReference(path: "README.md", line: 12)))
        for text in ["page.mdx", "README.MDX", ".md", "*.md", "a README.md"] {
            #expect(TerminalLinkTarget(text) == nil, "\(text)")
        }
    }

    @Test func pathsResolveAgainstThePaneAndHome() {
        let cwd = "/home/me/project"
        let home = "/home/me"
        func resolve(_ path: String, cwd: String? = cwd, home: String? = home) -> String? {
            TerminalPathResolver.resolve(path, workingDirectory: cwd, homeDirectory: home)
        }
        #expect(resolve("src/a.swift") == "/home/me/project/src/a.swift")
        #expect(resolve("./out/../img.png") == "/home/me/project/img.png")
        #expect(resolve("../other/x") == "/home/me/other/x")
        #expect(resolve("/etc//hosts/.") == "/etc/hosts")
        #expect(resolve("~/pic.png") == "/home/me/pic.png")
        #expect(resolve("~") == "/home/me")
        #expect(resolve("$HOME/a/b") == "/home/me/a/b")
        // `..` cannot climb above the root.
        #expect(resolve("../../../../../etc/passwd") == "/etc/passwd")
    }

    @Test func pathsWithoutAKnownBaseDoNotResolve() {
        #expect(
            TerminalPathResolver.resolve("src/a", workingDirectory: nil, homeDirectory: "/h") == nil)
        #expect(
            TerminalPathResolver.resolve("src/a", workingDirectory: "rel", homeDirectory: "/h") == nil)
        #expect(
            TerminalPathResolver.resolve("~/a", workingDirectory: "/w", homeDirectory: nil) == nil)
        // Another user's home and other variables need a shell to expand.
        #expect(
            TerminalPathResolver.resolve("~root/a", workingDirectory: "/w", homeDirectory: "/h") == nil)
        #expect(
            TerminalPathResolver.resolve("$TMPDIR/a", workingDirectory: "/w", homeDirectory: "/h") == nil)
        #expect(TerminalPathResolver.needsHomeDirectory("~/a"))
        #expect(!TerminalPathResolver.needsHomeDirectory("~root/a"))
        #expect(!TerminalPathResolver.needsHomeDirectory("./~/a"))
    }
}
