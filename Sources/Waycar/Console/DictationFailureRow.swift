import SwiftUI
import UIKit

/// Why the last Dictation session ended early, with Dismiss; a denied
/// microphone also offers a shortcut to Settings.
struct DictationFailureRow: View {
    let failure: DictationStore.Failure
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
            HStack(spacing: 8) {
                if failure == .microphonePermissionDenied {
                    Button("Open Settings") {
                        dismiss()
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
                Button("Dismiss", action: dismiss)
                    .tint(Brand.Colors.quietAction)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var text: String {
        switch failure {
        case .microphonePermissionDenied:
            "Dictation needs microphone access. Turn it on in Settings."
        case .message(let text):
            text
        }
    }
}
