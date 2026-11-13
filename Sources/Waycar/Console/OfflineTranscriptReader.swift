import SwiftUI
import UIKit

/// An Agent's conversation as this device last saved it, for reading with
/// no connection (`ConsoleStore.savedTranscript(for:)`).
struct SavedTranscript: Equatable, Sendable {
    /// Oldest first.
    let messages: [ChatTranscriptMessage]
    /// When the copy was last saved, or last read from the Host and found
    /// current.
    let savedAt: Date
}

/// Whether the reader follows its newest message as the layout changes under
/// it (a message sent, queued rows appearing, the Composer card growing in
/// several steps). Only the user's own scroll decides: where it came to rest,
/// at the bottom or not. A scroll the reader ran itself, or one a layout
/// change moved, rests wherever the layout was mid-change, so it reads as
/// "not at the bottom" at times and must never switch following off.
struct OfflineReaderFollow: Equatable {
    private(set) var followsNewest = true

    /// A scroll came to rest: `afterUserScroll` when the user's finger drove it
    /// (dragging, or the fling after), `nearBottom` where it ended.
    mutating func scrollCameToRest(afterUserScroll: Bool, nearBottom: Bool) {
        guard afterUserScroll else { return }
        followsNewest = nearBottom
    }

    /// Whether a change of content or of the space under it scrolls to the
    /// newest message, now and again once the layout has settled.
    var anchorsAfterChange: Bool { followsNewest }
}

/// What the terminal screen measures for the offline reader: the input
/// chrome's top edge, the terminal's region, and how tall the Composer's
/// queued rows are, all in global coordinates. A box of its own rather than
/// the screen's `@State`: these move with every keyboard frame and every
/// layout pass, and the screen's body must not re-run for them. Only what
/// reads them (the reader's modifier, and the screen's queue cap while the
/// reader is open) is invalidated.
@MainActor
@Observable
final class OfflineReaderGeometry {
    /// The input chrome's top edge; nil until measured.
    var chromeTop: CGFloat?
    var terminalRegion: CGRect = .zero
    var queuedAreaHeight: CGFloat = 0
}

/// The rules of offline reading, apart from the views that show them.
enum OfflineReading {
    /// How long a plain connect has to last, on a device whose network is up,
    /// before the terminal offers its saved conversation: a session that has
    /// not loaded in a while can take a few seconds on a fast network, and an
    /// offer would flicker over each. With no network the offer is at once.
    static let slowConnectDelay: Duration = .seconds(8)

    /// Why the terminal cannot be read live, as far as the app can tell. The
    /// device's own network path (`NetworkPathMonitor`) decides between a
    /// device that is offline and one whose Host cannot be reached.
    enum Cause: Equatable {
        /// The device has no usable network.
        case offline
        /// The device has a network, and the Host is unreachable or quiet.
        case hostUnreachable
        /// The attach ended on a Host that can be reached.
        case disconnected
        /// The device has a network and the terminal is still connecting.
        case connecting
    }

    /// nil while the terminal is live, or where no terminal state applies.
    static func cause(connection: TerminalConnectionIndicator?, hasNetwork: Bool) -> Cause? {
        guard let connection else { return nil }
        switch connection {
        case .live: return nil
        case _ where !hasNetwork: return .offline
        case .detached: return .disconnected
        case .hostUnavailable: return .hostUnreachable
        case .reconnecting(_, let isStalled): return isStalled ? .hostUnreachable : .connecting
        }
    }

    /// Whether the terminal offers its saved conversation: a copy with
    /// something to read is kept and the terminal cannot be read live. That is
    /// every cause but a plain connect on a device with a network, which waits
    /// `slowConnectDelay` (`reconnectingFor`; the screen counts it and resets
    /// it when the terminal is live). `connection` is nil where no terminal
    /// state applies.
    static func offersReader(
        connection: TerminalConnectionIndicator?, saved: SavedTranscript?,
        hasNetwork: Bool = true, reconnectingFor: Duration = .zero
    ) -> Bool {
        guard let saved, !saved.messages.isEmpty,
            let cause = cause(connection: connection, hasNetwork: hasNetwork)
        else { return false }
        if cause == .connecting { return reconnectingFor >= slowConnectDelay }
        return true
    }

    /// A plain connect on a device with a network: the state `slowConnectDelay`
    /// counts.
    static func isSlowConnectCandidate(
        _ connection: TerminalConnectionIndicator?, hasNetwork: Bool
    ) -> Bool {
        cause(connection: connection, hasNetwork: hasNetwork) == .connecting
    }

    /// How old the copy is, as the words after "Saved": "just now",
    /// "2 hours ago". A clock that moved back reads as just now.
    static func age(savedAt: Date, now: Date) -> String {
        AgentSummaryLine.spokenAge(max(0, now.timeIntervalSince(savedAt)))
    }

    /// The offline card's first line: what is wrong, said only as far as the
    /// app knows it. "You're offline" is for a device with no network.
    static func offerTitle(_ cause: Cause, hostTitle: String? = nil) -> String {
        switch cause {
        case .offline: "You're offline"
        // A Host that cannot be used says why in its own words ("Authentication
        // failed", "Host Unavailable"); the generic line is for one that is
        // only quiet or unreachable.
        case .hostUnreachable:
            hostTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Can't reach your Host"
        case .disconnected: "Terminal disconnected"
        case .connecting: "Still connecting…"
        }
    }

    /// The Host's own title when the Host cannot be used (`.hostUnavailable`).
    static func hostTitle(_ connection: TerminalConnectionIndicator?) -> String? {
        if case .hostUnavailable(let title, _)? = connection { return title }
        return nil
    }

    /// The offline card's second line: the saved copy on offer, and its age.
    static func offerSubtitle(savedAt: Date, now: Date) -> String {
        "Read saved copy · \(age(savedAt: savedAt, now: now))"
    }

    /// The card's and banner's icon: a slashed network only for a device that
    /// has none.
    static func symbol(_ cause: Cause) -> String {
        switch cause {
        case .offline: "wifi.slash"
        case .hostUnreachable: "server.rack"
        case .disconnected: "cable.connector.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        }
    }

    /// The reader's banner: that this is a saved copy (and "Offline" only for
    /// a device with no network), or that the terminal is back; nil where no
    /// terminal state applies (it lives in another window).
    static func banner(
        connection: TerminalConnectionIndicator?, hasNetwork: Bool, savedAt: Date, now: Date
    ) -> String? {
        guard let connection else { return nil }
        let ago = age(savedAt: savedAt, now: now)
        guard let cause = cause(connection: connection, hasNetwork: hasNetwork) else {
            return reconnectedBanner
        }
        return cause == .offline ? "Offline · saved copy, \(ago)" : "Saved copy, \(ago)"
    }

    static let reconnectedBanner = "Back online · the terminal is live again"

    /// The banner's short form for the one-line header while the keyboard is up.
    static func compactBanner(
        connection: TerminalConnectionIndicator?, hasNetwork: Bool, savedAt: Date, now: Date
    ) -> String? {
        guard let connection else { return nil }
        let ago = age(savedAt: savedAt, now: now)
        guard let cause = cause(connection: connection, hasNetwork: hasNetwork) else {
            return "Back online"
        }
        return cause == .offline ? "Offline · \(ago)" : "Saved · \(ago)"
    }

    /// Whether the terminal is back while the reader is open.
    static func isTerminalLive(_ connection: TerminalConnectionIndicator?) -> Bool {
        if let connection, case .live = connection { return true }
        return false
    }

    /// How far above the end of the copy still counts as "at the bottom": a
    /// message's half-line of slack, not a screenful the user scrolled away.
    static let nearBottomTolerance: CGFloat = 48

    /// Whether the visible edge (`visibleMaxY`, in the content's coordinates)
    /// is at the end of `contentHeight`, give or take `nearBottomTolerance`.
    static func isNearBottom(visibleMaxY: CGFloat, contentHeight: CGFloat) -> Bool {
        visibleMaxY >= contentHeight - nearBottomTolerance
    }


    /// The height of the reader's viewport: from the reader's top edge
    /// (`readerMinY`) to the input chrome's top edge (`chromeTop`), both in
    /// one coordinate space, so the copy ends exactly where the chrome
    /// begins. Zero when the chrome has reached the reader's top; nil while
    /// the chrome is not measured yet (the reader then fills its frame).
    static func viewportHeight(readerMinY: CGFloat, chromeTop: CGFloat?) -> CGFloat? {
        guard let chromeTop else { return nil }
        return max(0, chromeTop - readerMinY)
    }

    /// How far above its host's bottom edge (`hostMaxY`) the Read pill
    /// rests: clear of the input chrome's top edge (`chromeTop`) by a
    /// margin, and never less than the margin from the edge itself.
    static func pillBottomPadding(hostMaxY: CGFloat, chromeTop: CGFloat?) -> CGFloat {
        let margin: CGFloat = 12
        guard let chromeTop else { return 24 }
        return max(24, hostMaxY - chromeTop + margin)
    }

    /// The least room the copy keeps above the chrome while the Composer
    /// card grows: a header and a bubble and a half, or this share of the
    /// room the screen has above the keyboard, whichever is more.
    static let minimumVisibleHeight: CGFloat = 200
    static let minimumVisibleFraction: CGFloat = 0.35
    /// The Queued Messages' area never shrinks below this, so a queued row
    /// is still seen (it scrolls inside the cap).
    static let minimumQueueAreaHeight: CGFloat = 48

    /// The tallest the Composer card's Queued Messages area may be so the copy
    /// keeps `minimumVisibleHeight` (or `minimumVisibleFraction` of
    /// `availableHeight`): what it shows now (`queueAreaHeight`) plus the
    /// room the reader has over its minimum, negative when it has less.
    /// `availableHeight` is the window's height above the keyboard: a number
    /// the chrome's own growth does not move (the terminal's frame could,
    /// which would make the minimum chase the cap). The reader starts at
    /// `containerMinY`; the chrome's top edge is `chromeTop` (one coordinate
    /// space). Shrinking the area moves the chrome's top down by as much, so
    /// the answer is the same before and after: it settles.
    static func queueAreaCap(
        containerMinY: CGFloat, availableHeight: CGFloat, chromeTop: CGFloat,
        queueAreaHeight: CGFloat
    ) -> CGFloat {
        let minimum = max(minimumVisibleHeight, minimumVisibleFraction * availableHeight)
        let visible = chromeTop - containerMinY
        return max(minimumQueueAreaHeight, queueAreaHeight + visible - minimum)
    }
}

/// The Read pill and the reader over a terminal screen. The pill is the only
/// thing that takes touches while it shows; the reader, once opened, covers
/// the terminal above the input chrome, whose Composer card stays below it.
struct OfflineReadingPresentation: ViewModifier {
    let saved: SavedTranscript?
    let connection: TerminalConnectionIndicator?
    /// The device has a usable network (`ConsoleStore.hasNetwork`).
    let hasNetwork: Bool
    /// `OfflineReading.offersReader` for the screen's state, which the
    /// screen also uses for the connection popover's entry.
    let offersReader: Bool
    @Binding var isReading: Bool
    let agentName: String
    let composer: AgentComposerStore
    let palette: TerminalThemePalette
    let loadMedia: ChatMediaLoader
    /// Opens the reader; the screen also brings up the Composer card.
    let open: () -> Void
    /// What the screen measures; read only where the pill or the reader is shown.
    let geometry: OfflineReaderGeometry
    /// The keyboard is up as the reader opens (the Composer's, already).
    let keyboardIsUp: Bool
    /// The pill's host frame bottom in global coordinates.
    @State private var pillHostMaxY: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                // The pill rests above the chrome's measured top edge, not a
                // fixed distance from the bottom: a tall Composer card must
                // not push it onto the terminal's centre.
                if !isReading, offersReader, let saved,
                    let cause = OfflineReading.cause(connection: connection, hasNetwork: hasNetwork)
                {
                    Color.clear
                        .overlay(alignment: .bottom) {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                TerminalReadSavedPill(
                                    palette: palette,
                                    systemImage: OfflineReading.symbol(cause),
                                    title: OfflineReading.offerTitle(
                                        cause, hostTitle: OfflineReading.hostTitle(connection)),
                                    subtitle: OfflineReading.offerSubtitle(
                                        savedAt: saved.savedAt, now: context.date),
                                    action: open)
                            }
                                .padding(.horizontal, 16)
                                .padding(
                                    .bottom,
                                    OfflineReading.pillBottomPadding(
                                        hostMaxY: pillHostMaxY, chromeTop: geometry.chromeTop))
                                .transition(.opacity)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                            pillHostMaxY = $0
                        }
                }
            }
            .overlay {
                if isReading, let saved {
                    OfflineTranscriptReaderView(
                        agentName: agentName, saved: saved, connection: connection,
                        hasNetwork: hasNetwork,
                        composer: composer, loadMedia: loadMedia, chromeTop: geometry.chromeTop,
                        startsWithKeyboardUp: keyboardIsUp
                    ) {
                        isReading = false
                    }
                    .transition(.opacity)
                }
            }
    }
}

/// The saved conversation, newest message at the bottom, under a header that
/// says how old the copy is and whether the terminal is back.
struct OfflineTranscriptReaderView: View {
    let agentName: String
    let saved: SavedTranscript
    let connection: TerminalConnectionIndicator?
    let hasNetwork: Bool
    let composer: AgentComposerStore
    let loadMedia: ChatMediaLoader
    let chromeTop: CGFloat?
    /// The Composer's keyboard is already up when the reader opens: the
    /// header is compact from the first frame, not from the next keyboard event.
    let startsWithKeyboardUp: Bool
    let close: () -> Void
    /// Messages sent from here show under the copy, which is a snapshot.
    @State private var openedAt = Date()
    @AccessibilityFocusState private var headerIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The keyboard is up: the header takes one line.
    @State private var isKeyboardUp = false
    /// Whether the reader follows the newest message: set by where the user
    /// last left their own scroll, never by layout (`OfflineReaderFollow`).
    @State private var follow = OfflineReaderFollow()
    /// The latest scroll geometry's reading, adopted when the user's scroll rests.
    @State private var restingNearBottom = true
    /// The re-anchor that waits for the layout to stop moving.
    @State private var settleTask: Task<Void, Never>?
    /// The reader's top edge in global coordinates.
    @State private var readerMinY: CGFloat = 0

    private static let bottomID = "offline-reader-bottom"

    var body: some View {
        // The input chrome (status row, Composer card, Toolbar, footer) floats
        // over the bottom of the terminal's frame, and safe-area insets do
        // not describe it, so the chrome's top edge is measured and the
        // scroll view's viewport gets an explicit height from the reader's top
        // to that edge: the copy ends exactly at the chrome's top edge and can
        // be scrolled to it. The opaque brand background is its own layer
        // behind, down to the screen's edge, so nothing of the terminal
        // shows through the chrome or the keyboard.
        let viewport = OfflineReading.viewportHeight(readerMinY: readerMinY, chromeTop: chromeTop)
        ZStack(alignment: .top) {
            Brand.Colors.bg.ignoresSafeArea(.container, edges: .bottom)
            content(viewportHeight: viewport)
                .frame(height: viewport)
                .frame(maxWidth: .infinity, maxHeight: viewport == nil ? .infinity : nil, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
            readerMinY = $0
        }
        // Dark-only brand palette, as in the chat view.
        .environment(\.colorScheme, Brand.colorScheme)
        // Not modal: VoiceOver must still reach the Composer under the reader.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.offlineReader")
        .onAppear { isKeyboardUp = startsWithKeyboardUp }
        // VoiceOver starts at the header, not wherever it was on the terminal.
        .task {
            await Task.yield()
            headerIsFocused = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in isKeyboardUp = true }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in isKeyboardUp = false }
    }

    private func content(viewportHeight: CGFloat?) -> some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy, as in the chat view: a lazy stack sizes rows
                    // it has not built from estimates, so a long copy opened
                    // at its bottom could land past the real content.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(saved.messages) { message in
                            ChatMessageRow(message: message, agentName: agentName, loadMedia: loadMedia)
                                .equatable()
                        }
                        ForEach(sentMessages) { message in
                            ChatPendingBubble(
                                message: message,
                                canSendAnyway: composer.canSendHeldAnyway,
                                retry: { Task { await composer.retry(message.id) } },
                                edit: { composer.withdrawToDraft(message.id) },
                                cancel: { composer.deleteQueued(message.id) },
                                sendAnyway: { composer.sendAnyway(message.id) })
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                // Where the user left their own scroll, adopted when it comes
                // to rest. A message or the Composer card growing changes the
                // geometry (and may run a scroll of its own, animating to rest
                // mid-layout) without the user moving: those never decide.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    OfflineReading.isNearBottom(
                        visibleMaxY: geometry.visibleRect.maxY,
                        contentHeight: geometry.contentSize.height)
                } action: { _, isNear in
                    restingNearBottom = isNear
                }
                .onScrollPhaseChange { old, phase in
                    guard phase == .idle else { return }
                    follow.scrollCameToRest(
                        afterUserScroll: old == .interacting || old == .decelerating,
                        nearBottom: restingNearBottom)
                }
                .onChange(of: composer.messages.map(\.state)) { _, _ in anchor(proxy) }
                .onChange(of: composer.messages.map(\.id)) { _, _ in anchor(proxy) }
                .onChange(of: viewportHeight) { _, _ in anchor(proxy) }
                // The header changes height when the terminal comes back (Done
                // becomes the prominent button), which moves no viewport edge.
                .onChange(of: OfflineReading.isTerminalLive(connection)) { _, _ in anchor(proxy) }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIResponder.keyboardDidShowNotification)
                ) { _ in
                    anchor(proxy)
                }
            }
        }
    }

    /// The banner's icon: the cause's, or a plain network once the terminal is back.
    private var bannerSymbol: String {
        OfflineReading.cause(connection: connection, hasNetwork: hasNetwork)
            .map(OfflineReading.symbol) ?? "wifi"
    }

    private var header: some View {
        let isLive = OfflineReading.isTerminalLive(connection)
        // One line while the keyboard is up: the copy needs the room.
        let compact = isKeyboardUp
        let title = Text(agentName)
            .font(.headline)
            .foregroundStyle(Brand.Colors.text)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if compact {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            title.lineLimit(1)
                            if connection != nil {
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Label(
                                        OfflineReading.compactBanner(
                                            connection: connection, hasNetwork: hasNetwork,
                                            savedAt: saved.savedAt, now: context.date) ?? "",
                                        systemImage: bannerSymbol)
                                        .font(.caption)
                                        .lineLimit(1)
                                        // The age outranks a long title: the title
                                        // truncates first.
                                        .fixedSize(horizontal: true, vertical: false)
                                        .layoutPriority(1)
                                        .foregroundStyle(
                                            isLive ? Brand.Colors.violetSoft : Brand.Colors.text2)
                                }
                            }
                        }
                    } else {
                        title.lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityFocused($headerIsFocused)
                Spacer(minLength: 8)
                // The reader stays open when the terminal comes back: the user
                // may be mid-sentence, so closing it is theirs to do.
                if isLive {
                    Button("Done", action: close)
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.Colors.chatUser)
                        .accessibilityIdentifier("terminal.offlineReader.done")
                } else {
                    Button("Done", action: close)
                        .font(.body.weight(.semibold))
                        .tint(Brand.Colors.violetSoft)
                        .accessibilityIdentifier("terminal.offlineReader.done")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, compact ? 6 : 10)
            // The banner says this is a saved copy, or that the terminal is
            // back. It waits for the keyboard to go; the compact title row
            // carries the same news inline meanwhile.
            if !compact, connection != nil {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(
                        OfflineReading.banner(
                            connection: connection, hasNetwork: hasNetwork,
                            savedAt: saved.savedAt, now: context.date) ?? "",
                        systemImage: bannerSymbol
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isLive ? Brand.Colors.violetSoft : Brand.Colors.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        (isLive ? Brand.Colors.violetSoft : Brand.Colors.text3).opacity(0.14))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .background(Brand.Colors.ink)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Brand.Colors.text3.opacity(0.25)).frame(height: 1)
        }
    }

    /// What was sent from the Composer since the reader opened and has left
    /// the device or is leaving it; waiting and failed messages show in the
    /// Composer card under the reader.
    private var sentMessages: [AgentComposerStore.Message] {
        composer.messages
            .filter { message in
                guard message.sentAt >= openedAt else { return false }
                switch message.state {
                case .sending, .delivered: return true
                case .queued, .held, .failed: return false
                }
            }
            .sorted { $0.sentAt < $1.sentAt }
    }

    /// Brings the newest message into view after a change, if the reader
    /// follows it: at once, and again once the layout has stopped changing. A
    /// Composer card that grows in several steps (queued rows crossing their
    /// cap, rows scrolling inside it) moves the viewport several times, and a
    /// scroll run against a layout that is still moving lands short; the last
    /// one, a moment after the last change, runs against the final layout.
    /// Without animation under Reduce Motion.
    private func anchor(_ proxy: ScrollViewProxy) {
        guard follow.anchorsAfterChange else { return }
        scrollToNewest(proxy, animated: !reduceMotion)
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, follow.anchorsAfterChange else { return }
            scrollToNewest(proxy, animated: false)
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }
}
