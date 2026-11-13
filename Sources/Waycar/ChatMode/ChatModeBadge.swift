import SwiftUI
import UIKit

/// The mark of a Chat Mode Agent on a Console card: a small user-bubble
/// violet disc with a chat bubble in it, ringed in the card surface so it
/// reads as sitting on the kind glyph's edge, iMessage-style. VoiceOver
/// hears it as "Chat Mode".
struct ChatModeBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(Brand.Colors.chatUser)
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Brand.Colors.chatUserText)
        }
        .frame(width: 16, height: 16)
        .padding(2)
        .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chat Mode")
    }
}
