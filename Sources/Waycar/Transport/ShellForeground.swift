import Foundation

/// Pure: a Shell pane's Shell Activity from herdr's `pane.process_info`.
enum ShellForeground {
    /// Nil when herdr cannot tell (no shell pid or foreground group).
    static func activity(_ info: PaneProcessInfo) -> ShellActivity? {
        guard let shellPid = info.shellPid,
            let group = info.foregroundProcessGroupID
        else { return nil }
        let processes = info.foregroundProcesses ?? []
        // Linux lists by pid, not leader first.
        guard let leader = processes.first(where: { $0.pid == group }) ?? processes.first
        else { return group == shellPid ? .idle : nil }

        if isInteractiveShell(leader) {
            // A subshell leading the group: a non-shell member is the command.
            guard group != shellPid,
                let member = processes
                    .filter({ !ShellCommand.isShell($0.name) })
                    .min(by: { $0.pid < $1.pid })
            else { return .idle }
            return running(member)
        }
        return running(leader)
    }

    private static func running(_ process: PaneProcessInfoProcess) -> ShellActivity? {
        let line = process.argv.flatMap { $0.isEmpty ? nil : $0.joined(separator: " ") }
            ?? process.cmdline ?? process.name
        return ShellActivity.runningCommand(line)
            ?? ShellActivity.runningCommand(ShellCommand.normalized(process.name))
    }

    /// A shell sitting at its prompt: named a shell (Linux `name` is the
    /// 15-char comm, so argv[0] counts too) and running no `-c` command or
    /// script operand.
    private static func isInteractiveShell(_ process: PaneProcessInfoProcess) -> Bool {
        let candidates = [process.name, process.argv0, process.argv?.first].compactMap { $0 }
        guard candidates.contains(where: ShellCommand.isShell) else { return false }
        guard let argv = process.argv else { return true }
        let isFish = candidates.contains { ShellCommand.normalized($0) == "fish" }
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" { return index + 1 >= argv.count }
            if ["-o", "+o", "-O", "+O", "--rcfile", "--init-file", "--init-command"]
                .contains(arg) || (arg == "-C" && isFish)
            {
                index += 2
                continue
            }
            if arg.hasPrefix("--") {
                if arg == "--command" || arg.hasPrefix("--command=") { return false }
            } else if arg.hasPrefix("-") || arg.hasPrefix("+") {
                if arg.count > 1, !arg.hasPrefix("+"), arg.dropFirst().contains("c") {
                    return false
                }
            } else {
                return false
            }
            index += 1
        }
        return true
    }
}
