import CoreImage
import IOSurface
import SwiftUI
import UIKit

/// The last frame a terminal painted, kept on screen while its pipeline is
/// replaced (#21).
///
/// A replacement pipeline gets a new surface, and a new surface is blank until
/// its attach paints. Rather than a blank terminal under the Ignition loader
/// (#96), the screen keeps a render-server copy of the outgoing surface:
/// `snapshotView(afterScreenUpdates:)` carries Ghostty's Metal content, where
/// `drawHierarchy` draws black. Only the copy survives the replacement; the
/// outgoing Ghostty view itself is held weakly and must go (#242).
///
/// Owned by the Agent detail rather than its terminal screen: a return from a
/// suspension swaps in a whole new Attach store and screen, and the frame has
/// to outlive that screen too.
@MainActor
@Observable
final class TerminalLastFrame {
    @MainActor
    struct Snapshot {
        let view: UIView
        let size: CGSize

        /// A render-server copy of `surface` as it stands on screen, or nil
        /// when it is not showing anything.
        static func capture(of surface: UIView?) -> Snapshot? {
            guard let surface, surface.window != nil, !surface.bounds.isEmpty,
                let copy = surface.snapshotView(afterScreenUpdates: false)
            else { return nil }
            copy.frame = CGRect(origin: .zero, size: surface.bounds.size)
            copy.isUserInteractionEnabled = false
            copy.accessibilityElementsHidden = true
            return Snapshot(view: copy, size: surface.bounds.size)
        }

        /// An Agent's cached frame from an earlier visit (`AgentLastFrameStore`),
        /// drawn at the terminal size it was taken at.
        static func cached(_ frame: AgentLastFrameStore.Frame) -> Snapshot {
            let view = UIImageView(image: frame.image)
            view.contentMode = .scaleToFill
            view.frame = CGRect(origin: .zero, size: frame.size)
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            return Snapshot(view: view, size: frame.size)
        }
    }

    /// The surface whose attach has painted on this screen, and the view
    /// showing it. No other surface holds a frame worth keeping: one that
    /// never went live is blank.
    private var machine = TerminalLastFrameMachine()
    var paintedSurface: TerminalSurfaceID? { machine.paintedSurface }
    @ObservationIgnored private weak var paintedView: UIView?
    private(set) var snapshot: Snapshot?

    /// Whether the screen showing `surface` has a painted frame to keep up
    /// while it connects: the surface's own, or a copy of its predecessor's.
    func hasFrame(for surface: TerminalSurfaceID) -> Bool {
        machine.hasFrame(for: surface)
    }

    /// The view drawing `surface`'s live frame, when `surface` is the one
    /// that painted here.
    func paintedTerminal(of surface: TerminalSurfaceID) -> UIView? {
        paintedSurface == surface ? paintedView : nil
    }

    /// Puts up `cached`, an Agent's frame from an earlier visit, when the
    /// screen holds no frame of its own: nothing painted here yet and no copy
    /// held. True when it went up; the screen's own frame always wins.
    @discardableResult
    func offer(_ cached: Snapshot) -> Bool {
        send(.offer, snapshot: cached).contains(.storeSnapshot)
    }

    /// `surface`'s attach is live on `view`: its own frame now stands, so the
    /// copy of the previous one goes.
    func surfaceDidPaint(_ surface: TerminalSurfaceID, view: UIView?) {
        send(.paint(surface, hasView: view != nil), view: view)
    }

    /// `surface`'s pipeline or screen is about to be replaced. A painted
    /// surface leaves the copy `capture` takes of its view behind. Any other
    /// retirement keeps the copy already held: a replacement that never
    /// painted leaves the older frame the latest one there is.
    func surfaceWillRetire(
        _ surface: TerminalSurfaceID,
        capture: @MainActor (UIView?) -> Snapshot? = Snapshot.capture(of:)
    ) {
        guard paintedSurface == surface else { return }
        let captured = capture(paintedView)
        send(.retired(hasSnapshot: captured != nil), snapshot: captured)
    }

    /// The frame no longer stands for what the terminal will show: its attach
    /// ended, its Host became unavailable, or another window took the
    /// terminal over. Nothing held may come back later as the last frame.
    func discard() {
        send(.discard)
    }

    @discardableResult
    private func send(
        _ event: TerminalLastFrameMachine.Event,
        snapshot offered: Snapshot? = nil, view: UIView? = nil
    ) -> [TerminalLastFrameMachine.Effect] {
        // Mutating an observed property notifies even when handle is a no-op.
        // Repeated live-status paints only refresh the weak resource, as before.
        var next = machine
        let effects = next.handle(event)
        if next.state != machine.state { machine = next }
        for effect in effects {
            switch effect {
            case .storeSnapshot: snapshot = offered
            case .clearSnapshot:
                if snapshot != nil { snapshot = nil }
            case .storePaintedView: paintedView = view
            case .clearPaintedView: paintedView = nil
            }
        }
        return effects
    }
}

/// A bitmap of what a Ghostty terminal shows, for the per-Agent frame cache.
///
/// Ghostty draws with Metal into an IOSurface that its `IOSurfaceLayer`
/// sublayer shows as layer contents, which `drawHierarchy` draws black (see
/// `TerminalLastFrame`). The presented IOSurface is read directly instead:
/// it holds the last frame the renderer finished, at the surface's pixel
/// size.
enum TerminalFrameCapture {
    /// Pixels per point the stored copy keeps at most: enough to read the
    /// dimmed text, a fraction of a 3x screen's bytes.
    static let maxScale: CGFloat = 2

    /// No colour matching: the surface's bytes are drawn as the sRGB values
    /// Ghostty rendered them as.
    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
    ])

    /// The terminal's presented frame, scaled to at most `maxScale` pixels
    /// per point, or nil when it has no rendered surface to read.
    @MainActor
    static func image(of terminal: UIView, maxScale: CGFloat = maxScale) -> CGImage? {
        let size = terminal.bounds.size
        guard size.width > 0, size.height > 0, let surface = presentedSurface(of: terminal)
        else { return nil }
        let source = CIImage(ioSurface: surface, options: [.colorSpace: NSNull()])
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, maxScale * size.width / extent.width)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = scaled.extent.integral
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.createCGImage(scaled, from: rect, format: .BGRA8, colorSpace: sRGB)
    }

    /// The IOSurface Ghostty's content layer presents, if it has one.
    @MainActor
    static func presentedSurface(of terminal: UIView) -> IOSurface? {
        for sublayer in (terminal.layer.sublayers ?? []).reversed()
        where NSStringFromClass(type(of: sublayer)) == "IOSurfaceLayer" {
            guard let contents = sublayer.contents else { continue }
            let object = contents as CFTypeRef
            guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { continue }
            return unsafeDowncast(object, to: IOSurface.self)
        }
        return nil
    }
}

/// Hosts a `TerminalLastFrame` copy in the terminal's place. The screen can
/// change size meanwhile — a reclaimed keyboard, a rotation — so the copy
/// keeps its aspect ratio: never enlarged, shrunk only to fit the width, and
/// pinned bottom-leading so the prompt and cursor rows stay in view, with
/// whatever no longer fits clipped away at the top.
struct TerminalLastFrameView: UIViewRepresentable {
    let snapshot: TerminalLastFrame.Snapshot

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        container.show(snapshot)
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        container.show(snapshot)
    }

    final class Container: UIView {
        private var snapshot: TerminalLastFrame.Snapshot?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            clipsToBounds = true
        }

        func show(_ snapshot: TerminalLastFrame.Snapshot) {
            guard snapshot.view !== self.snapshot?.view else { return }
            self.snapshot?.view.removeFromSuperview()
            self.snapshot = snapshot
            addSubview(snapshot.view)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let snapshot, snapshot.size.width > 0, snapshot.size.height > 0 else { return }
            let scale = min(1, bounds.width / snapshot.size.width)
            snapshot.view.transform = .identity
            snapshot.view.frame = CGRect(origin: .zero, size: snapshot.size)
            snapshot.view.transform = CGAffineTransform(scaleX: scale, y: scale)
            snapshot.view.center = CGPoint(
                x: snapshot.size.width * scale / 2,
                y: bounds.height - snapshot.size.height * scale / 2)
        }
    }
}
