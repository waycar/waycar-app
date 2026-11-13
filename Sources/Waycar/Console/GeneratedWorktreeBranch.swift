import Foundation

/// The branch a New Worktree launch sends when the Branch field is empty,
/// in herdr 0.9.1's own generated format: `worktree/<adjective>-<noun>-<hex>`
/// with herdr's word lists and a 16-bit suffix as 4 lowercase hex digits.
/// Minting it here, rather than letting herdr pick, gives the launch a name
/// only it knows, so a lost `worktree.create` answer can be reconciled by
/// exact branch without mistaking another launch's worktree for its own.
/// Every minted name passes `GitBranchName.validationError`.
enum GeneratedWorktreeBranch {
    static let prefix = "worktree/"
    static let adjectives = [
        "brave", "calm", "clear", "green", "lucky", "quiet", "rapid", "silver",
    ]
    static let nouns = [
        "river", "cloud", "field", "forest", "harbor", "meadow", "stone", "valley",
    ]

    /// A fresh branch drawn from the system's random source.
    static func mint() -> String {
        var generator = SystemRandomNumberGenerator()
        return mint(using: &generator)
    }

    /// A branch drawn from `generator`; the same generator state always
    /// yields the same branch.
    static func mint<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        let adjective = adjectives[Int.random(in: adjectives.indices, using: &generator)]
        let noun = nouns[Int.random(in: nouns.indices, using: &generator)]
        let suffix = UInt16.random(in: .min ... .max, using: &generator)
        return prefix + adjective + "-" + noun + "-" + hex(suffix)
    }

    /// `value` as exactly 4 lowercase hex digits, zero-padded.
    private static func hex(_ value: UInt16) -> String {
        let digits = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }
}
