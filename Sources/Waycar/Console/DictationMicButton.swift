import SwiftUI

/// The Composer's Dictation control beside Add and More: a microphone while
/// idle, a red stop while starting or listening. Disabled only while the last
/// words are being flushed.
struct DictationMicButton: View {
    let phase: DictationStore.Phase
    let idleTint: Color
    let action: () -> Void

    var body: some View {
        if phase == .idle {
            Button(action: action) {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(idleTint)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Dictate")
            .accessibilityHint("Speak into the draft. Speech is transcribed on this device.")
        } else {
            Button(action: action) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(phase == .finishing)
            .accessibilityLabel("Stop Dictation")
            .accessibilityHint("Keeps what you said in the draft")
        }
    }
}
