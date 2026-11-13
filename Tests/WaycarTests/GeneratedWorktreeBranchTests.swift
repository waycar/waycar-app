import Testing

@testable import Waycar

/// SplitMix64: a small deterministic generator, so minted branches are
/// reproducible in tests.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Always answers the same word, to reach both ends of every range.
private struct ConstantRandomNumberGenerator: RandomNumberGenerator {
    let value: UInt64

    mutating func next() -> UInt64 { value }
}

@Suite("Generated worktree branch")
struct GeneratedWorktreeBranchTests {
    private static func mints(seed: UInt64, count: Int) -> [String] {
        var generator = SeededRandomNumberGenerator(seed: seed)
        return (0..<count).map { _ in GeneratedWorktreeBranch.mint(using: &generator) }
    }

    @Test func mintsHerdrsFormatFromItsWordLists() {
        let hexDigits = Set("0123456789abcdef")
        for branch in Self.mints(seed: 42, count: 500) {
            #expect(branch.hasPrefix("worktree/"), "\(branch)")
            let parts = branch.dropFirst("worktree/".count)
                .split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                Issue.record("expected adjective-noun-hex, got \(branch)")
                continue
            }
            #expect(GeneratedWorktreeBranch.adjectives.contains(String(parts[0])), "\(branch)")
            #expect(GeneratedWorktreeBranch.nouns.contains(String(parts[1])), "\(branch)")
            #expect(parts[2].count == 4 && parts[2].allSatisfy { hexDigits.contains($0) }, "\(branch)")
        }
    }

    @Test func everyMintedBranchIsAValidGitBranch() {
        for branch in Self.mints(seed: 7, count: 500) {
            #expect(GitBranchName.validationError(branch) == nil, "\(branch)")
        }
    }

    /// The lowest and highest draws: the suffix keeps 4 digits, and both
    /// ends of each word list are reachable without going out of range.
    @Test func extremeDrawsPadTheSuffixAndStayInTheWordLists() {
        var lowest = ConstantRandomNumberGenerator(value: 0)
        var highest = ConstantRandomNumberGenerator(value: .max)

        #expect(GeneratedWorktreeBranch.mint(using: &lowest) == "worktree/brave-river-0000")
        #expect(GeneratedWorktreeBranch.mint(using: &highest) == "worktree/silver-valley-ffff")
    }

    @Test func theSameSeedMintsTheSameBranches() {
        #expect(Self.mints(seed: 2026, count: 20) == Self.mints(seed: 2026, count: 20))
    }
}
