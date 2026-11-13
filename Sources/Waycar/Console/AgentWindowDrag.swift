import SwiftUI
import UIKit

/// Lets a Console row be dragged out as a new window on iPad: the row vends
/// its Agent's user activity, and dropping it at the screen edge asks the
/// system for a window restored to that Agent. Off where multiple windows
/// are unsupported, so an iPhone row drags nowhere.
///
/// `isAvailable` (the device supports multiple windows) never changes for a
/// row, so it alone picks the view's structure. `isEnabled` pauses the drag
/// (Selection Mode) by switching off the row cell's drag interactions,
/// leaving the structure alone: swapping the `.onDrag` branch would rebuild
/// every row and cut short their checkbox and slide animations.
struct AgentWindowDrag: ViewModifier {
    let route: AgentRoute
    let title: String
    let isAvailable: Bool
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isAvailable {
            content
                .onDrag {
                    let provider = NSItemProvider()
                    provider.registerObject(route.makeUserActivity(title: title), visibility: .all)
                    return provider
                }
                .background(RowDragInteractionGate(isEnabled: isEnabled))
        } else {
            content
        }
    }
}

/// Switches the enclosing List cell's drag interactions off while
/// `isEnabled` is false, and back on once it is true again. Only the
/// interactions it switched off are switched back on.
private struct RowDragInteractionGate: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> GateView {
        let view = GateView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: GateView, context: Context) {
        uiView.isGateEnabled = isEnabled
    }

    final class GateView: UIView {
        var isGateEnabled = true {
            didSet {
                guard isGateEnabled != oldValue else { return }
                scheduleApply()
            }
        }
        private var disabled: [WeakInteraction] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // A cell leaving the window may be reused for another row: hand
            // its interactions back now rather than leave them off.
            if window == nil {
                restore()
            } else {
                scheduleApply()
            }
        }

        /// A beat later: the cell hosts this view only once SwiftUI has
        /// placed it.
        private func scheduleApply() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard !isGateEnabled, window != nil else {
                restore()
                return
            }
            guard let cell = enclosingCell() else { return }
            var stack: [UIView] = [cell]
            while let node = stack.popLast() {
                for case let drag as UIDragInteraction in node.interactions where drag.isEnabled {
                    drag.isEnabled = false
                    disabled.append(WeakInteraction(interaction: drag))
                }
                stack.append(contentsOf: node.subviews)
            }
        }

        private func enclosingCell() -> UIView? {
            var node = superview
            while let view = node {
                if view is UICollectionViewCell || view is UITableViewCell { return view }
                node = view.superview
            }
            return nil
        }

        private func restore() {
            for entry in disabled { entry.interaction?.isEnabled = true }
            disabled.removeAll()
        }
    }

    private struct WeakInteraction {
        weak var interaction: UIDragInteraction?
    }
}
