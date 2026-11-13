import SwiftUI
import UIKit

/// The Composer Tray: one scrolling row of chips for the images and files
/// added to the draft, in the order they were added. Each chip carries its
/// own upload status; the row scrolls to a newly added chip. Renders nothing
/// while the tray is empty, and keeps one fixed row height while it is not,
/// so status changes never resize the card around it. The tray's notice,
/// when it has one, sits under the chips and wraps to two lines.
struct ComposerTrayView: View {
    let tray: ComposerTray
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room above and after the chips for each Remove control's 44 pt hit
    /// area, which reaches past the chip's top-trailing corner. Kept inside
    /// the scroll view's content, so its clipping never trims the target.
    private static let removeRoom = ComposerTrayChip.removeReach
    /// Wider than the Remove control's reach past the chip, so a chip's
    /// target overlaps its trailing neighbor by only a corner sliver; the
    /// chips' z order puts that sliver on the chip it removes.
    private static let chipSpacing: CGFloat = 12

    private var chipSide: CGFloat { verticalSizeClass == .compact ? 48 : 64 }

    var body: some View {
        if !tray.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                chips
                if let notice = tray.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Brand.Colors.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Only a new notice is announced: remounting the tray (Message
            // Agent opening, Chat input appearing) must not repeat an old one.
            .onChange(of: tray.notice) { _, notice in
                if let notice { AccessibilityNotification.Announcement(notice).post() }
            }
        }
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.chipSpacing) {
                    ForEach(Array(tray.items.enumerated()), id: \.element.id) { index, item in
                        ComposerTrayChip(
                            tray: tray,
                            item: item,
                            position: index + 1,
                            count: tray.items.count,
                            side: chipSide)
                        .id(item.id)
                        // Earlier chips draw above later ones, so a Remove
                        // target reaching past its chip is never covered by
                        // the next chip.
                        .zIndex(Double(tray.items.count - index))
                        .transition(chipTransition)
                    }
                }
                .padding(.top, Self.removeRoom)
                .padding(.trailing, Self.removeRoom)
                .animation(chipAnimation, value: tray.items.map(\.id))
            }
            .frame(height: chipSide + Self.removeRoom)
            .onChange(of: tray.items.count) { previous, current in
                guard current > previous, let newest = tray.items.last?.id else { return }
                withAnimation(reduceMotion ? nil : .snappy) {
                    proxy.scrollTo(newest, anchor: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Added items")
    }

    private var chipTransition: AnyTransition {
        reduceMotion ? .opacity : .scale.combined(with: .opacity)
    }

    private var chipAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy
    }
}

/// One Composer Tray chip: an image thumbnail or a file glyph, its upload
/// status, and a Remove badge. A failed chip opens Retry / Remove on tap; a
/// ready chip offers Copy Path from its context menu.
private struct ComposerTrayChip: View {
    /// How far the Remove badge reaches past the chip's top and trailing edges.
    private static let badgeOverhang: CGFloat = 6
    private static let badgeDiameter: CGFloat = 22
    private static let hitDiameter: CGFloat = 44
    /// How far the Remove control's 44 pt hit area, centered on the badge,
    /// reaches past the chip's top and trailing edges.
    static let removeReach = (hitDiameter - badgeDiameter) / 2 + badgeOverhang

    let tray: ComposerTray
    let item: ComposerTray.Item
    let position: Int
    let count: Int
    let side: CGFloat
    @State private var isShowingFailure = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous)
    }

    var body: some View {
        tile
            .overlay(alignment: .topTrailing) { removeButton }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(item.status.isFailed ? .isButton : [])
            .accessibilityAction {
                if item.status.isFailed { isShowingFailure = true }
            }
            .accessibilityAction(named: "Remove", remove)
            .accessibilityActions {
                if canRetry {
                    Button("Retry") { tray.retry(item.id) }
                }
                if item.status.readyPath != nil {
                    Button("Copy Path", action: copyPath)
                }
            }
            .confirmationDialog(
                item.status.failureMessage ?? "",
                isPresented: Binding(
                    get: { isShowingFailure && item.status.isFailed },
                    set: { isShowingFailure = $0 }),
                titleVisibility: .visible
            ) {
                if canRetry {
                    Button("Retry") { tray.retry(item.id) }
                }
                Button("Remove", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
                    .tint(Brand.Colors.quietAction)
            }
    }

    private var tile: some View {
        content
            .frame(width: side, height: side)
            .opacity(contentOpacity)
            .background(.quaternary, in: shape)
            .clipShape(shape)
            .overlay { statusOverlay }
            .contentShape(shape)
            .onTapGesture {
                if item.status.isFailed { isShowingFailure = true }
            }
            .contentShape(.contextMenuPreview, shape)
            // An empty menu presents nothing: only a ready chip has one.
            .contextMenu {
                if item.status.readyPath != nil {
                    Button("Copy Path", systemImage: "doc.on.doc", action: copyPath)
                    Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: item.status)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let thumbnail = item.thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        case .file(let name):
            VStack(spacing: 2) {
                Image(systemName: "doc")
                    .font(.title3)
                let fileExtension = (name as NSString).pathExtension.uppercased()
                if !fileExtension.isEmpty {
                    Text(fileExtension)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch item.status {
        case .queued:
            Image(systemName: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(.ultraThinMaterial, in: Circle())
        case .staging:
            Group {
                if let fraction = tray.uploadProgress(for: item.id) {
                    ProgressView(value: fraction)
                        .progressViewStyle(ComposerTrayRingStyle())
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 24, height: 24)
            .padding(4)
            .background(.ultraThinMaterial, in: Circle())
        case .failed:
            // System red stays reserved for errors (DESIGN.md).
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Brand.Colors.white, Brand.Colors.danger)
                .accessibilityHidden(true)
        case .ready:
            EmptyView()
        }
    }

    /// A light 22 pt badge drawn over the corner; its circular hit area is
    /// 44 pt across and centered on the badge, so it never reaches the
    /// chip's center, where a failed chip takes its tap. The tray leaves
    /// `removeReach` above and after the chips so none of it is clipped.
    private var removeButton: some View {
        Button {
            // The chip leaves with the press; a light tap says it landed.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            remove()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: Self.badgeDiameter, height: Self.badgeDiameter)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: Self.hitDiameter, height: Self.hitDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Moves the 44 pt frame's center from inside the chip to the badge's
        // center, which overhangs the corner by `badgeOverhang`.
        .offset(
            x: (Self.hitDiameter - Self.badgeDiameter) / 2 + Self.badgeOverhang,
            y: -((Self.hitDiameter - Self.badgeDiameter) / 2 + Self.badgeOverhang))
        // Hidden: the chip's Remove action carries it. Labelled anyway, since
        // the offset badge reaches past the chip's frame and some AX clients
        // still list it; "Remove" beats the symbol's default "Close".
        .accessibilityLabel("Remove")
        .accessibilityHidden(true)
    }

    private func remove() {
        tray.remove(item.id)
    }

    /// Copies the Host path, then says so: the clipboard shows nothing.
    private func copyPath() {
        tray.copyPath(item.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AccessibilityNotification.Announcement("Path copied").post()
    }

    /// Retry is offered only for a retryable failure while the tray is
    /// active: bound to a staging store and not suspended.
    private var canRetry: Bool {
        item.status.isRetryableFailure && tray.canRetry
    }

    private var contentOpacity: Double {
        switch item.status {
        case .queued: 0.5
        case .staging: 0.7
        case .failed: 0.4
        case .ready: 1
        }
    }

    private var accessibilityLabel: String {
        switch item.kind {
        case .image: "Image \(position) of \(count)"
        case .file(let name): "File \(name), \(position) of \(count)"
        }
    }

    private var accessibilityValue: String {
        switch item.status {
        case .queued:
            return "Waiting"
        case .staging:
            guard let fraction = tray.uploadProgress(for: item.id) else { return "Preparing" }
            return "Uploading, \(Int((fraction * 100).rounded())) percent"
        case .failed(let message, _):
            return "Failed. \(message)"
        case .ready:
            return "Ready"
        }
    }
}

/// A determinate ring for an uploading chip; the system circular style draws
/// an indeterminate spinner on iOS whatever the value.
private struct ComposerTrayRingStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: configuration.fractionCompleted ?? 0)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
    }
}
