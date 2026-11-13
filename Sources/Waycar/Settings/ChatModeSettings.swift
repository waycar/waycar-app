import Foundation
import Observation

/// Settings › Chat Mode (`CONTEXT.md`): the Chat Prompt override, each
/// harness's model, Quick thinking, and the New Chat defaults.
/// An absent prompt means the built-in `ChatModePrompt.defaultText`, so a
/// later build's improved default reaches everyone who never edited it; an
/// absent model means the harness's own default. Synced across devices
/// through iCloud Sync (ADR 0019).
@MainActor
@Observable
final class ChatModeSettings {
    nonisolated static let promptKey = "chat-mode-prompt"
    /// Bool; absent means on.
    nonisolated static let quickThinkingKey = "chat-mode-quick-thinking"
    /// JSON `ChatDestination`; absent means Last Used.
    nonisolated static let newChatDestinationKey = "chat-mode-new-chat-destination"
    /// `SupportedAgentKind` raw value; absent means Last Used.
    nonisolated static let newChatKindKey = "chat-mode-new-chat-kind"

    /// The key holding `kind`'s model; absent means the harness's default.
    nonisolated static func modelKey(for kind: SupportedAgentKind) -> String {
        "chat-mode-model.\(kind.rawValue)"
    }

    /// Every key iCloud Sync carries for these settings.
    nonisolated static var syncedKeys: [String] {
        [promptKey] + chatKinds.map(modelKey(for:))
            + [quickThinkingKey, newChatDestinationKey, newChatKindKey]
    }

    /// The user's own prompt; nil means the default.
    private(set) var customPrompt: String?
    /// Each Chat Mode kind's model, normalized; a missing kind starts with
    /// the harness's default.
    private(set) var models: [SupportedAgentKind: String]
    /// Quick thinking: Chat Mode launches ask for less reasoning.
    private(set) var quickThinking: Bool
    /// New Chat's Host + Workspace; nil means Last Used.
    private(set) var newChatDestination: ChatDestination?
    /// New Chat's Agent kind; nil means Last Used.
    private(set) var newChatKind: SupportedAgentKind?

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customPrompt = Self.storedPrompt(in: defaults)
        models = Self.storedModels(in: defaults)
        quickThinking = Self.storedQuickThinking(in: defaults)
        newChatDestination = Self.storedNewChatDestination(in: defaults)
        newChatKind = Self.storedNewChatKind(in: defaults)
    }

    var promptText: String { customPrompt ?? ChatModePrompt.defaultText }

    var isDefault: Bool { customPrompt == nil }

    /// Stores `text` as the override. Blank text, or text equal to the
    /// default, clears it instead.
    func setPrompt(_ text: String) {
        let isBlank = text.allSatisfy(\.isWhitespace)
        let value: String? = isBlank || text == ChatModePrompt.defaultText ? nil : text
        guard value != customPrompt else { return }
        customPrompt = value
        if let value {
            defaults.set(value, forKey: Self.promptKey)
        } else {
            defaults.removeObject(forKey: Self.promptKey)
        }
    }

    func resetToDefault() {
        customPrompt = nil
        defaults.removeObject(forKey: Self.promptKey)
    }

    func model(for kind: SupportedAgentKind) -> String? { models[kind] }

    /// Stores `text`, normalized (`ChatModeLaunchOptions.normalizedModel`),
    /// as `kind`'s model. Blank text removes it, back to the harness's
    /// default. Kinds without Chat Mode keep none.
    func setModel(_ text: String, for kind: SupportedAgentKind) {
        guard kind.supportsChatMode else { return }
        let value = ChatModeLaunchOptions.normalizedModel(text)
        guard value != models[kind] else { return }
        models[kind] = value
        if let value {
            defaults.set(value, forKey: Self.modelKey(for: kind))
        } else {
            defaults.removeObject(forKey: Self.modelKey(for: kind))
        }
    }

    /// On, the default, removes the key; off stores false.
    func setQuickThinking(_ on: Bool) {
        guard on != quickThinking else { return }
        quickThinking = on
        if on {
            defaults.removeObject(forKey: Self.quickThinkingKey)
        } else {
            defaults.set(false, forKey: Self.quickThinkingKey)
        }
    }

    /// Nil, Last Used, removes the key.
    func setNewChatDestination(_ destination: ChatDestination?) {
        guard destination != newChatDestination else { return }
        newChatDestination = destination
        if let data = destination?.encoded {
            defaults.set(data, forKey: Self.newChatDestinationKey)
        } else {
            defaults.removeObject(forKey: Self.newChatDestinationKey)
        }
    }

    /// Nil, Last Used, removes the key. Kinds without Chat Mode are ignored.
    func setNewChatKind(_ kind: SupportedAgentKind?) {
        guard kind?.supportsChatMode ?? true, kind != newChatKind else { return }
        newChatKind = kind
        if let kind {
            defaults.set(kind.rawValue, forKey: Self.newChatKindKey)
        } else {
            defaults.removeObject(forKey: Self.newChatKindKey)
        }
    }

    /// Re-reads every setting after iCloud Sync changed one (ADR 0019).
    /// Assigning only on a difference keeps the editors from re-rendering.
    func reload() {
        let stored = Self.storedPrompt(in: defaults)
        if stored != customPrompt { customPrompt = stored }
        let storedModels = Self.storedModels(in: defaults)
        if storedModels != models { models = storedModels }
        let storedQuickThinking = Self.storedQuickThinking(in: defaults)
        if storedQuickThinking != quickThinking { quickThinking = storedQuickThinking }
        let storedDestination = Self.storedNewChatDestination(in: defaults)
        if storedDestination != newChatDestination { newChatDestination = storedDestination }
        let storedKind = Self.storedNewChatKind(in: defaults)
        if storedKind != newChatKind { newChatKind = storedKind }
    }

    /// The prompt a launch sends, normalized for herdr. Callable off the
    /// main actor, straight from the stored value.
    nonisolated static func effectivePrompt(defaults: UserDefaults = .standard) -> String {
        ChatModePrompt.launchText(from: storedPrompt(in: defaults))
    }

    /// What a Chat Mode launch of `kind` asks for: the effective prompt,
    /// `kind`'s model and Quick thinking. Callable off the main actor,
    /// straight from the stored values.
    nonisolated static func launchOptions(
        for kind: SupportedAgentKind, defaults: UserDefaults = .standard
    ) -> ChatModeLaunchOptions {
        ChatModeLaunchOptions(
            prompt: effectivePrompt(defaults: defaults),
            model: storedModel(for: kind, in: defaults),
            quickThinking: storedQuickThinking(in: defaults))
    }

    private nonisolated static var chatKinds: [SupportedAgentKind] {
        SupportedAgentKind.allCases.filter(\.supportsChatMode)
    }

    private nonisolated static func storedPrompt(in defaults: UserDefaults) -> String? {
        guard let stored = defaults.string(forKey: promptKey),
            !stored.allSatisfy(\.isWhitespace)
        else { return nil }
        return stored
    }

    private nonisolated static func storedModel(
        for kind: SupportedAgentKind, in defaults: UserDefaults
    ) -> String? {
        guard kind.supportsChatMode else { return nil }
        return ChatModeLaunchOptions.normalizedModel(defaults.string(forKey: modelKey(for: kind)))
    }

    private nonisolated static func storedModels(in defaults: UserDefaults) -> [SupportedAgentKind: String] {
        var models: [SupportedAgentKind: String] = [:]
        for kind in chatKinds {
            models[kind] = storedModel(for: kind, in: defaults)
        }
        return models
    }

    private nonisolated static func storedQuickThinking(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: quickThinkingKey) as? Bool ?? true
    }

    nonisolated static func storedNewChatDestination(in defaults: UserDefaults) -> ChatDestination? {
        ChatDestination.decoded(from: defaults.data(forKey: newChatDestinationKey))
    }

    nonisolated static func storedNewChatKind(in defaults: UserDefaults) -> SupportedAgentKind? {
        defaults.string(forKey: newChatKindKey)
            .flatMap(SupportedAgentKind.init(rawValue:))
            .flatMap { $0.supportsChatMode ? $0 : nil }
    }
}
