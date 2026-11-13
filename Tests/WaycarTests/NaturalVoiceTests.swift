import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("CarPlay Natural voice")
struct NaturalVoiceTests {
    /// Each sentence synthesizes while the one before it plays.
    @Test func linesSplitIntoTrimmedSentences() {
        #expect(
            NeuralSpeechEngine.sentences(in: "Tests pass.  Pushing now? Done!\n")
                == ["Tests pass.", "Pushing now?", "Done!"])
        #expect(NeuralSpeechEngine.sentences(in: "Bumped to v1.2 today.") == ["Bumped to v1.2 today."])
        #expect(NeuralSpeechEngine.sentences(in: "  \n ").isEmpty)
    }

    /// The catalog keeps an internal best-first order (not shown in Settings).
    @Test func catalogIsRankedBestFirstWithUniqueRanks() {
        let models = NaturalVoiceCatalog.models
        #expect(models.map(\.id) == [.kokoro, .pocket, .paradee])
        #expect(models.map(\.rank) == Array(1...models.count))
        #expect(Set(models.map(\.rank)).count == models.count)
        #expect(Set(models.map(\.id)) == Set(NaturalVoiceModelID.allCases))
        for model in NaturalVoiceModelID.allCases {
            let info = NaturalVoiceCatalog.info(model)
            #expect(info.id == model)
            #expect(info.voices.contains { $0.id == info.defaultVoice })
            #expect(Set(info.voices.map(\.id)).count == info.voices.count)
        }
    }

    /// Kyutai licenses `cosette` and `jean` for non-commercial use only.
    @Test func pocketLeavesOutNonCommercialVoices() {
        let voices = NaturalVoiceCatalog.info(.pocket).voices.map(\.id)
        #expect(!voices.contains("cosette"))
        #expect(!voices.contains("jean"))
        let required = NaturalVoiceModel.requiredFiles(.pocket)
        #expect(!required.contains { $0.contains("cosette") || $0.contains("jean") })
    }

    /// The download and the check skip every voice the catalog doesn't
    /// offer, and the bundles Waycar doesn't load.
    @Test func pocketDownloadKeepsOnlyCataloguedVoicesAndNeuralEngineBundles() {
        let pocket = NaturalVoiceModel.pocketFiles
        #expect(pocket.keeps("constants_bin/alba.safetensors"))
        #expect(pocket.keeps("constants_bin/tokenizer.model"))
        #expect(pocket.keeps("constants_bin/bos_before_voice.bin"))
        #expect(pocket.keeps("flowlm_step_ane.mlmodelc/weights/weight.bin"))
        #expect(!pocket.keeps("constants_bin/cosette.safetensors"))
        #expect(!pocket.keeps("constants_bin/jean.safetensors"))
        #expect(!pocket.keeps("constants_bin/estelle.safetensors"))
        #expect(!pocket.keeps("flowlm_step.mlmodelc/weights/weight.bin"))
        #expect(!pocket.keeps("cond_prefill_ane.mlpackage/Manifest.json"))
        #expect(!pocket.keeps("constants/alba.npz"))

        #expect(pocket.skips(remote: "v2.1/english/constants_bin/jean.safetensors"))
        #expect(!pocket.skips(remote: "v2.1/english/constants_bin"))
        #expect(!pocket.skips(remote: "v2.1/english"))
        #expect(pocket.skips(remote: "v2.1/french_24l/constants_bin/alba.safetensors"))
    }

    /// A Pocket install never leaves a voice the catalog doesn't offer on
    /// disk, finished or partial.
    @Test func uncataloguedPocketVoicesAreRemoved() throws {
        let (root, _, cleanup) = try Self.sandbox()
        defer { cleanup() }
        let constants = root.appending(path: "Models/pocket-tts/v2.1/english/constants_bin")
        try FileManager.default.createDirectory(at: constants, withIntermediateDirectories: true)
        let names = [
            "alba.safetensors", "marius.safetensors", "bos_before_voice.bin", "cosette.safetensors",
            "jean.safetensors", "jean.safetensors.partial", "estelle.safetensors",
        ]
        for name in names {
            try Data(repeating: 1, count: 16).write(to: constants.appending(path: name))
        }

        try NaturalVoiceModel.removeUncataloguedVoices(in: root)
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: constants.path))
        #expect(left == ["alba.safetensors", "marius.safetensors", "bos_before_voice.bin"])
    }

    /// The shared front end is checked file by file at the repository root,
    /// lexicon included.
    @Test func sharedTextCheckCoversTheG2PModelAndTheLexicon() {
        let shared = NaturalVoiceModel.sharedText
        #expect(shared.remote.isEmpty)
        #expect(shared.revision == NaturalVoiceModel.kokoroBaseRevision)
        #expect(shared.keeps("us_lexicon_cache.json"))
        #expect(shared.keeps("g2p_vocab.json"))
        #expect(shared.keeps("G2PEncoder.mlmodelc/weights/weight.bin"))
        #expect(!shared.keeps("voices/af_heart.json"))
        #expect(!shared.keeps("ANE/KokoroAlbert.mlmodelc/model.mil"))
    }

    /// Listing paths come from the server and name files to delete: only
    /// paths strictly inside the folder are accepted.
    @Test func listedPathsMustStayInsideTheirFolder() {
        #expect(NaturalVoiceModel.relativePath("v2.1/english/a/b.bin", under: "v2.1/english") == "a/b.bin")
        #expect(NaturalVoiceModel.relativePath("g2p_vocab.json", under: "") == "g2p_vocab.json")
        #expect(NaturalVoiceModel.relativePath("v2.1/englishx/a.bin", under: "v2.1/english") == nil)
        #expect(NaturalVoiceModel.relativePath("v2.1/english/../x.bin", under: "v2.1/english") == nil)
        #expect(NaturalVoiceModel.relativePath("v2.1/english/./x.bin", under: "v2.1/english") == nil)
        #expect(NaturalVoiceModel.relativePath("v2.1/english/a//b", under: "v2.1/english") == nil)
        #expect(NaturalVoiceModel.relativePath("v2.1/english/", under: "v2.1/english") == nil)
        #expect(NaturalVoiceModel.relativePath("../etc", under: "") == nil)
        #expect(NaturalVoiceModel.relativePath("", under: "") == nil)
    }

    /// Kokoro keeps reading the key from before the catalog, so an existing
    /// choice survives; every other model has its own key and default.
    @Test func eachModelHasItsOwnVoiceAndKokoroKeepsTheOldChoice() throws {
        let suite = "NaturalVoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(NaturalVoiceSettings.activeModel(defaults: defaults) == .kokoro)
        #expect(NaturalVoiceSettings.voice(for: .kokoro, defaults: defaults) == "af_heart")
        #expect(NaturalVoiceSettings.voice(for: .pocket, defaults: defaults) == "alba")
        #expect(NaturalVoiceSettings.voice(for: .paradee, defaults: defaults) == "af_heart")

        defaults.set("bm_george", forKey: "carplay-natural-voice-name")
        #expect(NaturalVoiceSettings.voice(for: .kokoro, defaults: defaults) == "bm_george")
        #expect(NaturalVoiceSettings.voice(for: .pocket, defaults: defaults) == "alba")

        defaults.set("marius", forKey: "carplay-natural-voice-name.pocket")
        #expect(NaturalVoiceSettings.voice(for: .pocket, defaults: defaults) == "marius")
        #expect(NaturalVoiceSettings.voice(for: .kokoro, defaults: defaults) == "bm_george")

        defaults.set("cosette", forKey: NaturalVoiceSettings.voiceKey(for: .pocket))
        #expect(NaturalVoiceSettings.voice(for: .pocket, defaults: defaults) == "alba")
        defaults.set("af_nonexistent", forKey: NaturalVoiceSettings.voiceKey)
        #expect(NaturalVoiceSettings.voice(for: .kokoro, defaults: defaults) == "af_heart")

        defaults.set("paradee", forKey: NaturalVoiceSettings.activeModelKey)
        #expect(NaturalVoiceSettings.activeModel(defaults: defaults) == .paradee)
        defaults.set("retired", forKey: NaturalVoiceSettings.activeModelKey)
        #expect(NaturalVoiceSettings.activeModel(defaults: defaults) == .kokoro)
    }

    @Test func naturalVoiceIsOffByDefault() throws {
        let suite = "NaturalVoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!NaturalVoiceSettings.isEnabled(defaults: defaults))
    }

    /// FluidAudio looks custom entries up by exact spelling, then lower
    /// case, so lower-case keys cover every capitalization.
    @Test func pronunciationsCoverTheCarsJargonInLowerCase() {
        let words = ["herdr", "codex", "npm", "api", "cli", "github", "omp"]
        #expect(Set(NaturalVoiceModel.pronunciations.keys) == Set(words))
        #expect(NaturalVoiceModel.pronunciations.keys.allSatisfy { $0 == $0.lowercased() })
    }

    /// The car loads offline: every file FluidAudio would fetch outside its
    /// offline switch must be part of the installed check.
    @Test func installedCheckCoversTheFilesLoadedOutsideTheOfflineSwitch() {
        let kokoro = NaturalVoiceModel.requiredFiles(.kokoro)
        #expect(kokoro.contains("Models/kokoro/us_lexicon_cache.json"))
        #expect(
            kokoro.contains(
                "Models/kokoro-82m-coreml/ANE-v3/\(NaturalVoiceModel.kokoroRelease)/en/manifest.json"))

        let pocket = NaturalVoiceModel.requiredFiles(.pocket)
        for voice in NaturalVoiceCatalog.info(.pocket).voices {
            #expect(pocket.contains("Models/pocket-tts/v2.1/english/constants_bin/\(voice.id).safetensors"))
        }
        #expect(pocket.contains("Models/pocket-tts/v2.1/english/constants_bin/bos_before_voice.bin"))

        let paradee = NaturalVoiceModel.requiredFiles(.paradee)
        #expect(paradee.contains("Models/kokoro/us_lexicon_cache.json"))
        #expect(paradee.contains("Models/paradee-8m-coreml/int8/ParadeeText.mlmodelc"))
    }

    /// Paradee reads Kokoro's English text front end: deleting either one
    /// keeps it while the other is installed, and the last one takes it.
    @Test func deleteKeepsSharedFilesAnotherInstalledModelNeeds() throws {
        let (root, defaults, cleanup) = try Self.sandbox()
        defer { cleanup() }
        try Self.fakeInstall(.kokoro, in: root)
        try Self.fakeInstall(.paradee, in: root)
        let shared = root.appending(path: NaturalVoiceModel.sharedTextFolder)

        try NaturalVoiceModel.delete(.kokoro, in: root, defaults: defaults)
        #expect(!NaturalVoiceModel.isInstalled(.kokoro, in: root))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Models/kokoro-82m-coreml").path))
        #expect(FileManager.default.fileExists(atPath: shared.path))
        #expect(NaturalVoiceModel.isInstalled(.paradee, in: root))

        try NaturalVoiceModel.delete(.paradee, in: root, defaults: defaults)
        #expect(!NaturalVoiceModel.isInstalled(.paradee, in: root))
        #expect(!FileManager.default.fileExists(atPath: shared.path))
        #expect(NaturalVoiceModel.totalDiskSize(in: root) == 0)
    }

    /// What deleting reports it frees leaves out what another model reads.
    @Test func freedSizeLeavesOutSharedFilesAnotherInstalledModelNeeds() throws {
        let (root, _, cleanup) = try Self.sandbox()
        defer { cleanup() }
        try Self.fakeInstall(.paradee, in: root)
        let alone = NaturalVoiceModel.freedSize(.paradee, in: root)
        try Self.fakeInstall(.kokoro, in: root)

        #expect(NaturalVoiceModel.freedSize(.paradee, in: root) < alone)
        #expect(NaturalVoiceModel.diskSize(.paradee, in: root) > NaturalVoiceModel.freedSize(.paradee, in: root))
    }

    /// The car moves to the best other installed model, else Natural Voice
    /// turns off.
    @Test func deletingTheActiveModelReassignsActive() throws {
        let (root, defaults, cleanup) = try Self.sandbox()
        defer { cleanup() }
        try Self.fakeInstall(.paradee, in: root)
        try Self.fakeInstall(.pocket, in: root)
        try Self.fakeInstall(.kokoro, in: root)
        defaults.set(true, forKey: NaturalVoiceSettings.enabledKey)

        try NaturalVoiceModel.delete(.kokoro, in: root, defaults: defaults)
        #expect(NaturalVoiceSettings.activeModel(defaults: defaults) == .pocket)
        #expect(NaturalVoiceSettings.isEnabled(defaults: defaults))

        try NaturalVoiceModel.delete(.paradee, in: root, defaults: defaults)
        #expect(NaturalVoiceSettings.activeModel(defaults: defaults) == .pocket)

        try NaturalVoiceModel.delete(.pocket, in: root, defaults: defaults)
        #expect(!NaturalVoiceSettings.isEnabled(defaults: defaults))
    }

    /// Cancelling a download deletes a model that was never installed; that
    /// leaves the user's choices alone.
    @Test func deletingAModelThatWasNotInstalledKeepsTheSettings() throws {
        let (root, defaults, cleanup) = try Self.sandbox()
        defer { cleanup() }
        defaults.set(true, forKey: NaturalVoiceSettings.enabledKey)
        let partial = root.appending(path: "Models/kokoro-82m-coreml/partial.bin")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: partial)

        try NaturalVoiceModel.delete(.kokoro, in: root, defaults: defaults)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(NaturalVoiceSettings.isEnabled(defaults: defaults))
        #expect(NaturalVoiceSettings.activeModel(defaults: defaults) == .kokoro)
    }

    // MARK: - Fixtures

    /// A temporary model root and defaults suite.
    private static func sandbox() throws -> (URL, UserDefaults, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "NaturalVoiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "NaturalVoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (
            root, defaults,
            {
                try? FileManager.default.removeItem(at: root)
                defaults.removePersistentDomain(forName: suite)
            }
        )
    }

    /// Writes every file the installed check reads, plus the marker. A
    /// required path that holds other required paths (Pocket's
    /// `constants_bin`) is a folder, as on disk.
    private static func fakeInstall(_ model: NaturalVoiceModelID, in root: URL) throws {
        let paths = NaturalVoiceModel.requiredFiles(model)
        for path in paths {
            let url = root.appending(path: path)
            if paths.contains(where: { $0.hasPrefix(path + "/") }) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: url)
        }
        try NaturalVoiceModel.markInstalled(model, in: root)
        #expect(NaturalVoiceModel.isInstalled(model, in: root))
    }
}
