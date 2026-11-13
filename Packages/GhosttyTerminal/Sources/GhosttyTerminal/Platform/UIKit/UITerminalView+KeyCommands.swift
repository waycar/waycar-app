//
//  UITerminalView+KeyCommands.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import UIKit

    extension UITerminalView {
        /// Ctrl combos the text input system would otherwise interpret
        /// itself: as a `UITextInput` first responder, the view hands
        /// hardware keys to UIKit's text machinery, which consumes most
        /// Ctrl+letter chords (its emacs-style bindings) before
        /// `pressesBegan` ever fires. Registering them as key commands with
        /// priority over system behavior is the only reliable claim — the
        /// same route Blink and SwiftTerm take.
        private static let controlKeyCommandInputs: [String] = {
            var inputs = (UInt8(ascii: "a") ... UInt8(ascii: "z")).map {
                String(UnicodeScalar($0))
            }
            inputs += (UInt8(ascii: "0") ... UInt8(ascii: "9")).map {
                String(UnicodeScalar($0))
            }
            inputs += [" ", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
            return inputs
        }()

        private static let controlKeyCommands: [UIKeyCommand] =
            controlKeyCommandInputs.map { input in
                let command = UIKeyCommand(
                    input: input,
                    modifierFlags: .control,
                    action: #selector(handleControlKeyCommand(_:))
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }

        /// Escape, which the text input system also handles itself: for a
        /// `UITextInput` first responder UIKit's system behaviour for a
        /// hardware Escape is to end editing — the view resigns, the keyboard
        /// (and the accessory bar over it) drops — and that runs before
        /// `pressesBegan` ever sees the key. A terminal cannot give Escape
        /// away, so it is claimed the same way as the Ctrl combos, under
        /// every modifier set a program might bind (Cmd-Escape stays with
        /// the system).
        ///
        /// Catalyst needs this just the same. It has no software keyboard to
        /// drop, but the end-editing behaviour is the text input system's,
        /// not the keyboard's: an unclaimed Escape resigns the view there
        /// too, the press never reaches `pressesBegan`, and every key after
        /// it goes nowhere until the next click.
        private static let escapeKeyCommands: [UIKeyCommand] = {
            let modifierSets: [UIKeyModifierFlags] = [
                [], .shift, .control, .alternate,
                [.shift, .control], [.shift, .alternate], [.control, .alternate],
                [.shift, .control, .alternate],
            ]
            return modifierSets.map { flags in
                let command = UIKeyCommand(
                    input: UIKeyCommand.inputEscape,
                    modifierFlags: flags,
                    action: #selector(handleEscapeKeyCommand(_:))
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }()

        /// Plain arrows, which the iPadOS keyboard focus system takes for
        /// itself: the terminal is not a focus item, so the focused item stays
        /// a sibling — a SwiftUI `List` cell (the Console's Agent list) — and
        /// focus movement, with selection following focus, eats the arrows
        /// before `pressesBegan`; with a focused terminal that moved the Agent
        /// list instead of reaching the PTY (#80). A terminal cannot give its
        /// arrows away either, so they are claimed like Escape. Modified
        /// arrows (Shift/Ctrl selections, Cmd jumps) stay with the press path,
        /// which carries their modifiers. (Waycar patch)
        private static let arrowKeyCommands: [UIKeyCommand] = [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
        ].map { input in
            let command = UIKeyCommand(
                input: input,
                modifierFlags: [],
                action: #selector(handleArrowKeyCommand(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        /// Return, like Escape: the text input system claims it for a
        /// `UITextInput` first responder before `pressesBegan` ever sees the
        /// key (insertNewline), and the iPadOS focus system activates the
        /// focused sibling (a selected Agent row) with it — and a terminal
        /// cannot give Return away (#80). ⌘ is included, unlike ⌘Escape which
        /// stays with the system: ⌘Return has no system meaning over a
        /// terminal, and harnesses read it as submit, so it is delivered as a
        /// plain Return (see `handleReturnKeyCommand`) rather than a
        /// super-modified Enter that Ghostty's own keybinds may consume.
        /// Shift is left out — a Shift-Return is a newline, not a Return (see
        /// `shiftReturnKeyCommands`) — and so are chords that carry Shift.
        /// (Waycar patch)
        private static let returnKeyCommands: [UIKeyCommand] = {
            let modifierSets: [UIKeyModifierFlags] = [
                [], .control, .alternate, .command,
                [.control, .alternate], [.control, .command], [.alternate, .command],
                [.control, .alternate, .command],
            ]
            return modifierSets.map { flags in
                let command = UIKeyCommand(
                    input: "\r",
                    modifierFlags: flags,
                    action: #selector(handleReturnKeyCommand(_:))
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }()

        /// Shift-Return, claimed for the same reasons as Return, but a
        /// newline rather than a submit: it goes to the surface as Ctrl+J,
        /// which the legacy encoding sends as a bare LF (0x0A). omp binds its
        /// `tui.input.newLine` to shift+enter and ctrl+j and reads a raw LF as
        /// a newline, so the byte lands in the edit line; a terminal on the
        /// kitty keyboard protocol reports ctrl+j, which omp also binds. It
        /// takes the key path, never paste, so bracketed paste never frames
        /// it. Shift chords with Ctrl, Alt or ⌘ stay with the press path.
        /// (Waycar patch)
        private static let shiftReturnKeyCommands: [UIKeyCommand] = {
            let command = UIKeyCommand(
                input: "\r",
                modifierFlags: .shift,
                action: #selector(handleShiftReturnKeyCommand(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            return [command]
        }()

        /// Tab and Shift-Tab, which the iPadOS focus system uses to move focus
        /// between groups — over a terminal that is not a focus item, Tab
        /// would leave for the sidebar. The terminal needs both: shell
        /// completion, and reverse completion or a backwards field move. So
        /// they are claimed like Escape. (Waycar patch)
        private static let tabKeyCommands: [UIKeyCommand] = {
            let modifierSets: [UIKeyModifierFlags] = [[], .shift]
            return modifierSets.map { flags in
                let command = UIKeyCommand(
                    input: "\t",
                    modifierFlags: flags,
                    action: #selector(handleTabKeyCommand(_:))
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }()

        // Catalyst included: its text-input system also swallows Ctrl+letter
        // before `pressesBegan` (the Control press itself arrives, the letter
        // never does), and the key command is the only route left. The
        // per-runloop claim below dedupes against a press on systems that
        // deliver both.
        //
        // UIKit asks for this list on every key event, so it can change with
        // the view's state: while a composition is on screen every key is the
        // input method's (Escape cancels it, Return and Tab commit or pick a
        // candidate — see `TerminalIMEComposition`), and the Escape, arrow,
        // Return and Tab commands step aside so the press takes the deferral
        // path in `pressesBegan` as it always did.
        override open var keyCommands: [UIKeyCommand]? {
            var commands = super.keyCommands ?? []
            commands.append(contentsOf: Self.controlKeyCommands)
            if !inputHandler.hasMarkedText {
                commands.append(contentsOf: Self.escapeKeyCommands)
                commands.append(contentsOf: Self.arrowKeyCommands)
                commands.append(contentsOf: Self.returnKeyCommands)
                // (Waycar patch) Shift-Return and Tab, as above.
                commands.append(contentsOf: Self.shiftReturnKeyCommands)
                commands.append(contentsOf: Self.tabKeyCommands)
            }
            return commands
        }

        @objc private func handleControlKeyCommand(_ command: UIKeyCommand) {
            guard let input = command.input, input.count == 1,
                  let character = input.first,
                  let press = TerminalKeyPress(
                      typing: character,
                      modifiers: TerminalInputModifiers(from: command.modifierFlags)
                  )
            else { return }
            guard claimKeyCommandDelivery(
                input: input,
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=\(TerminalDebugLog.describe(input)) mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            // A chord, not typing: it closes an open composition the way a
            // hardware press would, and takes the shared key path.
            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }
            _ = surface?.sendKey(press)
        }

        /// The Escape command's action: the key goes to the surface as a
        /// press, exactly as `pressesBegan` would have sent it, and the view
        /// stays first responder. The command is not offered while text is
        /// marked (see `keyCommands`), so no composition is open here.
        @objc private func handleEscapeKeyCommand(_ command: UIKeyCommand) {
            guard claimKeyCommandDelivery(
                input: UIKeyCommand.inputEscape,
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=escape mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            _ = surface?.sendKey(TerminalKeyPress(
                .escape,
                modifiers: TerminalInputModifiers(from: command.modifierFlags)
            ))
        }

        /// The arrows' action, same shape as Escape's: the key reaches the
        /// surface as a press and the view stays first responder.
        /// (Waycar patch)
        @objc private func handleArrowKeyCommand(_ command: UIKeyCommand) {
            guard let input = command.input else { return }
            let key: TerminalKey
            switch input {
            case UIKeyCommand.inputUpArrow: key = .arrowUp
            case UIKeyCommand.inputDownArrow: key = .arrowDown
            case UIKeyCommand.inputLeftArrow: key = .arrowLeft
            case UIKeyCommand.inputRightArrow: key = .arrowRight
            default: return
            }
            guard claimKeyCommandDelivery(
                input: input,
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=\(TerminalDebugLog.describe(input)) mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            _ = surface?.sendKey(TerminalKeyPress(
                key,
                modifiers: TerminalInputModifiers(from: command.modifierFlags)
            ))
        }

        /// The Return command's action, same shape as Escape's and the
        /// arrows': the key reaches the surface as a press and the view
        /// stays first responder. ⌘ is dropped so ⌘Return submits exactly as
        /// Return does; Ctrl and Alt are kept. (Waycar patch)
        @objc private func handleReturnKeyCommand(_ command: UIKeyCommand) {
            guard claimKeyCommandDelivery(
                input: "\r",
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=return mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            var flags = command.modifierFlags
            flags.remove(.command)
            _ = surface?.sendKey(TerminalKeyPress(
                .enter,
                modifiers: TerminalInputModifiers(from: flags)
            ))
        }

        /// The Shift-Return command's action: a newline as Ctrl+J (LF), see
        /// `shiftReturnKeyCommands`. It claims under Return's signature with
        /// Shift, the same one the press path computes for this key.
        /// (Waycar patch)
        @objc private func handleShiftReturnKeyCommand(_ command: UIKeyCommand) {
            guard claimKeyCommandDelivery(
                input: "\r",
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=shift-return mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            _ = surface?.sendKey(TerminalKeyPress(.j, modifiers: .ctrl))
        }

        /// The Tab commands' action, same shape as Escape's: Tab, or Shift-Tab
        /// with its Shift, reaches the surface as a press. (Waycar patch)
        @objc private func handleTabKeyCommand(_ command: UIKeyCommand) {
            guard claimKeyCommandDelivery(
                input: "\t",
                modifierFlags: command.modifierFlags
            ) else { return }
            TerminalDebugLog.log(
                .input,
                "uikit key command input=tab mods=0x\(String(command.modifierFlags.rawValue, radix: 16))"
            )
            _ = surface?.sendKey(TerminalKeyPress(
                .tab,
                modifiers: TerminalInputModifiers(from: command.modifierFlags)
            ))
        }

        /// Whether this path gets to deliver a key that is also registered
        /// as a `UIKeyCommand` (a Ctrl combo, Escape, an arrow, Return,
        /// Shift-Return, Tab). Whichever of
        /// `pressesBegan` / the key command runs first wins the press; the
        /// entry expires at the end of the runloop turn, before the key can
        /// physically repeat. (Waycar patch: the arrow, Return, Shift-Return
        /// and Tab claims share it.)
        func claimKeyCommandDelivery(
            input: String,
            modifierFlags: UIKeyModifierFlags
        ) -> Bool {
            let relevant = modifierFlags.intersection(
                [.control, .shift, .alternate, .command]
            )
            let signature = "\(input.lowercased())|\(relevant.rawValue)"
            guard !hardwareKeyboard.recentKeyCommandDeliveries.contains(signature) else {
                TerminalDebugLog.log(
                    .input,
                    "uikit key delivery deduped signature=\(signature)"
                )
                return false
            }
            hardwareKeyboard.recentKeyCommandDeliveries.insert(signature)
            DispatchQueue.main.async { [weak self] in
                self?.hardwareKeyboard.recentKeyCommandDeliveries.remove(signature)
            }
            return true
        }
    }
#endif
