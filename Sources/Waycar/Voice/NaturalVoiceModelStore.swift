import CryptoKit
import FluidAudio
import Foundation
import Observation
import OSLog

/// Settings › CarPlay Voice › Natural Voice (Beta): the stored choices.
enum NaturalVoiceSettings {
    /// Off unless the user turned it on.
    static let enabledKey = "carplay-natural-voice"
    /// The catalog model the car speaks with. Absent means Kokoro, the only
    /// model before the catalog, so an existing install keeps speaking.
    static let activeModelKey = "carplay-natural-voice-model"
    /// Kokoro's voice. Kokoro keeps the key from before the catalog, so an
    /// existing choice stays; the other models append `.<id>`.
    static let voiceKey = "carplay-natural-voice-name"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func activeModel(defaults: UserDefaults = .standard) -> NaturalVoiceModelID {
        defaults.string(forKey: activeModelKey).flatMap(NaturalVoiceModelID.init(rawValue:)) ?? .kokoro
    }

    static func voiceKey(for model: NaturalVoiceModelID) -> String {
        model == .kokoro ? voiceKey : "\(voiceKey).\(model.rawValue)"
    }

    /// The model's stored voice while the catalog still offers it, else
    /// its default.
    static func voice(for model: NaturalVoiceModelID, defaults: UserDefaults = .standard) -> String {
        let info = NaturalVoiceCatalog.info(model)
        let stored = defaults.string(forKey: voiceKey(for: model))
        return info.voices.first { $0.id == stored }?.id ?? info.defaultVoice
    }
}

enum NaturalVoiceModelError: LocalizedError {
    /// FluidAudio no longer keeps its files where Waycar protects and deletes them.
    case unexpectedLocation(String)
    /// The download finished without a file the car loads offline.
    case missingFile(String)
    /// A downloaded file doesn't match the pinned release; it was removed.
    case corruptFile(String)
    /// The Hub didn't list the pinned release's files to check them against.
    case unverifiable(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedLocation(let path): "FluidAudio's model folder moved to \(path)."
        case .missingFile(let name): "The voice model download is missing \(name)."
        case .corruptFile(let name): "The voice model file \(name) didn't match its release."
        case .unverifiable(let repository): "Couldn't check the \(repository) download."
        }
    }
}

/// The Natural voice's models on this device (docs/design/carplay.md §5 TTS),
/// one per `NaturalVoiceCatalog` entry, all through FluidAudio. Never
/// bundled; Settings downloads them pinned to a commit, and every file is
/// checked before Core ML opens it: Kokoro's pack by FluidAudio against its
/// pinned manifest, everything else (Pocket TTS, Paradee, and the shared
/// English text front end) by Waycar against the pinned commit's Hub
/// listing. Waycar fetches those itself, so FluidAudio's own fetches, some
/// of them from `main`, find the files present and never run.
/// Everything lives in FluidAudio's cache root,
/// `Application Support/fluidaudio`, which holds nothing else in this app.
/// Kokoro and Paradee share the English text front end there; deleting
/// one keeps it while the other is installed. Files are
/// `.completeUntilFirstUserAuthentication`: CarPlay speaks with the phone
/// locked. Outside a Settings download FluidAudio runs offline, so loading
/// in the car never fetches: a model it can't load from disk fails to the
/// system voice instead.
enum NaturalVoiceModel {
    /// FluidAudio 0.17.7's pinned Kokoro ANE-v3 release
    /// (`KokoroAneV3Assets.revision`, internal there, so copied). A FluidAudio
    /// pin that moves it leaves this release's files without the ones
    /// FluidAudio wants; offline, that load fails to the system voice rather
    /// than downloading in the car.
    static let kokoroRelease = "6c0750dd02ef9d981fb82f147d784a3f171755ee"
    /// The Kokoro release's base revision (`KokoroAneV3Assets.baseRevision`).
    /// The shared English G2P model FluidAudio fetches from the repository
    /// root would otherwise come from `main`.
    static let kokoroBaseRevision = "006395f65025af251858b1ab0a7178a6a1e73f9f"
    static let kokoroRepository = Repo.kokoro.remotePath
    /// FluidAudio fetches Pocket TTS and Paradee from `main`; these are the
    /// commits measured and checked on 2026-10-12.
    static let pocketRevision = "91748676fe3c8b2eb3007b3125253bcd898202c3"
    static let pocketRepository = Repo.pocketTts.remotePath
    static let paradeeRevision = "bb38cf32d9b4ac06006be67797995b2dab0751f0"
    static let paradeeRepository = Repo.paradeeInt8.remotePath
    /// The shared English text front end, the G2P model and the Misaki
    /// lexicon (measured 2026-10-12).
    static let sharedTextBytes: Int64 = 12_000_000
    /// A line to synthesize once after loading, so the first car line
    /// doesn't pay the model's first-run cost.
    static let warmUpText = "Ready."

    /// How the car says words Kokoro's lexicon doesn't know, in Misaki
    /// phonemes (the lexicon's own letter and word entries). Keys are
    /// lower-cased; FluidAudio tries the exact spelling, then lower case.
    static let pronunciations: [String: String] = [
        "herdr": "hˈɜɹdəɹ",
        "codex": "kˈOdˌɛks",
        "npm": "ˈɛn pˈi ˈɛm",
        "api": "ˈA pˈi ˈI",
        "cli": "sˈi ˈɛl ˈI",
        "github": "ɡˈɪthˌʌb",
        "omp": "ˈO ˈɛm pˈi",
    ]

    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    private struct Marker: Codable {
        let release: String
        let voices: [String]
    }

    /// FluidAudio's cache root on iOS (`TtsCacheDirectory`), computed
    /// without creating it.
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "fluidaudio", directoryHint: .isDirectory)
    }

    /// FluidAudio's network switch, set before every FluidAudio call: on
    /// only while Settings downloads. Also pins every catalog repository's
    /// fetches that FluidAudio doesn't pin itself.
    @MainActor
    static func allowNetwork(_ allowed: Bool) {
        ModelRegistry.revisionOverrides[kokoroRepository] = kokoroBaseRevision
        ModelRegistry.revisionOverrides[pocketRepository] = pocketRevision
        ModelRegistry.revisionOverrides[paradeeRepository] = paradeeRevision
        ModelHub.offlineMode = !allowed
    }

    // MARK: - Files

    /// Where FluidAudio keeps the English text front end, relative to `root`.
    static let sharedTextFolder = "Models/\(Repo.kokoro.folderName)"
    private static let kokoroFolder = "Models/kokoro-82m-coreml"
    private static let kokoroPack = "\(kokoroFolder)/ANE-v3/\(kokoroRelease)/en"
    private static let pocketFolder = "Models/\(Repo.pocketTts.folderName)"
    private static let pocketPack = "\(pocketFolder)/\(PocketTtsLanguage.english.repoSubdirectory)"
    /// The bundles FluidAudio loads for the Neural Engine placement.
    private static let pocketBundles = ModelNames.PocketTTS.requiredModels(precision: .fp16, placement: .ane)
    /// FluidAudio keeps the int8 variant in `<folder>/int8`.
    private static let paradeeFolder = "Models/paradee-8m-coreml"
    private static let paradeePack = "Models/\(Repo.paradeeInt8.folderName)"

    /// Folders only `model` reads, relative to `root`.
    static func ownedPaths(_ model: NaturalVoiceModelID) -> [String] {
        switch model {
        case .kokoro: [kokoroFolder]
        case .pocket: [pocketFolder]
        case .paradee: [paradeeFolder]
        }
    }

    /// Folders `model` reads that another model may read too.
    static func sharedPaths(_ model: NaturalVoiceModelID) -> [String] {
        switch model {
        case .kokoro, .paradee: [sharedTextFolder]
        case .pocket: []
        }
    }

    static let lexiconFile = "us_lexicon_cache.json"
    private static let sharedTextItems = ModelNames.G2P.requiredModels.union([lexiconFile])
    private static let sharedTextFiles = sharedTextItems.sorted().map { "\(sharedTextFolder)/\($0)" }
    private static let pocketVoices = Set(NaturalVoiceCatalog.info(.pocket).voices.map(\.id))

    /// Files the car needs that FluidAudio fetches outside its offline
    /// switch or checks only by name, relative to `root`.
    static func requiredFiles(_ model: NaturalVoiceModelID) -> [String] {
        switch model {
        case .kokoro:
            return sharedTextFiles + ["\(kokoroPack)/manifest.json"]
        case .pocket:
            // FluidAudio fetches a missing voice or `bos_before_voice.bin`
            // from `main`, so every offered voice must already be here.
            let constants = "\(pocketPack)/\(ModelNames.PocketTTS.constantsBinDir)"
            return pocketBundles.sorted().map { "\(pocketPack)/\($0)" }
                + ["\(constants)/bos_before_voice.bin"]
                + NaturalVoiceCatalog.info(.pocket).voices.map { "\(constants)/\($0.id).safetensors" }
        case .paradee:
            return ModelNames.Paradee.requiredModels.sorted().map { "\(paradeePack)/\($0)" } + sharedTextFiles
        }
    }

    /// Offered voices whose files are on disk. Kokoro's existing installs
    /// predate some offered voices.
    static func downloadedVoices(
        _ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root
    ) -> [NaturalVoiceOption] {
        let voices = NaturalVoiceCatalog.info(model).voices
        guard model == .kokoro else { return voices }
        return voices.filter { voice in
            ["\(kokoroPack)/\(voice.id).bin", "\(kokoroPack)/voices/\(voice.id).bin"].contains {
                FileManager.default.fileExists(atPath: root.appending(path: $0).path)
            }
        }
    }

    // MARK: - State

    private static func markerName(_ model: NaturalVoiceModelID) -> String {
        model == .kokoro ? "waycar-natural-voice.json" : "waycar-natural-voice-\(model.rawValue).json"
    }

    private static func release(_ model: NaturalVoiceModelID) -> String {
        switch model {
        case .kokoro: kokoroRelease
        case .pocket: pocketRevision
        case .paradee: paradeeRevision
        }
    }

    /// True once a download of `model`'s release finished, was checked, and
    /// warmed, and the files the car loads offline are still there.
    static func isInstalled(_ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root) -> Bool {
        guard let data = try? Data(contentsOf: root.appending(path: markerName(model))),
            let marker = try? JSONDecoder().decode(Marker.self, from: data),
            marker.release == release(model)
        else { return false }
        return missingFile(model, in: root) == nil
    }

    /// Records `model`'s release as installed.
    static func markInstalled(_ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root) throws {
        let voices = NaturalVoiceCatalog.info(model).voices.map(\.id)
        let marker = try JSONEncoder().encode(Marker(release: release(model), voices: voices))
        try marker.write(
            to: root.appending(path: markerName(model)),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func missingFile(_ model: NaturalVoiceModelID, in root: URL) -> String? {
        requiredFiles(model).first {
            !FileManager.default.fileExists(atPath: root.appending(path: $0).path)
        }
    }

    private static func missingSharedText(_ model: NaturalVoiceModelID, in root: URL) -> Bool {
        !sharedPaths(model).isEmpty
            && sharedTextFiles.contains { !FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
    }

    // MARK: - Sizes

    /// Bytes `model` takes on disk, shared files included.
    static func diskSize(_ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root) -> Int64 {
        bytes(of: ownedPaths(model) + sharedPaths(model), in: root)
    }

    /// Bytes of `model`'s own folders: above zero, a download started.
    static func ownedSize(_ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root) -> Int64 {
        bytes(of: ownedPaths(model), in: root)
    }

    /// Bytes deleting `model` frees: its own files and the shared ones no
    /// other installed model reads.
    static func freedSize(_ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root) -> Int64 {
        bytes(of: removablePaths(model, in: root), in: root)
    }

    /// Bytes every downloaded model takes, shared files counted once.
    static func totalDiskSize(in root: URL = NaturalVoiceModel.root) -> Int64 {
        bytes(at: root)
    }

    /// Bytes a download of `model` fetches: the catalog size, plus the
    /// shared text front end unless it's already here.
    static func downloadSize(_ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root) -> Int64 {
        NaturalVoiceCatalog.info(model).downloadBytes + (missingSharedText(model, in: root) ? sharedTextBytes : 0)
    }

    /// Bytes of `model`'s files already on disk that its download won't
    /// fetch: a shared text front end another model brought.
    static func downloadBaseline(_ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root) -> Int64 {
        missingSharedText(model, in: root) ? 0 : bytes(of: sharedPaths(model), in: root)
    }

    private static func bytes(of paths: [String], in root: URL) -> Int64 {
        paths.reduce(0) { $0 + bytes(at: root.appending(path: $1)) }
    }

    private static func bytes(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Install and delete

    /// Downloads, verifies, compiles and warms `model` and every offered
    /// voice, then protects the files and marks the release installed.
    /// `fetched` runs once every file is on disk and checked; compiling and
    /// warming follow. Cancellation stops between files.
    static func install(_ model: NaturalVoiceModelID, fetched: @Sendable () async -> Void) async throws {
        let root = try prepareRoot()
        let models = root.appending(path: "Models")
        switch model {
        case .kokoro:
            try await fetchSharedText(root: root)
            try await verify(sharedText, in: root)
            // FluidAudio fetches the pack itself, checked against its
            // pinned manifest, then compiles it.
            try await installKokoro(fetched: fetched)
        case .pocket:
            try await ModelHub.download(
                .pocketTts, subdirectory: pocketFiles.remote, to: root.appending(path: pocketFolder),
                shouldSkip: { pocketFiles.skips(remote: $0) })
            try removeUncataloguedVoices(in: root)
            try await verify(pocketFiles, in: root)
            await fetched()
            try await installPocket()
        case .paradee:
            try await fetchSharedText(root: root)
            try Task.checkCancellation()
            try await ModelHub.download(.paradeeInt8, to: models)
            try await verify(sharedText, in: root)
            try await verify(paradeeFiles, in: root)
            await fetched()
            try await installParadee()
        }
        if let missing = missingFile(model, in: root) { throw NaturalVoiceModelError.missingFile(missing) }
        try protectContents(of: root)
        try markInstalled(model, in: root)
    }

    /// The G2P model and the lexicon at Kokoro's base revision. FluidAudio
    /// fetches the lexicon from `main`; fetching it here first means
    /// FluidAudio finds it and never does.
    private static func fetchSharedText(root: URL) async throws {
        try await ModelHub.download(.kokoro, to: root.appending(path: "Models"), variant: "g2p-only")
        try Task.checkCancellation()
        let lexicon = root.appending(path: "\(sharedTextFolder)/\(lexiconFile)")
        guard !FileManager.default.fileExists(atPath: lexicon.path) else { return }
        let data = try await ModelHub.fetchFile(
            from: ModelRegistry.resolveModel(kokoroRepository, lexiconFile, revision: kokoroBaseRevision),
            description: lexiconFile)
        try data.write(to: lexicon, options: .atomic)
    }

    /// Removes Pocket preset voices the catalog doesn't offer (licensed for
    /// non-commercial use only, or not English), and any partial download of
    /// one, so they never stay on the device.
    static func removeUncataloguedVoices(in root: URL = NaturalVoiceModel.root) throws {
        let folder = root.appending(path: "\(pocketPack)/\(ModelNames.PocketTTS.constantsBinDir)")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard let suffix = name.range(of: ".safetensors"),
                !pocketVoices.contains(String(name[..<suffix.lowerBound]))
            else { continue }
            try FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    private static func installKokoro(fetched: @Sendable () async -> Void) async throws {
        let voices = NaturalVoiceCatalog.info(.kokoro).voices.map(\.id)
        let manager = NaturalVoiceBackends.kokoroManager(voice: nil)
        do {
            try await manager.initialize(preloadVoices: Set(voices))
            await fetched()
            try Task.checkCancellation()
            _ = try await manager.synthesizeDetailed(text: warmUpText)
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
    }

    /// Every file is already here and checked: FluidAudio loads without
    /// fetching.
    private static func installPocket() async throws {
        let manager = NaturalVoiceBackends.pocketManager()
        do {
            try await manager.initialize()
            try Task.checkCancellation()
            _ = try await manager.synthesizeDetailed(
                text: warmUpText, voice: NaturalVoiceCatalog.info(.pocket).defaultVoice)
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
    }

    /// Every file is already here and checked: FluidAudio loads without
    /// fetching.
    private static func installParadee() async throws {
        let manager = NaturalVoiceBackends.paradeeManager()
        do {
            try await manager.initialize()
            try Task.checkCancellation()
            _ = try await manager.synthesize(text: warmUpText)
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
    }

    /// Removes `model`'s files, except shared ones another installed model
    /// reads. Deleting the installed active model hands the car to the
    /// best other installed model, or turns the Natural voice off.
    static func delete(
        _ model: NaturalVoiceModelID, in root: URL = NaturalVoiceModel.root,
        defaults: UserDefaults = .standard
    ) throws {
        let wasInstalled = isInstalled(model, in: root)
        for path in removablePaths(model, in: root) {
            let url = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
        guard wasInstalled, NaturalVoiceSettings.activeModel(defaults: defaults) == model else { return }
        if let next = NaturalVoiceCatalog.models.first(where: { $0.id != model && isInstalled($0.id, in: root) }) {
            defaults.set(next.id.rawValue, forKey: NaturalVoiceSettings.activeModelKey)
        } else {
            defaults.set(false, forKey: NaturalVoiceSettings.enabledKey)
        }
    }

    /// The marker first, so a delete that stops partway leaves the model
    /// not installed.
    private static func removablePaths(_ model: NaturalVoiceModelID, in root: URL) -> [String] {
        let others = NaturalVoiceModelID.allCases.filter { $0 != model && isInstalled($0, in: root) }
        let needed = Set(others.flatMap(sharedPaths))
        return [markerName(model)] + ownedPaths(model) + sharedPaths(model).filter { !needed.contains($0) }
    }

    /// Creates the root with the car's protection class before FluidAudio
    /// writes into it, so new files inherit it, and checks FluidAudio
    /// still uses it.
    private static func prepareRoot() throws -> URL {
        let root = root
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: root.path)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var backupRoot = root
        try backupRoot.setResourceValues(excluded)
        let used = try TtsCacheDirectory.ensure()
        guard used.standardizedFileURL.path == root.standardizedFileURL.path else {
            throw NaturalVoiceModelError.unexpectedLocation(used.path)
        }
        return root
    }

    /// Files written through a temporary location keep that location's
    /// class, so every item gets the car's class explicitly.
    private static func protectContents(of root: URL) throws {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return }
        for case let url as URL in items {
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
    }

    // MARK: - Pinned files

    /// A Hub folder at a pinned commit, downloaded and checked file by file.
    struct PinnedFolder: Sendable {
        let repository: String
        let revision: String
        /// Remote folder; empty for the repository root.
        let remote: String
        /// Where FluidAudio keeps `remote`, relative to `root`.
        let local: String
        /// Whether a path relative to `remote` belongs to the model.
        let keeps: @Sendable (String) -> Bool

        /// FluidAudio's download filter, given a full remote path.
        func skips(remote path: String) -> Bool {
            guard path != remote else { return false }
            return NaturalVoiceModel.relativePath(path, under: remote).map { !keeps($0) } ?? true
        }
    }

    /// The shared English text front end at Kokoro's base revision.
    static let sharedText = PinnedFolder(
        repository: kokoroRepository, revision: kokoroBaseRevision, remote: "", local: sharedTextFolder,
        keeps: { sharedTextItems.contains(topItem($0)) })

    /// The Neural Engine bundles, the constants and the catalog's voices.
    static let pocketFiles = PinnedFolder(
        repository: pocketRepository, revision: pocketRevision,
        remote: PocketTtsLanguage.english.repoSubdirectory, local: pocketPack,
        keeps: { relative in
            let parts = relative.split(separator: "/")
            guard pocketBundles.contains(topItem(relative)), parts.last != ".DS_Store" else { return false }
            guard parts.count == 2, parts[0] == ModelNames.PocketTTS.constantsBinDir,
                parts[1].hasSuffix(".safetensors")
            else { return true }
            return pocketVoices.contains(String(parts[1].dropLast(".safetensors".count)))
        })

    static let paradeeFiles = PinnedFolder(
        repository: paradeeRepository, revision: paradeeRevision,
        remote: Repo.paradeeInt8.subPath ?? "int8", local: paradeePack,
        keeps: { ModelNames.Paradee.requiredModels.contains(topItem($0)) })

    private static func topItem(_ relative: String) -> String {
        String(relative.prefix { $0 != "/" })
    }

    /// `path` relative to `folder`, or nil unless it lies strictly inside
    /// it: listing paths come from the server and name files to delete.
    static func relativePath(_ path: String, under folder: String) -> String? {
        let relative: Substring
        if folder.isEmpty {
            relative = Substring(path)
        } else {
            guard path.hasPrefix(folder + "/") else { return nil }
            relative = path.dropFirst(folder.count + 1)
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") })
        else { return nil }
        return String(relative)
    }

    /// One entry of the Hub's tree listing.
    private struct ListedFile: Decodable {
        struct LFS: Decodable { let oid: String }
        let type: String
        let path: String
        let size: Int64?
        let oid: String?
        let lfs: LFS?
    }

    /// Compares every file of `folder` on disk with the pinned commit's
    /// listing, by LFS SHA-256 or git blob SHA-1. A mismatched file is
    /// removed; FluidAudio's download fetches missing files one by one, so
    /// resuming downloads only it again.
    private static func verify(_ folder: PinnedFolder, in root: URL) async throws {
        let local = root.appending(path: folder.local)
        for (relative, file) in try await pinnedFiles(folder) {
            try Task.checkCancellation()
            let url = local.appending(path: relative)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NaturalVoiceModelError.missingFile(relative)
            }
            guard try matches(file, at: url) else {
                try? FileManager.default.removeItem(at: url)
                throw NaturalVoiceModelError.corruptFile(relative)
            }
        }
    }

    /// The files `folder` keeps: its top level, then each kept folder in
    /// full, so a repository root isn't listed recursively.
    private static func pinnedFiles(_ folder: PinnedFolder) async throws -> [(String, ListedFile)] {
        var files: [(String, ListedFile)] = []
        for item in try await listing(folder, path: folder.remote, recursive: false) {
            guard let relative = relativePath(item.path, under: folder.remote) else {
                throw NaturalVoiceModelError.unverifiable(folder.repository)
            }
            guard folder.keeps(relative) else { continue }
            if item.type == "file" {
                files.append((relative, item))
                continue
            }
            for file in try await listing(folder, path: item.path, recursive: true) where file.type == "file" {
                guard let relative = relativePath(file.path, under: folder.remote) else {
                    throw NaturalVoiceModelError.unverifiable(folder.repository)
                }
                if folder.keeps(relative) { files.append((relative, file)) }
            }
        }
        guard !files.isEmpty else { throw NaturalVoiceModelError.unverifiable(folder.repository) }
        return files
    }

    /// Follows `Link` pages only on the registry's own host, each once, at
    /// most `maxListingPages`.
    private static func listing(_ folder: PinnedFolder, path: String, recursive: Bool) async throws -> [ListedFile] {
        let tree = path.isEmpty ? "tree/\(folder.revision)" : "tree/\(folder.revision)/\(path)"
        let first = try ModelRegistry.apiModels(folder.repository, recursive ? "\(tree)?recursive=true" : tree)
        var next: URL? = first
        var visited: Set<URL> = []
        var files: [ListedFile] = []
        while let url = next {
            guard url.scheme == first.scheme, url.host == first.host, visited.insert(url).inserted,
                visited.count <= maxListingPages
            else { throw NaturalVoiceModelError.unverifiable(folder.repository) }
            let (data, response) = try await ModelHub.fetchWithAuth(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NaturalVoiceModelError.unverifiable(folder.repository)
            }
            files += try JSONDecoder().decode([ListedFile].self, from: data)
            next = nextPage(http.value(forHTTPHeaderField: "Link"))
        }
        return files
    }

    private static let maxListingPages = 50

    /// The `rel="next"` URL of a paged listing's `Link` header.
    private static func nextPage(_ link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close
            else { continue }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }

    private static func matches(_ file: ListedFile, at url: URL) throws -> Bool {
        if let lfs = file.lfs {
            return try digest(of: url, using: SHA256()) == lfs.oid.lowercased()
        }
        guard let oid = file.oid, let size = file.size else { return false }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        return try digest(of: url, using: hasher) == oid.lowercased()
    }

    /// Hex digest, reading in 1 MiB chunks rather than the whole file.
    private static func digest<H: HashFunction>(of url: URL, using initial: H) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = initial
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Settings' view of the catalog models: per-model download with progress,
/// size, use, delete. One download or delete runs at a time. A download that
/// failed, or that the app was quit during, leaves its verified files so it
/// can resume; Settings shows their size and deletes them.
@MainActor
@Observable
final class NaturalVoiceModelStore {
    static let shared = NaturalVoiceModelStore()

    enum Phase: Equatable, Sendable {
        case checking
        case absent
        /// Bytes on disk over the expected download, 0...1.
        case downloading(Double)
        /// Downloaded; checking, compiling for this device and warming.
        case preparing
        case installed(bytes: Int64)
        /// A download that didn't finish left these bytes on disk.
        case incomplete(bytes: Int64)
    }

    private var machine = NaturalVoiceModelMachine()
    var phases: [NaturalVoiceModelID: Phase] { machine.snapshot.phases }
    /// Offered voices on disk, per installed model.
    var voices: [NaturalVoiceModelID: [NaturalVoiceOption]] { machine.snapshot.voices }
    /// Bytes deleting each model frees.
    var freedBytes: [NaturalVoiceModelID: Int64] { machine.snapshot.freed }
    /// Bytes each model's download fetches.
    var downloadBytes: [NaturalVoiceModelID: Int64] { machine.snapshot.download }
    /// Every downloaded voice model, shared files counted once.
    var totalBytes: Int64 { machine.snapshot.total }
    var busyModel: NaturalVoiceModelID? { machine.busyModel }
    /// The process-wide network switch remains on through cancellation cleanup.
    var isDownloading: Bool { machine.isDownloading }
    @ObservationIgnored private var work: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var snapshots: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private let readSnapshot: @Sendable () async -> Snapshot
    private nonisolated static let log = Logger(subsystem: "com.otreva.waycar", category: "carplay")

    typealias Snapshot = NaturalVoiceModelMachine.Snapshot

    convenience init() {
        self.init(readSnapshot: { await NaturalVoiceModelStore.snapshot() })
    }

    init(readSnapshot: @escaping @Sendable () async -> Snapshot) {
        self.readSnapshot = readSnapshot
    }

    func phase(_ model: NaturalVoiceModelID) -> Phase {
        phases[model] ?? .checking
    }

    func isInstalled(_ model: NaturalVoiceModelID) -> Bool {
        if case .installed = phase(model) { return true }
        return false
    }

    /// Reads what is on disk, unless a download or delete is running.
    func refresh() { send(.refresh) }

    /// Starts downloading `model`, resuming from any verified files already
    /// there. Releases the car's model first: its load switches the network
    /// off, which would fail the download.
    func download(_ model: NaturalVoiceModelID) { send(.download(model)) }

    /// Stops the download and removes what it fetched.
    func cancel() { send(.cancel) }

    /// Removes `model` or its download's leftovers; a running download of
    /// it is cancelled instead, which removes what it fetched.
    func delete(_ model: NaturalVoiceModelID) { send(.delete(model)) }

    private func send(_ event: NaturalVoiceModelMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case .readSnapshot(let token):
                snapshots[token] = Task {
                    let snapshot = await readSnapshot()
                    snapshots[token] = nil
                    send(.snapshot(token, snapshot))
                }
            case .download(let op):
                NaturalVoice.unload()
                NaturalVoiceModel.allowNetwork(true)
                work[op.token] = Task { await runDownload(op.model, token: op.token) }
            case .delete(let op):
                if NaturalVoiceSettings.activeModel() == op.model { NaturalVoice.unload() }
                work[op.token] = Task {
                    await Self.remove(op.model)
                    send(.completed(op.token))
                }
            case .cancel(let token):
                work[token]?.cancel()
            case .clearWork(let token):
                work[token] = nil
            }
        }
    }

    private nonisolated static func snapshot() async -> Snapshot {
        await Task.detached(priority: .utility) { () -> Snapshot in
            var snapshot = Snapshot()
            for model in NaturalVoiceModelID.allCases {
                let freed = NaturalVoiceModel.freedSize(model)
                if NaturalVoiceModel.isInstalled(model) {
                    snapshot.phases[model] = .installed(bytes: NaturalVoiceModel.diskSize(model))
                    snapshot.voices[model] = NaturalVoiceModel.downloadedVoices(model)
                } else if NaturalVoiceModel.ownedSize(model) > 0 {
                    snapshot.phases[model] = .incomplete(bytes: freed)
                } else {
                    snapshot.phases[model] = .absent
                }
                snapshot.freed[model] = freed
                snapshot.download[model] = NaturalVoiceModel.downloadSize(model)
            }
            snapshot.total = NaturalVoiceModel.totalDiskSize()
            return snapshot
        }.value
    }

    private nonisolated static func remove(_ model: NaturalVoiceModelID) async {
        do {
            try await Task.detached(priority: .utility) { try NaturalVoiceModel.delete(model) }.value
        } catch {
            log.error("Natural voice model delete failed: \(error)")
        }
    }

    private func runDownload(_ model: NaturalVoiceModelID, token: UInt64) async {
        let (expected, baseline) = await Task.detached(priority: .utility) {
            (NaturalVoiceModel.downloadSize(model), NaturalVoiceModel.downloadBaseline(model))
        }.value
        let progress = Task {
            while !Task.isCancelled, machine.isCurrent(token), !machine.fetched {
                let bytes = await Task.detached(priority: .utility) {
                    NaturalVoiceModel.diskSize(model) - baseline
                }.value
                guard !Task.isCancelled, !machine.fetched else { return }
                send(.progress(token, min(Double(max(bytes, 0)) / Double(expected), 1)))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { NaturalVoiceModel.allowNetwork(false) }
        do {
            try await NaturalVoiceModel.install(model) { [weak self] in await self?.send(.fetched(token)) }
            progress.cancel()
            NaturalVoice.modelInstalled()
            // The first model downloaded is the one the car uses.
            let active = NaturalVoiceSettings.activeModel()
            let activeInstalled = await Task.detached(priority: .utility) {
                NaturalVoiceModel.isInstalled(active)
            }.value
            if !activeInstalled {
                UserDefaults.standard.set(model.rawValue, forKey: NaturalVoiceSettings.activeModelKey)
            }
        } catch {
            progress.cancel()
            if Task.isCancelled || error is CancellationError {
                await Self.remove(model)
            } else {
                Self.log.error("Natural voice model download failed: \(error)")
            }
        }
        send(.completed(token))
    }
}
