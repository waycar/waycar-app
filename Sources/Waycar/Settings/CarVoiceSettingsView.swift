import AVFoundation
import SwiftUI

/// Settings › CarPlay Voice: the voice Waycar speaks with in the car. The
/// list holds only voices installed for the car's language (novelty and
/// Personal voices left out), best first; Automatic follows the best one,
/// so a voice downloaded later is used without coming back here. Natural
/// Voice (Beta) adds on-device neural voice models (`NaturalVoiceCatalog`),
/// to download, compare, use and delete; the system voice stands in
/// whenever the chosen one can't speak.
struct CarVoiceSettingsView: View {
    /// Empty means Automatic.
    @AppStorage(CarVoiceSelection.voiceKey) private var storedVoice = ""
    @State private var voices = CarVoice.installed()
    @AppStorage(NaturalVoiceSettings.enabledKey) private var naturalVoiceEnabled = false
    @AppStorage(NaturalVoiceSettings.activeModelKey) private var activeModel = NaturalVoiceModelID.kokoro
    @State private var confirmsDelete: NaturalVoiceModelID?
    @AppStorage(CarVoiceSpeed.key) private var speed = CarVoiceSpeed.standard
    @State private var sample = CarVoiceSample()
    private let models = NaturalVoiceModelStore.shared

    var body: some View {
        Form {
            if !naturalVoiceEnabled {
                Section {
                    Picker("Apple Voice", selection: $storedVoice) {
                        Text("Automatic (best)").tag("")
                        ForEach(voices) { voice in
                            Text(Self.title(of: voice)).tag(voice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("settings.carPlayVoice.applePicker")
                } footer: {
                    Text(
                        "For a more natural voice, download an Enhanced or Premium English voice in "
                            + "iOS Settings › Accessibility › Read & Speak › Voices. Siri voices "
                            + "aren't available to apps.")
                }
            }
            speedSection
            naturalVoiceSection
            ForEach(NaturalVoiceCatalog.models) { info in
                modelSection(info)
            }
        }
        .navigationTitle("CarPlay Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { HelpLink(.carplay) } }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
        ) { _ in
            voices = CarVoice.installed()
        }
        .confirmationDialog(
            confirmsDelete.map { "Delete \(NaturalVoiceCatalog.info($0).title)?" } ?? "",
            isPresented: Binding(get: { confirmsDelete != nil }, set: { if !$0 { confirmsDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmsDelete
        ) { model in
            Button("Delete \(NaturalVoiceCatalog.info(model).title)", role: .destructive) {
                models.delete(model)
            }
        } message: { model in
            Text(deleteMessage(model))
        }
        .task { models.refresh() }
        .onDisappear { sample.stop() }
    }

    /// Applies to the Apple and the Natural voice alike.
    private var speedSection: some View {
        Section {
            Picker("Speaking Speed", selection: speedSelection) {
                ForEach(CarVoiceSpeed.steps, id: \.self) { step in
                    Text(CarVoiceSpeed.label(step)).tag(step)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.carPlayVoice.speed")
            // CarVoiceActivity isn't observable: re-read it each second so
            // the button greys out while a CarPlay voice turn is on.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Button(sample.isPlaying ? "Stop Sample" : "Play Sample") { sample.toggle() }
                    .disabled(!sample.isPlaying && !CarVoiceSample.canPlay)
                    .accessibilityIdentifier("settings.carPlayVoice.sample")
            }
        } footer: {
            Text("How fast CarPlay speaks, with either voice.")
        }
    }

    private var speedSelection: Binding<Double> {
        Binding(get: { CarVoiceSpeed.snapped(speed) }, set: { speed = $0 })
    }

    private var naturalVoiceSection: some View {
        Section {
            Toggle("Natural Voice", isOn: $naturalVoiceEnabled)
                .onChange(of: naturalVoiceEnabled) { _, enabled in
                    // Off frees the model now; on loads it when CarPlay next speaks.
                    if !enabled { NaturalVoice.unload() }
                }
                .accessibilityIdentifier("settings.naturalVoice.toggle")
        } header: {
            Text("Natural Voice (Beta)")
        } footer: {
            Text(
                "A neural voice that runs on this iPhone. Download one or more below, best "
                    + "first, and pick the one the car uses. Beta: whenever it can't speak, "
                    + "Waycar uses the Apple voice.")
        }
    }

    /// One model: what it is, then what can be done with it.
    private func modelSection(_ info: NaturalVoiceModelInfo) -> some View {
        Section {
            modelSummary(info)
            modelActions(info)
        } footer: {
            if info.id == NaturalVoiceCatalog.models.last?.id {
                Text(storageFooter)
            }
        }
    }

    private func modelSummary(_ info: NaturalVoiceModelInfo) -> some View {
        let isActive = activeModel == info.id && models.isInstalled(info.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.title).font(.headline)
                Spacer(minLength: 8)
                if isActive {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text("Choose it if \(info.chooseIf)")
                .font(.subheadline)
            Text(info.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("\(stateTitle(info.id, isActive: isActive)) · \(sizeTitle(info.id)) · \(info.license)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("settings.naturalVoice.\(info.id.rawValue)")
    }

    @ViewBuilder private func modelActions(_ info: NaturalVoiceModelInfo) -> some View {
        let model = info.id
        let identifier = "settings.naturalVoice.\(model.rawValue)"
        switch models.phase(model) {
        case .checking:
            LabeledContent("Voice Model") { ProgressView() }
                .accessibilityLabel("Checking \(info.title)")
        case .absent:
            let size = Self.size(models.downloadBytes[model] ?? info.downloadBytes, about: true)
            Button {
                models.download(model)
            } label: {
                LabeledContent("Download", value: size)
            }
            .disabled(models.busyModel != nil)
            .accessibilityLabel("Download \(info.title)")
            .accessibilityValue(size)
            .accessibilityIdentifier("\(identifier).download")
        case .downloading(let fraction):
            VStack(alignment: .leading) {
                LabeledContent(
                    "Downloading",
                    value: fraction.formatted(.percent.precision(.fractionLength(0))))
                ProgressView(value: min(max(fraction, 0), 1))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading \(info.title)")
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
            .accessibilityIdentifier("\(identifier).progress")
            Button("Cancel Download", role: .cancel) { models.cancel() }
                .accessibilityLabel("Cancel \(info.title) Download")
                .accessibilityIdentifier("\(identifier).cancel")
        case .preparing:
            LabeledContent("Preparing Voice") { ProgressView() }
                .accessibilityLabel("Preparing \(info.title)")
            Button("Cancel Download", role: .cancel) { models.cancel() }
                .accessibilityLabel("Cancel \(info.title) Download")
                .accessibilityIdentifier("\(identifier).cancel")
        case .installed:
            if activeModel == model {
                NaturalVoicePicker(model: model, voices: models.voices[model] ?? [])
                    .id(model)
                    .accessibilityLabel("\(info.title) Voice")
                    .accessibilityIdentifier("\(identifier).voice")
            } else {
                Button("Use \(info.title)") { activeModel = model }
                    .disabled(models.busyModel != nil)
                    .accessibilityIdentifier("\(identifier).use")
            }
            let freed = Self.size(models.freedBytes[model] ?? 0, about: false)
            Button(role: .destructive) {
                confirmsDelete = model
            } label: {
                LabeledContent("Delete", value: freed)
            }
            .disabled(models.busyModel != nil)
            .accessibilityLabel("Delete \(info.title)")
            .accessibilityValue("Frees \(freed)")
            .accessibilityIdentifier("\(identifier).delete")
        case .incomplete(let bytes):
            let size = Self.size(bytes, about: false)
            Text("The download didn't finish. Resume it, or delete what it downloaded.")
                .foregroundStyle(.secondary)
            Button("Resume Download") { models.download(model) }
                .disabled(models.busyModel != nil)
                .accessibilityLabel("Resume \(info.title) Download")
                .accessibilityIdentifier("\(identifier).resume")
            Button(role: .destructive) {
                models.delete(model)
            } label: {
                LabeledContent("Delete Downloaded Files", value: size)
            }
            .disabled(models.busyModel != nil)
            .accessibilityLabel("Delete \(info.title) Downloaded Files")
            .accessibilityValue(size)
            .accessibilityIdentifier("\(identifier).delete")
        }
    }

    private func stateTitle(_ model: NaturalVoiceModelID, isActive: Bool) -> String {
        switch models.phase(model) {
        case .checking: "Checking"
        case .absent: "Not Downloaded"
        case .downloading, .preparing: "Downloading"
        case .installed: isActive ? "In Use" : "Downloaded"
        case .incomplete: "Incomplete"
        }
    }

    /// "About 230 MB" before the download, "230 MB" on disk after.
    private func sizeTitle(_ model: NaturalVoiceModelID) -> String {
        if case .installed(let bytes) = models.phase(model) { return Self.size(bytes, about: false) }
        return Self.size(models.downloadBytes[model] ?? NaturalVoiceCatalog.info(model).downloadBytes, about: true)
    }

    private var storageFooter: String {
        let privacy = "Runs on your iPhone; nothing is sent after download."
        guard models.totalBytes > 0 else { return privacy }
        return "Downloaded voices use \(Self.size(models.totalBytes, about: false)). \(privacy)"
    }

    /// Says what the car speaks with once `model` is gone.
    private func deleteMessage(_ model: NaturalVoiceModelID) -> String {
        let freed = Self.size(models.freedBytes[model] ?? 0, about: false)
        guard activeModel == model else { return "Frees \(freed)." }
        if let next = NaturalVoiceCatalog.models.first(where: { $0.id != model && models.isInstalled($0.id) }) {
            return "Frees \(freed). The car switches to \(next.title)."
        }
        return "Frees \(freed). Natural Voice turns off and the car speaks with the voice above."
    }

    private static func size(_ bytes: Int64, about: Bool) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return about ? "About \(size)" : size
    }

    /// "Ava (Premium, en-US)"
    static func title(of voice: SpeechVoiceCandidate) -> String {
        "\(voice.name) (\(qualityTitle(voice.quality)), \(voice.language))"
    }

    static func qualityTitle(_ quality: SpeechVoiceCandidate.Quality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        case .standard: "Compact"
        }
    }
}

/// The active model's voice, stored under that model's key. Lists only
/// voices on disk, so the car never needs the network to switch.
private struct NaturalVoicePicker: View {
    let model: NaturalVoiceModelID
    let voices: [NaturalVoiceOption]
    @AppStorage private var stored: String

    init(model: NaturalVoiceModelID, voices: [NaturalVoiceOption]) {
        self.model = model
        self.voices = voices
        _stored = AppStorage(
            wrappedValue: NaturalVoiceCatalog.info(model).defaultVoice,
            NaturalVoiceSettings.voiceKey(for: model))
    }

    var body: some View {
        Picker("Voice", selection: selection) {
            ForEach(voices) { voice in
                Text(voice.accent.isEmpty ? voice.name : "\(voice.name) (\(voice.accent))").tag(voice.id)
            }
        }
        .pickerStyle(.menu)
        .disabled(voices.count < 2)
    }

    /// A stored voice no longer offered reads as the model's default, as in
    /// `NaturalVoiceSettings.voice(for:)`.
    private var selection: Binding<String> {
        Binding(
            get: {
                voices.contains { $0.id == stored } ? stored : NaturalVoiceCatalog.info(model).defaultVoice
            },
            set: { stored = $0 })
    }
}
