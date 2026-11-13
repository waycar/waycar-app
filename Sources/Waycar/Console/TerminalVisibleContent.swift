import Foundation

/// Whether terminal output draws anything a person would see: a printable
/// character other than a space, outside every escape sequence (#105).
///
/// mosh-server's first frame is the blank screen it starts with — cursor
/// moves, clears, mode switches — sent before the Agent's own screen
/// arrives. A terminal that went live on it would flash an empty grid over
/// the frame it is replacing. Stateful across chunks, so a sequence split
/// between two reads never passes for text.
struct TerminalVisibleContentScanner {
    private enum Phase {
        case ground
        /// After ESC: the sequence's kind is the next byte.
        case escape
        /// ESC then intermediates (0x20–0x2F), until a final byte.
        case escapeIntermediate
        /// CSI: parameters and intermediates until a final byte (0x40–0x7E).
        case csi
        /// OSC, DCS, SOS, PM, APC: a string until BEL or ST (ESC \).
        case string
        /// ESC seen inside a string: `\` ends it.
        case stringEscape
    }

    private var phase = Phase.ground

    /// Scans `bytes`, carrying any unfinished sequence into the next call;
    /// true when they contain visible content.
    mutating func containsVisibleContent(_ bytes: Data) -> Bool {
        var visible = false
        for byte in bytes {
            switch phase {
            case .ground:
                if byte == 0x1B {
                    phase = .escape
                } else if byte > 0x20, byte != 0x7F {
                    visible = true
                }
            case .escape:
                switch byte {
                case UInt8(ascii: "["): phase = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"),
                    UInt8(ascii: "^"), UInt8(ascii: "_"):
                    phase = .string
                case 0x20...0x2F: phase = .escapeIntermediate
                case 0x1B: phase = .escape
                default: phase = .ground
                }
            case .escapeIntermediate:
                if !(0x20...0x2F).contains(byte) { phase = .ground }
            case .csi:
                if (0x40...0x7E).contains(byte) { phase = .ground }
            case .string:
                if byte == 0x07 {
                    phase = .ground
                } else if byte == 0x1B {
                    phase = .stringEscape
                }
            case .stringEscape:
                phase = byte == UInt8(ascii: "\\") ? .ground : .string
            }
        }
        return visible
    }
}
