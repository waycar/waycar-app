import Foundation

/// One rate-limit window of one AI provider account, as CodexBar reports it:
/// a session, weekly, or provider-specific allowance and how much of it is
/// left. Percentages are already clamped to 0...100 for display.
struct AIUsageWindow: Sendable, Equatable, Identifiable {
    /// `primary`, `secondary`, `tertiary`, or `extra:<id>`; unique within
    /// its provider.
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    /// CodexBar's pace model: how much of the window should be used by now
    /// for usage to last exactly until the reset.
    let expectedUsedPercent: Double?
    /// CodexBar's pace estimate: stage, delta and outlook for this window.
    var pace: AIUsagePace? = nil
    /// The window's length as CodexBar reports it; nil when unknown.
    var windowMinutes: Int? = nil

    var remainingPercent: Double { 100 - usedPercent }

    var level: AIUsageLevel { AIUsageLevel(remainingPercent: remainingPercent) }
}

/// One provider row: its windows, or the error CodexBar reported for it.
struct AIUsageProvider: Sendable, Equatable, Identifiable {
    /// Provider id plus CodexBar's opaque account identity when available;
    /// legacy payloads fall back to the display label and occurrence.
    let id: String
    let providerID: String
    let displayName: String
    let account: String?
    let windows: [AIUsageWindow]
    let errorMessage: String?

    /// The window closest to running out, which decides the provider's
    /// urgency; nil for an error-only row.
    var mostUrgentWindow: AIUsageWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// The session window the compact pill reports: the one labelled
    /// Session or lasting 5 hours, else the shortest window, else the first.
    var sessionWindow: AIUsageWindow? {
        if let session = windows.first(where: {
            $0.label.caseInsensitiveCompare("Session") == .orderedSame || $0.windowMinutes == 300
        }) {
            return session
        }
        return windows.filter { $0.windowMinutes != nil }
            .min { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) } ?? windows.first
    }

    /// CodexBar failed because, over SSH, it cannot read the Host's login
    /// keychain (browser cookies, cookie cache, CLI credentials) — the case
    /// a `codexbar serve` in the GUI session fixes. `onMacOS`: the Host is a
    /// Mac, where CodexBar 0.84's "No available fetch strategy for claude."
    /// is that case too; elsewhere it only says Claude is not set up.
    func isHostKeychainBlocked(onMacOS: Bool) -> Bool {
        guard let message = errorMessage?.lowercased() else { return false }
        if Self.keychainBlockedMarkers.contains(where: message.contains) { return true }
        return onMacOS && message.contains("no available fetch strategy for claude")
    }

    private static let keychainBlockedMarkers = [
        "no claude session key found in browser cookies",
        "user interaction is not allowed",
        "keychain is unavailable",
        "keychain unavailable",
        "keychain not available",
        "keychain is not available",
    ]

    /// A `codexbar serve` gave up on this provider: CodexBar 0.84 answers
    /// "<provider> usage timed out" once a provider outlasts 0.8 of the
    /// server's request timeout (`serveProviderTimeout`), 24 seconds with
    /// CodexBar's default, too little for a slow Claude.
    var isServerProviderTimeout: Bool {
        errorMessage?.lowercased() == "\(providerID.lowercased()) usage timed out"
    }
}

/// Fuel-gauge severity of a remaining percentage.
enum AIUsageLevel: Sendable, Equatable {
    case normal
    /// Under 25 % remaining.
    case low
    /// Under 10 % remaining.
    case critical

    init(remainingPercent: Double) {
        if remainingPercent < 10 {
            self = .critical
        } else if remainingPercent < 25 {
            self = .low
        } else {
            self = .normal
        }
    }
}

/// What one CodexBar run reported: provider rows sorted least-remaining
/// first, plus a command-level failure (the CLI's `provider: "cli"` entry)
/// when the command itself failed.
struct AIUsageReport: Sendable, Equatable {
    /// Who answered: the CLI over SSH, or a `codexbar serve` in the Host's
    /// GUI session (``CodexBarServe``).
    enum Source: Sendable, Equatable {
        case cli, server
    }

    let providers: [AIUsageProvider]
    let commandError: String?
    var source: Source = .cli
    /// The CLI ran on a Mac (``CodexBarCommand/macOSHostMarker``).
    var isMacOSHost = false
    /// The oldest provider `usage.updatedAt` in the payload. A server
    /// answers with its last report while it rebuilds, so its data can be
    /// older than the fetch.
    var oldestUpdatedAt: Date?

    init(providers: [AIUsageProvider], commandError: String?) {
        self.providers = Self.sortedByUrgency(providers)
        self.commandError = commandError
    }

    /// What the Keychain Fix would fix in this report's `provider` row, nil
    /// when it cannot help. A CLI row can be out of the keychain's reach over
    /// SSH; a server, in the GUI session, reaches the keychain, so its rows
    /// can only have run out of the time the server gave them.
    func fixableProblem(_ provider: AIUsageProvider) -> CodexBarKeychainFix.Problem? {
        switch source {
        case .cli: provider.isHostKeychainBlocked(onMacOS: isMacOSHost) ? .keychainBlocked : nil
        case .server: provider.isServerProviderTimeout ? .serverTimedOut : nil
        }
    }

    /// The rows ``fixableProblem(_:)`` flags.
    var fixableProviders: [AIUsageProvider] {
        providers.filter { fixableProblem($0) != nil }
    }

    /// When the report's data was current: for a server answer the oldest
    /// provider `updatedAt`, never later than `finishedAt`; otherwise (or
    /// with no date) `finishedAt`.
    func dataDate(finishedAt: Date) -> Date {
        guard source == .server, let oldestUpdatedAt else { return finishedAt }
        return min(oldestUpdatedAt, finishedAt)
    }

    /// Least remaining first; ties by name. Providers without windows (error
    /// rows) follow every provider that has data.
    static func sortedByUrgency(_ providers: [AIUsageProvider]) -> [AIUsageProvider] {
        providers.enumerated().sorted { lhs, rhs in
            let left = lhs.element.mostUrgentWindow?.remainingPercent
            let right = rhs.element.mostUrgentWindow?.remainingPercent
            switch (left, right) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                let order = lhs.element.displayName.localizedStandardCompare(
                    rhs.element.displayName)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    static func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}

// MARK: - Decoding

extension AIUsageReport {
    /// The provider id CodexBar uses for a command-level error entry.
    static let commandErrorProviderID = "cli"

    /// Decodes CodexBar's JSON array. Leniency is deliberate: unknown fields
    /// are ignored, a malformed provider entry is dropped rather than failing
    /// the whole report, and a login shell's noise before the JSON is skipped
    /// (the CLI prints one compact line without `--pretty`). A
    /// ``CodexBarCommand/serverSourceMarker`` line marks a server answer;
    /// framed CLI reports may carry a separate Codex all-accounts supplement.
    /// Throws only when the base report contains no JSON array.
    static func decode(_ data: Data) throws -> AIUsageReport {
        let (body, source) = splitSourceMarker(data)
        let payloads = try (source == .cli ? decodeCLIReports(body) : decodePayloads(body))
        var providers: [AIUsageProvider] = []
        var commandErrors: [String] = []
        var seenIDs: [String: Int] = [:]
        var oldestUpdatedAt: Date?
        for payload in payloads {
            guard let providerID = payload.provider?.trimmingCharacters(in: .whitespaces),
                !providerID.isEmpty
            else { continue }
            if let updatedAt = payload.usage?.updatedAt.flatMap(parseDate) {
                oldestUpdatedAt = min(oldestUpdatedAt ?? updatedAt, updatedAt)
            }
            let message = payload.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorMessage = message?.isEmpty == false ? message : nil
            if providerID == commandErrorProviderID {
                commandErrors.append(errorMessage ?? "CodexBar could not run.")
                continue
            }
            let windows = Self.windows(of: payload)
            guard !windows.isEmpty || errorMessage != nil else { continue }
            let account = nonempty(payload.account)
            var id = nonempty(payload.cacheAccountKey).map { "\(providerID):\($0)" }
                ?? account.map { "\(providerID):\($0)" } ?? providerID
            if let count = seenIDs[id] {
                seenIDs[id] = count + 1
                id += "#\(count + 1)"
            } else {
                seenIDs[id] = 1
            }
            providers.append(AIUsageProvider(
                id: id,
                providerID: providerID,
                displayName: displayName(forProviderID: providerID),
                account: account,
                windows: windows,
                errorMessage: errorMessage))
        }
        // Older CodexBar versions can omit labels. Neutral labels still let
        // people distinguish multiple accounts without exposing opaque keys.
        let codexIDs = providers.filter { $0.providerID == "codex" }.map(\.id).sorted()
        if codexIDs.count > 1 {
            providers = providers.map { provider in
                guard provider.providerID == "codex", provider.account == nil,
                    let index = codexIDs.firstIndex(of: provider.id)
                else { return provider }
                return AIUsageProvider(
                    id: provider.id, providerID: provider.providerID,
                    displayName: provider.displayName, account: "Account \(index + 1)",
                    windows: provider.windows, errorMessage: provider.errorMessage)
            }
        }
        var report = AIUsageReport(
            providers: providers,
            commandError: commandErrors.isEmpty ? nil : commandErrors.joined(separator: "\n"))
        report.source = source
        report.isMacOSHost = source == .cli
            && outputLines(body).contains(CodexBarCommand.macOSHostMarker)
        report.oldestUpdatedAt = oldestUpdatedAt
        return report
    }

    /// Only an entire marker line changes the source; incidental marker text
    /// in login-shell noise or a JSON string is not framing.
    private static func splitSourceMarker(_ data: Data) -> (Data, Source) {
        let lines = outputLines(data)
        guard let index = lines.lastIndex(of: CodexBarCommand.serverSourceMarker) else {
            return (data, .cli)
        }
        return (Data(lines.dropFirst(index + 1).joined(separator: "\n").utf8), .server)
    }

    private static func outputLines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
    }

    private static func decodeCLIReports(_ data: Data) throws -> [Payload] {
        let lines = outputLines(data)
        guard let start = lines.lastIndex(of: CodexBarCommand.cliBaseStartMarker) else {
            return try decodePayloads(data)
        }
        guard let end = lines.indices.first(where: {
            $0 > start && lines[$0] == CodexBarCommand.cliBaseEndMarker
        }) else { throw AIUsageDecodingError.noJSONArray }
        let base = try decodePayloads(Data(lines[(start + 1)..<end].joined(separator: "\n").utf8))
        guard base.contains(where: { $0.provider == "codex" }),
            let accountStart = lines.indices.first(where: {
                $0 > end && lines[$0] == CodexBarCommand.codexAccountsStartMarker
            }),
            let accountEnd = lines.indices.first(where: {
                $0 > accountStart
                    && lines[$0].hasPrefix(CodexBarCommand.codexAccountsEndMarker + " ")
            }),
            let status = Int(lines[accountEnd].dropFirst(
                CodexBarCommand.codexAccountsEndMarker.count + 1)),
            ![126, 127, Int(HostWatchdog.stoppedStatus)].contains(status),
            let rows = try? decodePayloadArray(
                Data(lines[(accountStart + 1)..<accountEnd].joined(separator: "\n").utf8))
        else { return base }
        let accounts = rows.compactMap(\.value)
        // Only a complete account inventory can replace the ambient active
        // account. Lossy, empty, command-wide, or unusable output leaves the
        // working base untouched, even when the process returned success.
        guard !accounts.isEmpty, accounts.count == rows.count,
            accounts.allSatisfy({
                $0.provider == "codex"
                    && (hasWindows($0) || nonempty($0.error?.message) != nil)
            })
        else { return base }
        let baseAccounts = base.filter { $0.provider == "codex" }
        let inventory = accounts.map { account in
            guard !hasWindows(account) else { return account }
            let matches = baseAccounts.filter { sameAccount($0, account) }
            // An account-local error must not erase working usage when its
            // identity is unambiguous. Anonymous rows are never a match.
            guard matches.count == 1, let previous = matches.first,
                hasWindows(previous),
                accounts.filter({ sameAccount($0, previous) }).count == 1
            else { return account }
            return previous
        }
        return base.filter { $0.provider != "codex" } + inventory
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }

    private static func sameAccount(_ lhs: Payload, _ rhs: Payload) -> Bool {
        if let left = nonempty(lhs.cacheAccountKey), let right = nonempty(rhs.cacheAccountKey) {
            return left == right
        }
        guard let left = nonempty(lhs.account), let right = nonempty(rhs.account) else {
            return false
        }
        return left == right
    }

    private static func hasWindows(_ payload: Payload) -> Bool {
        let usage = payload.usage
        return isUsable(usage?.primary) || isUsable(usage?.secondary)
            || isUsable(usage?.tertiary)
            || usage?.extraRateWindows?.contains {
                $0.usageKnown != false && isUsable($0.window)
            } == true
    }

    private static func isUsable(_ window: RateWindow?) -> Bool {
        window?.usedPercent != nil && window?.isSyntheticPlaceholder != true
    }

    private static func decodePayloads(_ data: Data) throws -> [Payload] {
        try decodePayloadArray(data).compactMap(\.value)
    }

    private static func decodePayloadArray(_ data: Data) throws -> [Lossy<Payload>] {
        let decoder = JSONDecoder()
        if let whole = try? decoder.decode([Lossy<Payload>].self, from: data) {
            return whole
        }
        // Login-shell noise around the JSON: the array is the last line that
        // parses as one.
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let first = line.first(where: { !Self.isWhitespace($0) }),
                first == UInt8(ascii: "[")
            else { continue }
            if let parsed = try? decoder.decode([Lossy<Payload>].self, from: Data(line)) {
                return parsed
            }
        }
        throw AIUsageDecodingError.noJSONArray
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    private static func windows(of payload: Payload) -> [AIUsageWindow] {
        var windows: [AIUsageWindow] = []
        let slots: [(String, RateWindow?, String?, Pace?, String)] = [
            ("primary", payload.usage?.primary, payload.rateWindowLabels?.primary,
             payload.pace?.primary, "Primary"),
            ("secondary", payload.usage?.secondary, payload.rateWindowLabels?.secondary,
             payload.pace?.secondary, "Secondary"),
            ("tertiary", payload.usage?.tertiary, payload.rateWindowLabels?.tertiary,
             payload.pace?.tertiary, "Tertiary"),
        ]
        for (id, window, label, pace, fallback) in slots {
            guard let window, let used = window.usedPercent, window.isSyntheticPlaceholder != true
            else { continue }
            windows.append(AIUsageWindow(
                id: id,
                label: windowLabel(
                    explicit: label, windowMinutes: window.windowMinutes, fallback: fallback),
                usedPercent: clampedPercent(used),
                resetsAt: window.resetsAt.flatMap(parseDate),
                expectedUsedPercent: pace?.expectedUsedPercent,
                pace: pace.map(Self.makePace),
                windowMinutes: window.windowMinutes))
        }
        for extra in payload.usage?.extraRateWindows ?? [] {
            guard extra.usageKnown != false, let window = extra.window,
                let used = window.usedPercent, window.isSyntheticPlaceholder != true
            else { continue }
            let extraID = extra.id ?? extra.title ?? "\(windows.count)"
            windows.append(AIUsageWindow(
                id: "extra:\(extraID)",
                label: windowLabel(
                    explicit: extra.title, windowMinutes: window.windowMinutes,
                    fallback: extraID),
                usedPercent: clampedPercent(used),
                resetsAt: window.resetsAt.flatMap(parseDate),
                expectedUsedPercent: nil,
                windowMinutes: window.windowMinutes))
        }
        return windows
    }

    /// The decoded pace object. Unknown stage strings cost only the stage;
    /// the delta and outlook still read.
    private static func makePace(_ pace: Pace) -> AIUsagePace {
        AIUsagePace(
            stage: pace.stage.flatMap(AIUsagePace.Stage.init(rawValue:)),
            deltaPercent: pace.deltaPercent,
            etaSeconds: pace.etaSeconds,
            lastsUntilReset: pace.willLastToReset)
    }

    /// The CLI's own label when it gave one, else one derived from the
    /// window length ("5h", "30d"); 10080 minutes reads "Weekly", not "7d".
    static func windowLabel(explicit: String?, windowMinutes: Int?, fallback: String) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return explicit
        }
        guard let minutes = windowMinutes, minutes > 0 else { return fallback }
        switch minutes {
        case 10080: return "Weekly"
        case let minutes where minutes % 1440 == 0: return "\(minutes / 1440)d"
        case let minutes where minutes % 60 == 0: return "\(minutes / 60)h"
        default: return "\(minutes)m"
        }
    }

    /// Known CodexBar provider ids; anything else is shown capitalized.
    static func displayName(forProviderID id: String) -> String {
        if let known = knownProviderNames[id.lowercased()] { return known }
        return id.prefix(1).uppercased() + id.dropFirst()
    }

    private static let knownProviderNames: [String: String] = [
        "codex": "Codex",
        "claude": "Claude",
        "gemini": "Gemini",
        "openai": "OpenAI",
        "azureopenai": "Azure OpenAI",
        "cursor": "Cursor",
        "copilot": "Copilot",
        "openrouter": "OpenRouter",
        "opencode": "OpenCode",
        "factory": "Factory",
        "antigravity": "Antigravity",
        "zai": "z.ai",
        "minimax": "MiniMax",
        "kimi": "Kimi",
        "kiro": "Kiro",
        "vertexai": "Vertex AI",
        "augment": "Augment",
        "jetbrains": "JetBrains AI",
        "amp": "Amp",
        "ollama": "Ollama",
        "warp": "Warp",
        "windsurf": "Windsurf",
        "zed": "Zed",
        "perplexity": "Perplexity",
        "mistral": "Mistral",
        "deepseek": "DeepSeek",
        "bedrock": "Bedrock",
        "grok": "Grok",
        "groq": "Groq",
        "xai": "xAI",
        "devin": "Devin",
    ]

    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }

    // Wire shapes: every field optional, so a renamed or retyped field
    // costs that field rather than the provider.

    private struct Payload: Decodable {
        let provider: String?
        let account: String?
        let cacheAccountKey: String?
        let usage: Usage?
        let rateWindowLabels: Labels?
        let pace: Paces?
        let error: ErrorBody?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try? container.decodeIfPresent(String.self, forKey: .provider)
            account = try? container.decodeIfPresent(String.self, forKey: .account)
            cacheAccountKey = try? container.decodeIfPresent(String.self, forKey: .cacheAccountKey)
            usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
            rateWindowLabels = try? container.decodeIfPresent(Labels.self, forKey: .rateWindowLabels)
            pace = try? container.decodeIfPresent(Paces.self, forKey: .pace)
            error = try? container.decodeIfPresent(ErrorBody.self, forKey: .error)
        }

        private enum CodingKeys: String, CodingKey {
            case provider, account, cacheAccountKey, usage, rateWindowLabels, pace, error
        }
    }

    private struct Usage: Decodable {
        let primary: RateWindow?
        let secondary: RateWindow?
        let tertiary: RateWindow?
        let extraRateWindows: [ExtraWindow]?
        let updatedAt: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? container.decodeIfPresent(RateWindow.self, forKey: .primary)
            secondary = try? container.decodeIfPresent(RateWindow.self, forKey: .secondary)
            tertiary = try? container.decodeIfPresent(RateWindow.self, forKey: .tertiary)
            extraRateWindows = (try? container.decodeIfPresent(
                [Lossy<ExtraWindow>].self, forKey: .extraRateWindows))?
                .compactMap(\.value)
            updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
        }

        private enum CodingKeys: String, CodingKey {
            case primary, secondary, tertiary, extraRateWindows, updatedAt
        }
    }

    private struct RateWindow: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: String?
        let isSyntheticPlaceholder: Bool?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try? container.decodeIfPresent(Double.self, forKey: .usedPercent)
            windowMinutes = try? container.decodeIfPresent(Int.self, forKey: .windowMinutes)
            resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
            isSyntheticPlaceholder = try? container.decodeIfPresent(
                Bool.self, forKey: .isSyntheticPlaceholder)
        }

        private enum CodingKeys: String, CodingKey {
            case usedPercent, windowMinutes, resetsAt, isSyntheticPlaceholder
        }
    }

    private struct ExtraWindow: Decodable {
        let id: String?
        let title: String?
        let window: RateWindow?
        let usageKnown: Bool?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            window = try? container.decodeIfPresent(RateWindow.self, forKey: .window)
            usageKnown = try? container.decodeIfPresent(Bool.self, forKey: .usageKnown)
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, window, usageKnown
        }
    }

    private struct Labels: Decodable {
        let primary: String?
        let secondary: String?
        let tertiary: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? container.decodeIfPresent(String.self, forKey: .primary)
            secondary = try? container.decodeIfPresent(String.self, forKey: .secondary)
            tertiary = try? container.decodeIfPresent(String.self, forKey: .tertiary)
        }

        private enum CodingKeys: String, CodingKey {
            case primary, secondary, tertiary
        }
    }

    private struct Paces: Decodable {
        let primary: Pace?
        let secondary: Pace?
        let tertiary: Pace?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? container.decodeIfPresent(Pace.self, forKey: .primary)
            secondary = try? container.decodeIfPresent(Pace.self, forKey: .secondary)
            tertiary = try? container.decodeIfPresent(Pace.self, forKey: .tertiary)
        }

        private enum CodingKeys: String, CodingKey {
            case primary, secondary, tertiary
        }
    }

    private struct Pace: Decodable {
        let stage: String?
        let deltaPercent: Double?
        let expectedUsedPercent: Double?
        let etaSeconds: Int?
        let willLastToReset: Bool?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            stage = try? container.decodeIfPresent(String.self, forKey: .stage)
            deltaPercent = try? container.decodeIfPresent(Double.self, forKey: .deltaPercent)
            expectedUsedPercent = try? container.decodeIfPresent(
                Double.self, forKey: .expectedUsedPercent)
            etaSeconds = try? container.decodeIfPresent(Int.self, forKey: .etaSeconds)
            willLastToReset = try? container.decodeIfPresent(
                Bool.self, forKey: .willLastToReset)
        }

        private enum CodingKeys: String, CodingKey {
            case stage, deltaPercent, expectedUsedPercent, etaSeconds, willLastToReset
        }
    }

    private struct ErrorBody: Decodable {
        let message: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
        }

        private enum CodingKeys: String, CodingKey {
            case message
        }
    }

    /// One array element that fails to decode becomes nil instead of failing
    /// the array.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

enum AIUsageDecodingError: Error, Equatable {
    case noJSONArray
}
