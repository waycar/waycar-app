//
//  TerminalSelectionHandleView.swift
//  libghostty-spm (Waycar patch)
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit

    /// One end of a touch selection, drawn the way UIKit's text views draw
    /// theirs: a caret-height bar in the tint colour with a round knob above
    /// the start or below the end. The knob is what the finger grabs, so the
    /// view's touch area reaches well past its drawing.
    ///
    /// Touches that land here never reach the terminal view's own tap
    /// handling: the overrides below do not forward them up the responder
    /// chain, and the terminal's recognizers whose delegate is the terminal
    /// refuse them (`gestureRecognizer(_:shouldReceive:)`). Its delegate-less
    /// scroll pan and pinch still see them; the handle's own zero-delay
    /// press recognizes first.
    final class TerminalSelectionHandleView: UIView {
        let handle: UITerminalView.TouchSelectionHandle
        /// The selection's other handle. On a short selection the two touch
        /// areas overlap, and the one whose knob is nearer takes the touch.
        weak var sibling: TerminalSelectionHandleView?

        private let bar = UIView()
        private let knob = UIView()

        static let knobDiameter: CGFloat = 11
        static let barWidth: CGFloat = 2
        /// Apple's minimum comfortable touch target.
        static let touchSize: CGFloat = 44

        init(handle: UITerminalView.TouchSelectionHandle) {
            self.handle = handle
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            // Above ghostty's content layer, which it adds to the terminal
            // view's layer after any subview may already exist.
            layer.zPosition = 1
            bar.isUserInteractionEnabled = false
            knob.isUserInteractionEnabled = false
            knob.layer.cornerRadius = Self.knobDiameter / 2
            addSubview(bar)
            addSubview(knob)
            isAccessibilityElement = true
            accessibilityLabel = handle == .start ? "Selection start" : "Selection end"
            tintColorDidChange()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            bar.backgroundColor = tintColor
            knob.backgroundColor = tintColor
        }

        /// Places the handle on the selection's edge: `edge` is the x of that
        /// edge, `line` the row it sits on. The knob hangs above the start and
        /// below the end unless that would leave `limits`, the terminal's
        /// bounds, which clip it and refuse touches outside: on the top or
        /// bottom row it hangs on the other side of the bar.
        func place(edge: CGFloat, line: CGRect, within limits: CGRect) {
            let knob = Self.knobDiameter
            let height = line.height + knob
            let knobAbove = switch handle {
            case .start: line.minY - knob >= limits.minY
            case .end: line.maxY + knob > limits.maxY
            }
            frame = CGRect(
                x: edge - knob / 2,
                y: knobAbove ? line.minY - knob : line.minY,
                width: knob,
                height: height
            )
            let barX = (knob - Self.barWidth) / 2
            if knobAbove {
                self.knob.frame = CGRect(x: 0, y: 0, width: knob, height: knob)
                bar.frame = CGRect(x: barX, y: knob / 2, width: Self.barWidth, height: height - knob / 2)
            } else {
                self.knob.frame = CGRect(x: 0, y: height - knob, width: knob, height: knob)
                bar.frame = CGRect(x: barX, y: 0, width: Self.barWidth, height: height - knob / 2)
            }
        }

        /// The knob's centre, in this view's coordinates.
        var knobCenter: CGPoint {
            knob.center
        }

        var touchArea: CGRect {
            let dx = max(0, (Self.touchSize - bounds.width) / 2)
            let dy = max(0, (Self.touchSize - bounds.height) / 2)
            return bounds.insetBy(dx: -dx, dy: -dy)
        }

        override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
            guard touchArea.contains(point) else { return false }
            guard let sibling, !sibling.isHidden else { return true }
            let there = convert(point, to: sibling)
            guard sibling.touchArea.contains(there) else { return true }
            // Both claim it: the nearer knob takes it. A tie goes to the end
            // handle, which hit testing asks first.
            return hypot(point.x - knobCenter.x, point.y - knobCenter.y)
                <= hypot(there.x - sibling.knobCenter.x, there.y - sibling.knobCenter.y)
        }

        override func touchesBegan(_: Set<UITouch>, with _: UIEvent?) {}
        override func touchesMoved(_: Set<UITouch>, with _: UIEvent?) {}
        override func touchesEnded(_: Set<UITouch>, with _: UIEvent?) {}
        override func touchesCancelled(_: Set<UITouch>, with _: UIEvent?) {}
    }
#endif
