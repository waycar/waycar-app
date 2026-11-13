import SwiftUI

/// Settings › App Icon: every shipped icon, grouped by mark, as tappable tiles.
struct AppIconPickerView: View {
    let settings: AppIconSettings

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 16)]

    var body: some View {
        Form {
            ForEach(AppIconMark.allCases) { mark in
                Section {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(AppIconOption.options(for: mark)) { option in
                            tile(option)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text(mark.title)
                } footer: {
                    if mark == AppIconMark.allCases.last {
                        notificationNote
                    }
                }
            }
            if let error = settings.lastError {
                Section {
                    Text("Couldn't change the icon: \(error)")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Since iOS 18.1, Notification Center keeps the old icon until a
    /// restart (an iOS bug the app cannot work around), so say so up front.
    private var notificationNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Notifications may keep showing your previous icon until you restart your "
                    + "\(UIDevice.current.localizedModel). This is an iOS bug in iOS 18.1 and later.")
            if let url = Self.notificationBugURL {
                Link("Read about it on the Apple Developer Forums", destination: url)
            }
        }
        .accessibilityIdentifier("settings.appIcon.notificationNote")
    }

    static let notificationBugURL = URL(string: "https://developer.apple.com/forums/thread/780074")

    private func tile(_ option: AppIconOption) -> some View {
        let isSelected = option == settings.selection
        return Button {
            Task { await settings.select(option) }
        } label: {
            VStack(spacing: 6) {
                Image(option.previewImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 4, y: 4)
                        }
                    }
                Text(option.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.mark.title), \(option.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon.\(option.rawValue)")
    }
}

#Preview {
    NavigationStack {
        AppIconPickerView(settings: AppIconSettings())
    }
}
