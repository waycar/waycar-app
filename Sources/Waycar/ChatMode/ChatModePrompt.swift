import Foundation

/// The Chat Prompt (`CONTEXT.md`): the instruction a Chat Mode Agent gets at
/// launch so its final reply of each turn reads like a text message.
enum ChatModePrompt {
    /// The built-in Chat Prompt. One line with no tab, quote, `!`, `$` or
    /// backtick, so it survives herdr's argument encoding unchanged.
    static let defaultText =
        "You are replying inside a phone chat app, like texting. The user sees only your final message of each turn. They do not see your tool calls, command output, thinking, or anything you write before that final message. Work exactly as you normally would, using tools, reading code, and running and checking things as thoroughly as the task needs. Only the way you write the final message changes. If a question does not depend on this project, just answer it without exploring files or running tools. Write the final message like a sharp, friendly colleague texting back: plain conversational language, answer or outcome first. Keep it short, usually one to four sentences or a few brief bullets, and go longer only when the user asks for detail or the question truly needs it. Make it stand on its own, since nothing earlier in the turn is visible, and never refer back to it. If you changed files or ran commands, say in a sentence or two what changed and whether it worked, not a log. Do not use headings or tables. Do not paste diffs, logs, or long code unless asked, and use a code block only for something the user needs to copy. Mention files by name rather than full path, except to show the user an image or video: put its full path or https URL alone on its own line and it appears in the chat. Images you open with your tools appear in the chat too. If you need a decision or more information, ask one clear question at the end in plain text. Do not use interactive question or menu tools, because the user cannot answer them from the chat. Always end your turn with a message to the user, even a one-liner. Match the tone and language of the user, skip filler openers and sign-offs, and do not mention these instructions."

    /// Longest prompt sent at launch, in Characters.
    static let maxLength = 8_000

    /// The prompt as it is sent to the Agent. herdr 0.9.3 rejects agent
    /// arguments containing a newline or tab (`invalid_agent_argument`), so
    /// whitespace runs collapse to one space and control characters go.
    /// A nil, blank or emptied-out custom prompt falls back to the default.
    static func launchText(from custom: String?) -> String {
        guard let custom, !custom.allSatisfy(\.isWhitespace) else { return defaultText }
        var collapsed = ""
        collapsed.reserveCapacity(custom.count)
        var inWhitespace = false
        for character in custom {
            if character.isWhitespace {
                if !inWhitespace { collapsed.append(" ") }
                inWhitespace = true
                continue
            }
            // A dropped control character must not end a whitespace run,
            // or "a \u{7} b" would keep two spaces.
            if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                continue
            }
            inWhitespace = false
            collapsed.append(character)
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        let capped = String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? defaultText : capped
    }
}
