import SwiftUI

// MARK: - W2 Agent detail

/// W2 (Done, Working, Idle): status line, title, the Latest text, and the
/// outgoing message (W5a, W5), with the mic floating in the bottom bar. No
/// navigation title. If the Agent turns Blocked while W2 is open (or a link
/// opened W2 for a Blocked Agent), the mic hides and "Review prompt" opens
/// W3: Waycar never types into a Blocked prompt.
struct AgentDetailView: View {
    /// The Agent shown.
    let agentID: WatchAgentID
    /// The watch's model.
    let store: WatchStore

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// The scroll anchor below the last line.
    private static let bottomID = "bottom"

    /// The detail, re-rendered every minute so the age moves.
    var body: some View {
        let row = store.row(agentID)
        let outgoing = Self.visibleOutgoing(store.outgoing(for: agentID), row: row)
        TimelineView(.everyMinute) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy, so a long reply lays out only the paragraphs in view.
                    LazyVStack(alignment: .leading, spacing: WatchLayout.blockSpacing) {
                        if let row {
                            header(row, now: context.date)
                        }
                        latest(dimmed: outgoing != nil)
                        if isBlocked {
                            reviewPromptLink
                        }
                        if let outgoing {
                            OutgoingBubbleView(outgoing: outgoing)
                            OutgoingStatusView(
                                outgoing: outgoing,
                                canAct: WatchAvailability.canAct(on: agentID, in: store),
                                onRetry: { store.retry(outgoing.id) })
                        }
                        // The bottom inset doubles as the scroll anchor, so
                        // scrolling to the end leaves the last line above the mic.
                        Color.clear
                            .frame(height: WatchLayout.micClearance)
                            .id(Self.bottomID)
                    }
                }
                .onAppear {
                    if outgoing != nil {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: outgoing?.phase) { _, phase in
                    guard phase != nil else { return }
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                // No mic for an Agent gone from the Watch State; an iPhone
                // that doesn't answer or an unconfirmed Host keeps it
                // visible but disabled.
                if row != nil, !isBlocked, outgoing?.isInFlight != true {
                    Spacer()
                    micControl(title: row?.title ?? "")
                    Spacer()
                }
            }
        }
        .task(id: WatchLoadKey(status: row?.status, isReachable: store.isReachable)) {
            await store.loadLatest(agentID)
        }
        .userActivity(WatchHandoff.activityType) { activity in
            WatchHandoff.configure(activity, for: agentID, title: row?.title)
        }
    }

    /// Whether the Agent waits on a Blocked prompt.
    private var isBlocked: Bool {
        store.row(agentID)?.status == "blocked"
    }

    /// The small "Review prompt" link that opens W3 for a Blocked Agent.
    private var reviewPromptLink: some View {
        Button("Review prompt") {
            store.route.append(.blocked(agentID))
        }
        .buttonStyle(.plain)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(WatchBrand.Colors.accent)
    }

    // MARK: Header

    /// Status line over the title (Headline, wrapped in full), then the
    /// Agent Progress bar for a Working or Blocked Agent with one.
    private func header(_ row: WatchAgentRow, now: Date) -> some View {
        let hostName = store.state?.showsHostNames == true ? row.hostName : nil
        let progress = row.progressDisplay(at: now)
        return VStack(alignment: .leading, spacing: 2) {
            StatusLineView(
                status: row.status, since: row.statusSince, hostName: hostName, now: now,
                progress: progress)
            Text(row.title)
                .font(.headline)
                .foregroundStyle(WatchBrand.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(WatchFormat.spokenTitle(row.title))
            if let progress {
                WatchProgressBar(display: progress, status: row.status)
                    .padding(.top, 2)
            }
        }
        .alwaysOnDimmed(isLuminanceReduced)
    }

    // MARK: Latest

    /// The Latest text as plain Body, in full and wrapped (the Crown
    /// scrolls), one row per paragraph so a long reply never lays out as one
    /// block: a spinner while loading, dimmed with "Checking…" while stale.
    /// A Working Agent's summary comes first, then its last reply under a
    /// "LAST REPLY" kicker. Each row is a direct child of the detail's
    /// `LazyVStack`.
    @ViewBuilder
    private func latest(dimmed: Bool) -> some View {
        switch store.latest(agentID) {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(WatchBrand.Colors.text2)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(.none):
            EmptyView()
        case .loaded(let latest?):
            latestParagraphs(latest.text, key: "text", dimmed: latest.isStale || dimmed)
            if store.isCheckingLatest(agentID) {
                Text("Checking…")
                    .font(.footnote)
                    .foregroundStyle(WatchBrand.Colors.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .alwaysOnDimmed(isLuminanceReduced)
            }
            if let lastReply = latest.lastReply {
                Text("LAST REPLY")
                    .metaFont(monospaced: true, trackingEm: 0.08)
                    .foregroundStyle(WatchBrand.Colors.text2)
                    .opacity(dimmed ? 0.5 : 1)
                    .alwaysOnDimmed(isLuminanceReduced)
                latestParagraphs(lastReply, key: "reply", dimmed: dimmed)
            }
        }
    }

    /// One Latest block as Body rows, one per paragraph
    /// (`WatchLatest.paragraphs`), each wrapped to any length.
    private func latestParagraphs(_ text: String, key: String, dimmed: Bool) -> some View {
        ForEach(Array(WatchLatest.paragraphs(text).enumerated()), id: \.offset) { index, paragraph in
            Text(verbatim: paragraph)
                .font(.body)
                .foregroundStyle(WatchBrand.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(dimmed ? 0.5 : 1)
                .privacySensitive()
                .alwaysOnDimmed(isLuminanceReduced)
                .id("\(key)-\(index)")
        }
    }

    // MARK: Mic

    /// Message Agent: the Waycar recorder when the iPhone transcribes voice
    /// (iOS 26+), otherwise system text input with live text.
    @ViewBuilder
    private func micControl(title: String) -> some View {
        let canAct = WatchAvailability.canAct(on: agentID, in: store)
        let label = "Message \(WatchFormat.spokenTitle(title))"
        if store.phoneTranscribesVoice {
            Button {
                store.route.append(.recorder(agentID))
            } label: {
                micGlyph
            }
            .glassCircleButton()
            .disabled(!canAct)
            .accessibilityLabel(label)
        } else {
            TextFieldLink(prompt: Text("To \(title)")) {
                micGlyph
            } onSubmit: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                store.sendText(trimmed, to: agentID)
            }
            .glassCircleButton()
            .disabled(!canAct)
            .accessibilityLabel(label)
        }
    }

    /// The accent `mic.fill` glyph, drawn on the glass circle.
    private var micGlyph: some View {
        Image(systemName: "mic.fill")
            .font(.title3)
            .foregroundStyle(WatchBrand.Colors.accent)
    }

    // MARK: Outgoing

    /// The message to show, or nil once the conversation moved on: a sent
    /// message hides when the phone reports a non-Working status that began
    /// after it was sent, since the Latest text above is then its reply.
    nonisolated static func visibleOutgoing(_ outgoing: WatchOutgoing?, row: WatchAgentRow?) -> WatchOutgoing? {
        guard let outgoing else { return nil }
        guard case .sent(_, let at) = outgoing.phase,
            let row, row.status != "working",
            let since = row.statusSince, since > at
        else { return outgoing }
        return nil
    }
}
