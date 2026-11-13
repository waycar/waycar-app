import Foundation
import Testing

@testable import Waycar

/// The probe that serves both Host Tools eras (`HostToolProbe`): each
/// generated command is run under the real `/bin/sh` against a throwaway
/// plugin root, with stand-ins for `bin/node.sh` and `bin/waycar` that print
/// which one ran and with what arguments.
@Suite("Host Tools era probe", .timeLimit(.minutes(1)))
struct HostToolProbeTests {
    enum Tree: String, CaseIterable {
        case nodeEra, native, both, neither, nodeLauncherOnly
    }

    struct Run: Equatable {
        let status: Int32
        let output: String
    }

    private static func makeRoot(_ tree: Tree, script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waycar-probe-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if tree == .nodeEra || tree == .both {
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("src/\(script).js"))
            try executable("#!/bin/sh\nprintf 'node:%s\\n' \"$*\"; cat\n", at: root.appendingPathComponent("bin/node.sh"))
        }
        if tree == .native || tree == .both {
            try executable("#!/bin/sh\nprintf 'native:%s\\n' \"$*\"; cat\n", at: root.appendingPathComponent("bin/waycar"))
        }
        if tree == .nodeLauncherOnly {
            // A 1.2 to 1.5 plugin without this feature's script: `bin/waycar` is
            // the Node launcher, so it must not be run as a native binary.
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("src/waycar-cli.js"))
            try executable("#!/bin/sh\nexit 2\n", at: root.appendingPathComponent("bin/waycar"))
        }
        return root
    }

    private static func executable(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `/bin/sh -c command` with `stdin` as its standard input, through
    /// `posix_spawn` (`Process` does not exist in the iOS SDK these tests build
    /// against). Standard error is discarded.
    private static func run(_ command: String, stdin: String) throws -> Run {
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else { throw POSIXError(.EMFILE) }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        for fd in inPipe + outPipe { posix_spawn_file_actions_addclose(&actions, fd) }

        let arguments = ["sh", "-c", command]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // A Host's non-interactive PATH, set explicitly: the test process's own
        // may be empty under the simulator.
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/nonexistent"]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, nil, argv, envp)
        close(inPipe[0])
        close(outPipe[1])
        guard spawned == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }
        let bytes = Array(stdin.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(inPipe[1], buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        close(inPipe[1])
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(outPipe[0], &chunk, chunk.count)
            if n <= 0 { break }
            output.append(contentsOf: chunk[0..<n])
        }
        close(outPipe[0])
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Run(status: code, output: String(decoding: output, as: UTF8.self))
    }

    private func outcomes(
        script: String, command: (String) -> String
    ) throws -> [Tree: Run] {
        var result: [Tree: Run] = [:]
        for tree in Tree.allCases {
            let root = try Self.makeRoot(tree, script: script)
            defer { try? FileManager.default.removeItem(at: root) }
            result[tree] = try Self.run(command("'\(root.path)'"), stdin: "REQUEST\n")
        }
        return result
    }

    @Test func theChatReaderRunsTheScriptOrTheNativeSubcommand() throws {
        let runs = try outcomes(script: "chat-read") {
            WaycarSSHTransport.chatTranscriptReadCommand(quotedPluginRoot: $0)
        }
        #expect(runs[.nodeEra] == Run(status: 0, output: "node:src/chat-read.js --request -\nREQUEST\n"))
        #expect(runs[.native] == Run(status: 0, output: "native:chat-read --request -\nREQUEST\n"))
        #expect(runs[.both] == runs[.nodeEra])
        #expect(runs[.neither] == Run(status: WaycarSSHTransport.chatReaderMissingStatus, output: ""))
        #expect(runs[.nodeLauncherOnly] == runs[.neither])
    }

    @Test func theMediaReaderRunsTheScriptOrTheNativeSubcommand() throws {
        let runs = try outcomes(script: "chat-media") {
            WaycarSSHTransport.chatMediaReadCommand(quotedPluginRoot: $0)
        }
        #expect(runs[.nodeEra] == Run(status: 0, output: "node:src/chat-media.js --request -\nREQUEST\n"))
        #expect(runs[.native] == Run(status: 0, output: "native:chat-media --request -\nREQUEST\n"))
        #expect(runs[.both] == runs[.nodeEra])
        #expect(runs[.neither] == Run(status: WaycarSSHTransport.chatReaderMissingStatus, output: ""))
        #expect(runs[.nodeLauncherOnly] == runs[.neither])
    }

    @Test func aMissingPluginRootIsTooOldNotAnError() throws {
        let run = try Self.run(
            WaycarSSHTransport.chatTranscriptReadCommand(quotedPluginRoot: "'/nonexistent/waycar'"),
            stdin: "")
        #expect(run == Run(status: 64, output: ""))
    }

    /// The root is data: a quote or `$(…)` in it reaches `cd` as one word.
    @Test func aHostilePluginRootStaysOneWord() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("waycar-probe-pwn-\(UUID().uuidString)").path
        let hostile = ShellWord.quoted("/tmp/x'; touch \(marker); '")
        let run = try Self.run(
            WaycarSSHTransport.chatTranscriptReadCommand(quotedPluginRoot: hostile), stdin: "")
        #expect(run.status == 64)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}
