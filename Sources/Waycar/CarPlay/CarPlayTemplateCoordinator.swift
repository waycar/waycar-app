import CarPlay
import OSLog
import UIKit

/// The CarPlay template tree (docs/design/carplay.md §4–§5): a root list of
/// Agents with "Talk to Waycar" first, and a voice control template per
/// tap. Voice turns run on `AgentVoiceService`; this type only renders.
///
/// The screen never carries content: voice states keep generic titles
/// ("Ask <Agent>", "Sending…", "Replying", a correction's "Send?"), never
/// the transcript, the reply or a command (CPG p.4 #6, p.7 #3). An audio
/// session is active only while a turn the driver started runs (CPG p.7
/// #2, p.29). The Console's connections belong to the app's activity
/// coordinator; this type never resumes or suspends them.
@MainActor
final class CarPlayTemplateCoordinator: NSObject, CPInterfaceControllerDelegate {
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "carplay")

    /// The voice control template's states. A template holds at most
    /// five; each kind of turn builds its own template.
    enum VoiceState: String {
        case listening, confirm, sending, waiting, replying
        case checking, blockedAllow, blockedHold, answered
        case briefing
    }

    /// What the screen does for a conversation phase.
    enum ConversationScreen: Equatable {
        case show(VoiceState)
        /// Dismiss the template after this long.
        case close(after: Duration)
    }

    /// The template ignores state changes that come too fast.
    static let minimumStateDwell: Duration = .seconds(1.2)
    /// Non-Blocked changes wait this long, so a busy Host does not
    /// redraw the list on every event (§4 Refresh).
    private static let refreshCoalescing: Duration = .seconds(5)
    private static let ageTick: Duration = .seconds(60)
    /// Progress ring stroke as a share of the row image side (~3 pt).
    private static let ringLineWidthRatio: CGFloat = 0.08
    /// The unfilled ring segments: the status colour, faint.
    private static let ringTrackAlpha: CGFloat = 0.25
    /// A stale estimate's ring (C2 `isStale`).
    private static let staleRingAlpha: CGFloat = 0.4

    private let interfaceController: CPInterfaceController
    private let console: ConsoleStore
    private let voice: AgentVoiceService
    private let root = CPListTemplate(title: "Waycar", sections: [])
    private var model: CarPlayListModel?
    private var turns: [UInt64: Task<Void, Never>] = [:]
    private var presentation = CarPlayTurnMachine()
    /// CarPlay objects and Tasks remain resources, never machine state.
    private var templates: [UInt64: CPVoiceControlTemplate] = [:]
    private var voiceTemplate: CPVoiceControlTemplate? {
        presentation.turn.flatMap { templates[$0.template] }
    }
    /// The back-and-forth on screen, if the turn is one.
    private var conversation: AgentVoiceConversation?
    private var pendingText: String? { presentation.pendingText }
    private var isRunning = false
    /// A coalesced render waiting out `refreshCoalescing`.
    private var pendingRender: Task<Void, Never>?
    /// Re-renders once a minute so status ages advance.
    private var ageTicker: Task<Void, Never>?

    /// The car's templates over `console`.
    /// - Parameter actions: the app's shared `AgentActionService`
    ///   (`WaycarAppModel.agentActions`), so the car and the watch keep one
    ///   message and one answer in flight per Agent between them.
    init(
        interfaceController: CPInterfaceController, console: ConsoleStore,
        actions: AgentActionService, dictation: (any DictationEngine)?
    ) {
        self.interfaceController = interfaceController
        self.console = console
        voice = AgentVoiceService(
            console: console, actions: actions, dictation: dictation, speaker: CarSpeaker())
        super.init()
    }

    func start() {
        isRunning = true
        interfaceController.delegate = self
        interfaceController.setRootTemplate(root, animated: false) { _, error in
            if let error { Self.log.error("CarPlay root failed: \(error)") }
        }
        render()
        observeAgents()
        ageTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.ageTick)
                guard let self, !Task.isCancelled else { return }
                self.render()
            }
        }
    }

    func stop() {
        isRunning = false
        pendingRender?.cancel()
        pendingRender = nil
        ageTicker?.cancel()
        ageTicker = nil
        endTurn(dismiss: false)
    }

    /// The car's screen switched to another app: the turn ends now. A listen
    /// must not keep recording, a spoken "yes" from the cabin must not act,
    /// and a reply still awaited must not take the car's audio back later.
    /// Unsent text goes to the draft; the voice template is dismissed.
    func sceneDidEnterBackground() {
        endTurn()
    }

    // MARK: List

    private func observeAgents() {
        withObservationTracking {
            _ = console.agents
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.agentsChanged()
                self.observeAgents()
            }
        }
    }

    /// A newly Blocked Agent shows at once; anything else coalesces.
    private func agentsChanged() {
        let shownBlocked = Set(
            (model?.rows ?? []).filter { $0.status == .blocked }.map(\.id))
        let newlyBlocked = console.agents.contains {
            $0.agent.status == .blocked && !shownBlocked.contains($0.id)
        }
        if newlyBlocked {
            render()
            return
        }
        guard pendingRender == nil else { return }
        pendingRender = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshCoalescing)
            guard let self, !Task.isCancelled else { return }
            self.render()
        }
    }

    private func render() {
        pendingRender?.cancel()
        pendingRender = nil
        let next = CarPlayListModel(
            agents: console.agents,
            maximumItemCount: Int(CPListTemplate.maximumItemCount),
            now: Date())
        guard next != model else { return }
        model = next
        root.updateSections(sections(for: next))
    }

    private func sections(for model: CarPlayListModel) -> [CPListSection] {
        let talk = CPListItem(
            text: CarPlayListModel.talkTitle, detailText: nil,
            image: listImage("waveform", tint: .label))
        talk.handler = { [weak self] _, completion in
            self?.presentBriefing()
            completion()
        }
        let needYou = model.rows.filter { $0.status == .blocked || $0.status == .done }
        let working = model.rows.filter { $0.status == .working }
        let rest = model.rows.filter { ![.blocked, .done, .working].contains($0.status) }
        let groups: [(header: String, rows: [CarPlayListModel.Row])] = [
            (needYou.count == 1 ? "1 needs you" : "\(needYou.count) need you", needYou),
            ("Working", working),
            ("Idle", rest),
        ]
        return [CPListSection(items: [talk])]
            + groups.filter { !$0.rows.isEmpty }.map { group in
                CPListSection(
                    items: group.rows.map(listItem), header: group.header,
                    sectionIndexTitle: nil)
            }
    }

    private func listItem(_ row: CarPlayListModel.Row) -> CPListItem {
        let item = CPListItem(
            text: row.title, detailText: row.detail,
            image: listImage(row.symbolName, tint: row.status.inkUIColor, ring: row.ring))
        let id = row.id
        item.handler = { [weak self] _, completion in
            self?.open(id)
            completion()
        }
        return item
    }

    private func listImage(
        _ symbolName: String, tint: UIColor, ring: CarPlayListModel.Ring? = nil
    ) -> UIImage? {
        let size = CPListItem.maximumImageSize
        let side = min(size.width, size.height)
        guard let ring else {
            return symbolImage(symbolName, tint: tint, pointSize: side * 0.6, canvas: size)
        }
        // The glyph shrinks into the ring's hole: a square inscribed in
        // the inner circle, with a little air.
        let lineWidth = side * Self.ringLineWidthRatio
        let hole = (side - 2 * lineWidth) * 0.62
        return symbolImage(
            symbolName, tint: tint, pointSize: hole, canvas: size,
            glyphBox: CGSize(width: hole, height: hole)
        ) { context, color in
            Self.drawRing(ring, color: color, lineWidth: lineWidth, canvas: size, in: context)
        }
    }

    /// The symbol drawn into a bitmap in the car's colours: CarPlay
    /// renders template images in its own process, where a dynamic
    /// colour or a symbol tint does not survive (both came out black).
    /// `decoration` draws first, with the tint resolved for the car.
    private func symbolImage(
        _ symbolName: String, tint: UIColor, pointSize: CGFloat, canvas: CGSize,
        glyphBox: CGSize? = nil,
        decoration: ((CGContext, UIColor) -> Void)? = nil
    ) -> UIImage? {
        let traits = interfaceController.carTraitCollection
        let color = tint.resolvedColor(with: traits)
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard
            let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        else { return nil }
        let box = glyphBox ?? canvas
        let scale = min(
            1, box.width / symbol.size.width, box.height / symbol.size.height)
        let fitted = CGSize(
            width: symbol.size.width * scale, height: symbol.size.height * scale)
        let format = UIGraphicsImageRendererFormat(for: traits)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            decoration?(context.cgContext, color)
            symbol.draw(
                in: CGRect(
                    x: (canvas.width - fitted.width) / 2, y: (canvas.height - fitted.height) / 2,
                    width: fitted.width, height: fitted.height))
        }
    }

    /// The progress ring in the status colour: one segment per step or
    /// phase from 12 o'clock clockwise, done segments solid and the rest
    /// a faint track; a continuous arc past 12 steps. Stale estimates dim.
    private static func drawRing(
        _ ring: CarPlayListModel.Ring, color: UIColor, lineWidth: CGFloat, canvas: CGSize,
        in context: CGContext
    ) {
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let radius = (min(canvas.width, canvas.height) - lineWidth) / 2
        let track = color.withAlphaComponent(Self.ringTrackAlpha)
        let top = -CGFloat.pi / 2
        func stroke(from start: CGFloat, to end: CGFloat, _ stroke: UIColor) {
            let path = UIBezierPath(
                arcCenter: center, radius: radius, startAngle: start, endAngle: end,
                clockwise: true)
            path.lineWidth = lineWidth
            stroke.setStroke()
            path.stroke()
        }
        context.saveGState()
        defer { context.restoreGState() }
        if ring.isStale { context.setAlpha(Self.staleRingAlpha) }
        switch ring.shape {
        case .segments(let count, let filled):
            guard count > 0 else { return }
            let span = 2 * CGFloat.pi / CGFloat(count)
            let gap = count > 1 ? min(span * 0.3, lineWidth / radius) : 0
            for index in 0..<count {
                let start = top + CGFloat(index) * span + gap / 2
                stroke(from: start, to: start + span - gap, index < filled ? color : track)
            }
        case .arc(let fraction):
            stroke(from: top, to: top + 2 * .pi, track)
            let done = CGFloat(min(1, max(0, fraction)))
            if done > 0 { stroke(from: top, to: top + 2 * .pi * done, color) }
        }
    }

    /// "Waiting for reply" as iMessage-style bouncing dots: one bitmap per
    /// `CarPlayTypingDots` frame, drawn in the car's colours (see
    /// `symbolImage`), the raised dot white and the resting ones gray.
    private func typingDotsImage(canvas: CGSize) -> UIImage? {
        let traits = interfaceController.carTraitCollection
        let format = UIGraphicsImageRendererFormat(for: traits)
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let diameter = canvas.width * 0.16
        let gap = diameter * 0.6
        let rise = diameter * 0.6
        let count = CGFloat(CarPlayTypingDots.dotCount)
        let startX = (canvas.width - (count * diameter + (count - 1) * gap)) / 2
        let restY = (canvas.height - diameter) / 2 + rise / 2
        let raisedColor = UIColor.white.resolvedColor(with: traits)
        let restColor = UIColor.systemGray.resolvedColor(with: traits)
        let frames = CarPlayTypingDots.raisedDotPerFrame.map { raised in
            renderer.image { context in
                for dot in 0..<CarPlayTypingDots.dotCount {
                    let isRaised = dot == raised
                    (isRaised ? raisedColor : restColor).setFill()
                    context.cgContext.fillEllipse(
                        in: CGRect(
                            x: startX + CGFloat(dot) * (diameter + gap),
                            y: isRaised ? restY - rise : restY,
                            width: diameter, height: diameter))
                }
            }
        }
        return UIImage.animatedImage(with: frames, duration: CarPlayTypingDots.cycleDuration)
    }

    private func open(_ id: ConsoleAgent.ID) {
        guard let agent = console.agents.first(where: { $0.id == id }) else { return }
        if agent.agent.status == .blocked {
            presentBlocked(id)
        } else {
            presentConversation(agent)
        }
    }

    // MARK: Conversation

    /// A hands-free back-and-forth with the Agent (§5 Conversation):
    /// status, then listen, send when the driver pauses, the reply spoken,
    /// and listening again, until CarPlay's close, a spoken exit, the scene
    /// leaving the car's screen, or two minutes with nothing said. No
    /// buttons: the template's own close ends it.
    /// `AgentVoiceConversation` runs it; this renders it.
    private func presentConversation(_ agent: ConsoleAgent) {
        // The Agent's name, not content: the list shows it too. It tells
        // the driver whom the next listen asks.
        let title = AgentGlanceList.title(for: agent)
        let template = CPVoiceControlTemplate(voiceControlStates: [
            state(.listening, ["Ask \(title)", title, "Listening"], symbol: "waveform"),
            state(.sending, ["Sending…", "Sending"], symbol: "arrow.up.circle"),
            state(.waiting, ["Waiting for reply", "Waiting"], typingDots: true),
            state(.replying, ["Replying"], symbol: "speaker.wave.2.fill"),
        ])
        present(template, for: agent.id, kind: .conversation)
        guard let templateToken = presentation.turn?.template else { return }
        let conversation = AgentVoiceConversation(
            agentID: agent.id, voice: voice,
            announcePending: { [weak self] in await self?.announcePending() }
        ) { [weak self] phase in self?.conversationEntered(phase, template: templateToken) }
        self.conversation = conversation
        conversation.start()
    }

    /// Every phase of a conversation as the screen shows it. The driver
    /// ending it (a close, a spoken "stop") closes at once; a conversation
    /// that spoke its last line or went quiet stays long enough for the
    /// change to show.
    static func screen(for phase: AgentVoiceConversation.Phase) -> ConversationScreen {
        switch phase {
        case .listening: .show(.listening)
        case .sending: .show(.sending)
        case .waiting: .show(.waiting)
        case .replying: .show(.replying)
        case .ended(.driver): .close(after: .zero)
        case .ended(.silence), .ended(.finished): .close(after: minimumStateDwell)
        }
    }

    /// An ended conversation reports nothing more, and the coordinator
    /// drops its own before ending it, so a phase arriving while
    /// `conversation` is set is the current conversation's.
    private func conversationEntered(_ phase: AgentVoiceConversation.Phase, template: UInt64) {
        guard conversation != nil, presentation.turn?.template == template,
            let step = presentation.turn?.step else { return }
        switch Self.screen(for: phase) {
        case .show(let state):
            activate(state)
        case .close(let delay):
            guard delay > .zero else {
                endTurn()
                return
            }
            transition(.finish(step))
            runTurn { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, self.isCurrent(step) else { return }
                self.endTurn()
            }
        }
    }

    /// Cancel: what was heard and not sent becomes the Agent's draft.
    private func cancelPending() {
        guard pendingText != nil else {
            endTurn()
            return
        }
        replaceTurn { await $0.keepPendingAsDraft() }
    }

    private func keepPendingAsDraft() async {
        guard pendingText != nil else { return }
        transition(.draft)
        await finish(saying: CarVoiceScript.notSent)
    }

    // MARK: Blocked

    /// The prompt read from the screen and spoken; Deny first, Allow only
    /// when the car rules allow it, Hold for a held one (§5 rules 1–7).
    private func presentBlocked(_ id: ConsoleAgent.ID) {
        let deny = { [unowned self] in
            self.button("Deny", symbol: "xmark") { coordinator in
                coordinator.answer { voice, turn in await voice.deny(turn) }
            }
        }
        let template = CPVoiceControlTemplate(voiceControlStates: [
            // Deny only while the question is read: Allow never comes
            // before the driver heard what it allows.
            state(.checking, ["Checking…", "Checking"], symbol: "hand.raised.fill", buttons: [deny()]),
            // Deny first: the knob's focus lands on the first button, so
            // the safe answer is the default.
            state(
                .blockedAllow, ["Waiting on approval", "Approval"], symbol: "hand.raised.fill",
                buttons: [
                    deny(),
                    button("Allow", symbol: "checkmark") { coordinator in
                        coordinator.answer { voice, turn in await voice.allow(turn) }
                    },
                ]),
            state(
                .blockedHold, ["Waiting on approval", "Approval"], symbol: "hand.raised.fill",
                buttons: [deny(), button("Hold", symbol: "pause") { $0.holdBlocked() }]),
            state(
                .confirm, ["Send?"], symbol: "paperplane",
                buttons: [
                    button("Send", symbol: "paperplane.fill") { $0.sendCorrection() },
                    button("Cancel", symbol: "xmark") { $0.cancelPending() },
                ]),
            state(.answered, ["Done"], symbol: "checkmark.circle"),
        ])
        present(template, for: id, kind: .blocked)
        guard let step = presentation.turn?.step else { return }
        runTurn { [weak self] in
            guard let self, self.isCurrent(step), self.voiceTemplate === template else { return }
            self.voice.speaker.beginTurn()
            self.activate(.checking)
            let blocked = await self.voice.blockedTurn(for: id)
            guard self.isCurrent(step) else { return }
            await self.announce(blocked, saying: blocked.question)
        }
    }

    /// Speaks `line` with only Deny on screen, then shows `blocked`'s
    /// buttons — Allow only once the question was heard in full — and
    /// listens once for a spoken answer or correction; a read-only prompt
    /// ends the turn.
    private func announce(_ blocked: AgentVoiceService.BlockedTurn, saying line: String) async {
        guard let step = presentation.turn?.step, isCurrent(step) else { return }
        transition(.announce(step, blocked))
        activate(.checking)
        let spoken = await voice.speakQuestion(blocked, saying: line)
        guard isCurrent(step) else { return }
        transition(.spoken(step))
        switch blocked.buttons {
        case .denyAndAllow: if spoken { activate(.blockedAllow) }
        case .denyAndHold: activate(.blockedHold)
        case .readOnly: break
        }
        guard blocked.buttons != .readOnly else {
            await finish(saying: "")
            return
        }
        await announcePending()
        guard isCurrent(step) else { return }
        await listenForAnswer(to: blocked, reasked: false)
    }

    /// One spoken answer to `blocked`; an unrecognised word gets one re-ask.
    private func listenForAnswer(to blocked: AgentVoiceService.BlockedTurn, reasked: Bool) async {
        guard let step = presentation.turn?.step, isCurrent(step) else { return }
        guard case .heard(let text) = await voice.listen(), isCurrent(step) else {
            // Nothing said: the buttons stay; the car gets its audio back.
            if isCurrent(step) {
                await announcePending()
                guard isCurrent(step) else { return }
                voice.speaker.endTurn()
                CarVoiceActivity.shared.setAgent(nil)
            }
            return
        }
        switch AgentVoiceService.blockedReply(to: text) {
        case .allow:
            answer { voice, turn in await voice.allow(turn) }
        case .deny:
            answer { voice, turn in await voice.deny(turn) }
        case .exit:
            endTurn()
        case .unrecognized:
            guard !reasked else {
                await announcePending()
                guard isCurrent(step) else { return }
                voice.speaker.endTurn()
                CarVoiceActivity.shared.setAgent(nil)
                return
            }
            await voice.speak(CarVoiceScript.blockedReask(canAllow: blocked.buttons == .denyAndAllow))
            guard isCurrent(step) else { return }
            await announcePending()
            guard isCurrent(step) else { return }
            await listenForAnswer(to: blocked, reasked: true)
        case .correction(let correction):
            transition(.correction(step, correction))
            activate(.confirm)
            await voice.speak(
                CarVoiceScript.correctionReadBack(identity: blocked.identity, text: correction))
            guard isCurrent(step) else { return }
            let confirmation = await voice.listenForConfirmation()
            guard isCurrent(step) else { return }
            switch confirmation {
            case .send: sendCorrection()
            case .cancel: await keepPendingAsDraft()
            }
        }
    }

    /// One answer per announced prompt; a changed prompt is announced
    /// afresh and can be answered again.
    private func answer(
        _ action: @escaping @MainActor (AgentVoiceService, AgentVoiceService.BlockedTurn) async
            -> AgentVoiceService.BlockedAnswer
    ) {
        guard voiceTemplate != nil,
            case .answer(let blocked)? = transition(.answer).first else { return }
        replaceTurn { coordinator in
            guard let step = coordinator.presentation.turn?.step else { return }
            coordinator.activate(.checking)
            let answer = await action(coordinator.voice, blocked)
            guard coordinator.isCurrent(step) else { return }
            await coordinator.settle(answer)
        }
    }

    private func sendCorrection() {
        guard voiceTemplate != nil,
            case .correct(let blocked, let text)? = transition(.sendCorrection).first else { return }
        replaceTurn { coordinator in
            guard let step = coordinator.presentation.turn?.step else { return }
            coordinator.activate(.checking)
            let answer = await coordinator.voice.denyAndInstruct(blocked, text: text)
            guard coordinator.isCurrent(step) else { return }
            await coordinator.settle(answer)
        }
    }

    /// Done acknowledges dispatch, never a queued, refused or uncertain answer.
    static func screen(for answer: AgentVoiceService.BlockedAnswer) -> VoiceState {
        answer.outcome == .sent ? .answered : .checking
    }

    private func settle(_ answer: AgentVoiceService.BlockedAnswer) async {
        activate(Self.screen(for: answer))
        guard let next = answer.next else {
            await finish(saying: answer.spoken)
            return
        }
        // Still acted until the changed prompt was read: `announce` clears it.
        await announce(next, saying: answer.spoken)
    }

    private func holdBlocked() {
        guard voiceTemplate != nil, transition(.hold).contains(.held) else { return }
        replaceTurn { coordinator in
            coordinator.activate(.answered)
            await coordinator.finish(saying: CarVoiceScript.held)
        }
    }

    // MARK: Talk to Waycar

    /// How long the briefing waits for unverified Hosts' snapshots.
    private static let briefingVerificationWait: Duration = .seconds(3)
    private static let briefingVerificationPoll: Duration = .milliseconds(250)

    private func presentBriefing() {
        let template = CPVoiceControlTemplate(voiceControlStates: [
            state(
                .briefing, ["Talk to Waycar", "Waycar"], symbol: "waveform",
                buttons: [button("Done", symbol: "checkmark") { $0.endTurn() }])
        ])
        present(template, for: nil, kind: .briefing)
        guard let step = presentation.turn?.step else { return }
        runTurn { [weak self] in
            guard let self, self.isCurrent(step), self.voiceTemplate === template else { return }
            self.voice.speaker.beginTurn()
            let deadline = ContinuousClock.now + Self.briefingVerificationWait
            while !self.unverifiedHosts().isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.briefingVerificationPoll)
                guard self.isCurrent(step) else { return }
            }
            let rows = CarPlayListModel(
                agents: self.console.agents,
                maximumItemCount: Int(CPListTemplate.maximumItemCount),
                now: Date()
            ).rows
            let briefing = CarVoiceScript.briefing(
                rows: rows, unverifiedHosts: self.unverifiedHosts())
            await self.finish(saying: briefing)
        }
    }

    private func unverifiedHosts() -> [CarVoiceScript.UnverifiedHost] {
        CarVoiceScript.unverifiedHosts(
            Array(console.catalog.values), statuses: console.hostStatuses,
            awaitingSnapshot: console.hostsAwaitingSnapshot)
    }

    // MARK: Turn plumbing

    private func present(
        _ template: CPVoiceControlTemplate, for id: ConsoleAgent.ID?, kind: CarPlayTurnMachine.Kind
    ) {
        cancelTurn()
        // The next turn takes the session over: no release in between.
        let outgoing = conversation
        conversation = nil
        outgoing?.end(releasingAudio: false)
        voice.speaker.stop()
        // Set first, so the outgoing template's disappearance is not
        // taken for the driver closing this one. Opening salvages unsent words.
        transition(.open(kind, id))
        templates = [:]
        if let token = presentation.turn?.template { templates[token] = template }
        CarVoiceActivity.shared.setAgent(id)
        if interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: false, completion: nil)
        }
        interfaceController.presentTemplate(template, animated: true) { _, error in
            if let error { Self.log.error("CarPlay voice template failed: \(error)") }
        }
    }

    @discardableResult
    private func transition(_ event: CarPlayTurnMachine.Event) -> [CarPlayTurnMachine.Effect] {
        let effects = presentation.handle(event)
        for case .draft(let id, let text) in effects { voice.keepAsDraft(text, for: id) }
        return effects
    }

    private func isCurrent(_ step: UInt64) -> Bool {
        !Task.isCancelled && transition(.checkpoint(step)).contains(.proceed)
    }

    /// Cancels the running step (a listen, a line) and runs `step` as the
    /// turn instead.
    private func replaceTurn(_ step: @escaping @MainActor (CarPlayTemplateCoordinator) async -> Void) {
        cancelTurn()
        transition(.replaceStep)
        guard let token = presentation.turn?.step else { return }
        voice.speaker.stop()
        runTurn { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            await step(self)
        }
    }

    private func runTurn(_ operation: @escaping @MainActor () async -> Void) {
        guard let token = presentation.turn?.step else { return }
        turns[token] = Task { await operation() }
    }

    private func cancelTurn() {
        for task in turns.values { task.cancel() }
        turns = [:]
    }

    private func activate(_ state: VoiceState) {
        voiceTemplate?.activateVoiceControlState(withIdentifier: state.rawValue)
    }

    /// Speaks the turn's last line, then closes it.
    private func finish(saying line: String) async {
        guard let step = presentation.turn?.step, isCurrent(step) else { return }
        transition(.finish(step))
        if !line.isEmpty { await voice.speak(line) }
        guard isCurrent(step) else { return }
        await announcePending()
        guard isCurrent(step) else { return }
        voice.speaker.endTurn()
        try? await Task.sleep(for: Self.minimumStateDwell)
        guard isCurrent(step) else { return }
        endTurn()
    }

    /// Says, one short line each, the Blocked pushes from other Agents that
    /// arrived while the car spoke or listened (`CarVoiceActivity`).
    private func announcePending() async {
        guard let step = presentation.turn?.step, isCurrent(step) else { return }
        for pending in CarVoiceActivity.shared.drainPending() {
            guard isCurrent(step) else { return }
            let title =
                model?.rows.first { $0.id == pending.target.agentID }?.title
                ?? pending.alert.title
            await voice.speak(
                CarVoiceScript.blockedElsewhere(identity: CarVoiceScript.spokenIdentity(title)))
        }
    }

    private func endTurn(dismiss: Bool = true) {
        cancelTurn()
        // Unsent text to the draft; `voice.endTurn` below gives the audio back.
        let outgoing = conversation
        conversation = nil
        outgoing?.end(releasingAudio: false)
        transition(.close)
        templates = [:]
        CarVoiceActivity.shared.setAgent(nil)
        voice.endTurn()
        if dismiss, interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: true, completion: nil)
        }
    }

    /// The driver closed the voice template with CarPlay's own close
    /// button: stop talking and give the audio back.
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        guard let voiceTemplate, aTemplate === voiceTemplate,
            let token = presentation.turn?.template else { return }
        transition(.disappeared(token))
        endTurn(dismiss: false)
    }

    private func state(
        _ state: VoiceState, _ titles: [String], symbol: String? = nil, typingDots: Bool = false,
        buttons: [CPButton] = []
    ) -> CPVoiceControlState {
        let canvas = CGSize(width: 150, height: 150)
        let image =
            typingDots
            ? typingDotsImage(canvas: canvas)
            : symbol.flatMap { symbolImage($0, tint: .white, pointSize: 96, canvas: canvas) }
        let voiceState = CPVoiceControlState(
            identifier: state.rawValue, titleVariants: titles, image: image, repeats: typingDots)
        if #available(iOS 26.4, *) {
            voiceState.actionButtons = Array(
                buttons.prefix(CPVoiceControlState.maximumActionButtonCount))
        }
        return voiceState
    }

    private func button(
        _ title: String, symbol: String,
        action: @escaping @MainActor @Sendable (CarPlayTemplateCoordinator) -> Void
    ) -> CPButton {
        let image = UIImage(systemName: symbol) ?? UIImage()
        // CarPlay calls a voice template's button handler on its XPC
        // queue, not the main thread (seen on iOS 26.5).
        let button = CPButton(image: image) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
        }
        button.title = title
        return button
    }
}
