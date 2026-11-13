import Foundation

/// The Keychain Fix (`CONTEXT.md`): over SSH CodexBar cannot open the Host's
/// login keychain, so a provider whose usage lives behind browser cookies or
/// CLI credentials (`AIUsageReport.fixableProblem`) reads as an error. A `codexbar serve` LaunchAgent in the Host's GUI session can read
/// it, and `CodexBarCommand.usageCommand` asks that server first. A server
/// started with CodexBar's default request timeout gives up on a slow
/// provider, so the same fix also rewrites an existing one with
/// `CodexBarServe.requestTimeoutSeconds`. Waycar never installs it itself:
/// after the user confirms, it opens the New Agent sheet prefilled for the
/// Host, handing over `agentPrompt`; once the user taps Start, that Agent
/// explains the change and asks again before touching the Mac.
enum CodexBarKeychainFix {
    /// What the fix fixes for a provider row (`AIUsageReport.fixableProblem`).
    enum Problem: Sendable, Equatable {
        /// Over SSH CodexBar cannot open the login keychain: the fix sets up
        /// the server.
        case keychainBlocked
        /// The server answered "<provider> usage timed out": the fix gives
        /// it a longer request timeout.
        case serverTimedOut

        /// The provider row's title in place of CodexBar's raw error.
        func title(providerName: String) -> String {
            switch self {
            case .keychainBlocked: "\(providerName) can't be read over SSH"
            case .serverTimedOut: "\(providerName) timed out"
            }
        }

        /// The provider row's explanation beneath the title.
        func explanation(hostName: String?) -> String {
            let host = hostName ?? "your Mac"
            return switch self {
            case .keychainBlocked:
                "CodexBar on \(host) can't open your Mac's keychain from a remote "
                    + "session. A small background helper fixes it."
            case .serverTimedOut:
                "The AI Usage helper on \(host) stops waiting too soon. "
                    + "Updating it gives slow providers more time."
            }
        }

        /// The Console card's line for the provider; tapping it opens the
        /// AI Usage sheet, where the fix is offered.
        var cardLabel: String {
            switch self {
            case .keychainBlocked: "Can't be read over SSH · Fix…"
            case .serverTimedOut: "Timed out · Fix…"
            }
        }

        var systemImage: String {
            switch self {
            case .keychainBlocked: "lock.trianglebadge.exclamationmark"
            case .serverTimedOut: "clock.badge.exclamationmark"
            }
        }
    }

    /// A fix awaiting confirmation or launch: the Host, the problem, and the
    /// providers its report flags (`AIUsageReport.fixableProviders`).
    struct Request {
        let hostID: Host.ID
        let problem: Problem
        let providers: [AIUsageProvider]
    }

    // MARK: User-facing copy

    static let fixButtonTitle = "Fix it for me…"

    static func confirmationTitle(hostName: String?) -> String {
        "Fix AI Usage on \(hostName ?? "this Host")?"
    }

    static func confirmationMessage(hostName: String?) -> String {
        let host = hostName ?? "this Host"
        return "Waycar will open New Agent for \(host), ready for you to review and start. "
            + "The agent explains the change and asks before touching your Mac. "
            + "A Terminal window will open on the Mac; you can close it afterwards."
    }

    static let confirmButtonTitle = "Open Agent"

    // MARK: New Agent preset

    /// The New Agent sheet the confirmed fix opens: locked to the blocked
    /// Host, with `agentPrompt` attached as its first message. A preset,
    /// never quick chat, so nothing starts until the user taps Start.
    static func preset(
        hostID: Host.ID, hostName: String, problem: Problem, providers: [AIUsageProvider],
        codexBarPath: String?
    ) -> AgentLaunchPreset {
        AgentLaunchPreset(
            title: "Fix AI Usage",
            hostID: hostID,
            locksHost: true,
            suggestedName: "fix-ai-usage",
            attachmentTitle: "Fix instructions",
            firstMessage: agentPrompt(
                hostName: hostName, problem: problem, providers: providers,
                codexBarPath: codexBarPath))
    }

    // MARK: Agent prompt

    /// The first user message of the Agent that sets up the CodexBar serve
    /// LaunchAgent on `hostName`, handed over as a Launch Prompt File
    /// (`LaunchPromptStager`). One line with no tab, quote, `!`, `$` or
    /// backtick, like `ChatModePrompt.defaultText`, so Host and provider
    /// names can't change what it says. `codexBarPath` is CodexBar's detected
    /// path on the Host; nil (or one that would not survive as plain text)
    /// has the Agent look it up.
    /// `providers` are the report's rows with `problem`, named in the
    /// prompt and checked by its verification step. For
    /// ``Problem/serverTimedOut`` it rewrites Waycar's existing LaunchAgent,
    /// and changes nothing when that already has the timeout or is not there.
    static func agentPrompt(
        hostName: String, problem: Problem, providers: [AIUsageProvider], codexBarPath: String?
    ) -> String {
        let port = CodexBarServe.port
        let requestTimeout = CodexBarServe.requestTimeoutSeconds
        let label = CodexBarServe.launchAgentLabel
        let endpoint = "http://127.0.0.1:\(port)/usage"
        let log = "~/Library/Logs/codexbar-serve.log"
        let plist = "~/Library/LaunchAgents/\(label).plist"
        let codexbar: String
        if let codexBarPath, isPlainAbsolutePath(codexBarPath) {
            codexbar = "Use the CodexBar CLI at \(codexBarPath) (if it is gone, find it with command -v codexbar)."
        } else {
            codexbar = "Find the CodexBar CLI with command -v codexbar."
        }
        let names = providers.map { plainText($0.displayName) }.filter { !$0.isEmpty }
        let shownNames = names.isEmpty ? "some providers" : names.joined(separator: ", ")
        let entries = providers.map { plainText($0.providerID) }.filter { !$0.isEmpty }
        let entryList = entries.isEmpty
            ? "every entry" : "each of the entries " + entries.joined(separator: ", ")
        let undo = "To undo it later: launchctl bootout gui/UID/\(label), then delete \(plist) and \(log)."
        let why: [String]
        let endpointNote: String
        let step2: [String]
        switch problem {
        case .keychainBlocked:
            why = [
                "it runs codexbar usage over SSH, and an SSH session cannot open the login keychain,",
                "which stays locked to the GUI session, so CodexBar finds no browser cookies or credentials.",
                "The fix is to run codexbar serve inside the GUI session as a user LaunchAgent;",
                "Waycar already reads \(endpoint) first whenever it answers.",
            ]
            endpointNote = "this adds an always-on usage endpoint that listens only on this Mac (127.0.0.1),"
            step2 = [
                "Step 2, check the port: run lsof -nP -iTCP:\(port) -sTCP:LISTEN.",
                "If something other than codexbar serve is listening there, stop and tell me what it is.",
            ]
        case .serverTimedOut:
            why = [
                "Waycar reads \(endpoint), a codexbar serve helper in the GUI session, and for \(shownNames) that helper answers usage timed out.",
                "codexbar serve gives each provider 0.8 of its request timeout (24 seconds with the default of 30),",
                "and a slow provider such as Claude can take longer.",
                "The fix is to run the helper with --request-timeout \(requestTimeout) by rewriting its user LaunchAgent and loading it again.",
            ]
            endpointNote = "this only gives the existing usage endpoint, which listens only on this Mac (127.0.0.1), more time,"
            step2 = [
                "Step 2, check the helper: run lsof -nP -iTCP:\(port) -sTCP:LISTEN and launchctl print gui/UID/\(label)",
                "(UID being the output of id -u), and read \(plist).",
                "If that plist does not exist, or the process listening on the port is not the pid launchctl print reports,",
                "the helper was not set up by Waycar: change nothing,",
                "tell me what is listening on the port and that it needs --request-timeout \(requestTimeout), and stop.",
                "If its ProgramArguments already pass --request-timeout \(requestTimeout) or more, change nothing,",
                "tell me the helper already allows that much, so the provider itself is too slow, and stop.",
            ]
        }
        let opening = "The AI Usage screen in Waycar cannot read \(shownNames) usage on this Mac (\(plainText(hostName))):"
        let rules = [
            "Rules: before changing anything, explain the plan below to me in 3 to 6 short bullets and wait for my OK.",
            "The bullets must say that \(endpointNote)",
            "and how to undo it. \(undo)",
            "Never print, log or copy cookies, tokens or keychain contents.",
            "Step 1, check CodexBar: \(codexbar)",
            "If it is missing, or running it with serve --help fails (CodexBar too old to have codexbar serve, added in 0.26.1),",
            "stop and tell me to install or update CodexBar instead.",
        ]
        let sentences = [opening] + why + rules + step2 + [
            "Step 3, write \(plist) with Label \(label);",
            "ProgramArguments the absolute codexbar path, serve, --port, \(port), --request-timeout, \(requestTimeout)",
            "(it binds 127.0.0.1 by default; the longer timeout leaves slow providers such as Claude time to answer);",
            "RunAtLoad true; KeepAlive true;",
            "EnvironmentVariables with PATH set to /opt/homebrew/bin, /usr/local/bin, the .local/bin in your home directory,",
            "/usr/bin, /bin, /usr/sbin and /sbin, joined with colons;",
            "StandardOutPath and StandardErrorPath both \(log).",
            "Write every path in the plist as an absolute path, then check it with plutil -lint.",
            "Step 4, load it in the GUI session: launchctl bootstrap gui/UID (UID being the output of id -u)",
            "fails from SSH with error 5, so write a one-shot script ending in .command in a fresh temp directory from mktemp -d,",
            "make it executable, and have it run launchctl bootout gui/UID/\(label) (ignoring the error when nothing was loaded),",
            "then launchctl bootstrap gui/UID with the plist path, and as its very last line remove its own temp directory",
            "recursively (the directory containing the script, taken from the script path it was started with).",
            "Run it with open on the .command file: Terminal opens on the Mac and runs it in the GUI session.",
            "Instead of a fixed wait, poll every second or two for up to about 30 seconds",
            "until launchctl print gui/UID/\(label) succeeds or curl -fsS http://127.0.0.1:\(port)/health answers.",
            "Step 5, verify: curl -fsS --max-time \(requestTimeout + 5) \(endpoint) must return a JSON array in which \(entryList) has no error.",
            "If one of those providers is missing from the output entirely, tell me so rather than treating it as a failure.",
            "If an entry still has an error, read the end of the log and launchctl print gui/UID/\(label), and tell me what went wrong.",
            "When it works, tell me to pull to refresh AI Usage in Waycar, that the Terminal window can be closed, and repeat: \(undo)",
        ]
        return sentences.joined(separator: " ")
    }

    /// An absolute path of only letters, digits and `/._-+`, so it reads
    /// the same inside the prompt as on the Host.
    private static func isPlainAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || "/._-+".unicodeScalars.contains(scalar))
            }
    }

    /// `text` without the characters the prompt keeps out (see
    /// `agentPrompt`), whitespace runs collapsed to one space.
    private static func plainText(_ text: String) -> String {
        let kept = text.filter { character in
            !"\"'`$!".contains(character)
                && !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        return kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
