//
//  UITerminalView+Interaction.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        /// How far a finger may wander and still count as a tap.
        static let tapCandidateSlop: CGFloat = 10
        /// How long a press may last and still count as a tap. Below the
        /// long-press recognizer's 0.5s so a stationary hold never
        /// toggles the keyboard, whether or not the hold starts a
        /// selection. (Waycar patch)
        static let tapCandidateMaxDuration: TimeInterval = 0.35

        override open func touchesBegan(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .began, event: event) {
                return
            }
            super.touchesBegan(touches, with: event)
            #if targetEnvironment(macCatalyst)
                becomeFirstResponder()
            #else
                if momentumScroll.displayLink != nil || isHostMomentumScrolling {
                    // A touch during momentum is a scroll-stop, not a tap.
                    // (Waycar patch: the host's momentum counts too.)
                    stopMomentumScrolling()
                    softwareKeyboard.tapCandidateArmed = false
                } else if let touch = touches.first,
                          // View-scoped on purpose: `allTouches` spans the
                          // whole app, and a finger resting on host chrome
                          // (sidebar, tab bar) must not swallow a tap here.
                          (event?.touches(for: self)?.count ?? touches.count) == 1
                {
                    softwareKeyboard.tapCandidateArmed = true
                    softwareKeyboard.tapCandidateStart = touch.location(in: self)
                    softwareKeyboard.tapCandidateTimestamp = touch.timestamp
                } else {
                    // A second finger means pinch (or some other
                    // multi-touch gesture) — the sequence can no longer
                    // be a tap.
                    softwareKeyboard.tapCandidateArmed = false
                }
            #endif
        }

        override open func touchesMoved(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .moved, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                if softwareKeyboard.tapCandidateArmed, let touch = touches.first {
                    let point = touch.location(in: self)
                    let start = softwareKeyboard.tapCandidateStart
                    if hypot(point.x - start.x, point.y - start.y) > Self.tapCandidateSlop {
                        softwareKeyboard.tapCandidateArmed = false
                    }
                }
            #endif
            super.touchesMoved(touches, with: event)
        }

        override open func touchesEnded(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .ended, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                if softwareKeyboard.tapCandidateArmed, let touch = touches.first {
                    softwareKeyboard.tapCandidateArmed = false
                    let duration = touch.timestamp - softwareKeyboard.tapCandidateTimestamp
                    if duration <= Self.tapCandidateMaxDuration {
                        let location = touch.location(in: self)
                        // A selection on screen owns the tap: the menu on
                        // it, a dismissal anywhere else. (Waycar patch)
                        if handleTapWithSelection(at: location) {
                            super.touchesEnded(touches, with: event)
                            return
                        }
                        TerminalDebugLog.log(
                            .input,
                            "tap toggles keyboard visible=\(softwareKeyboard.isVisible) duration=\(String(format: "%.3f", duration))"
                        )
                        // The tap is a click first and a keyboard toggle
                        // second, in both directions: a TUI tracking the
                        // mouse gets its press before the resize the
                        // keyboard causes, and the shell sees the
                        // click-to-move at its prompt either way.
                        if sendsTapClicksToSurface {
                            sendTapClick(at: location)
                        }
                        // Overridable: a host keyboard lock overrides
                        // `toggleSoftwareKeyboard()` to swallow the toggle;
                        // the click above still lands either way.
                        toggleSoftwareKeyboard()
                    }
                }
            #endif
            super.touchesEnded(touches, with: event)
        }

        override open func touchesCancelled(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .cancelled, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                softwareKeyboard.tapCandidateArmed = false
            #endif
            super.touchesCancelled(touches, with: event)
        }

        func setupPlatformInput() {
            addInteraction(selectionContextMenuInteraction)
            setupDropInput()
            addGestureRecognizer(TerminalScrollWheelGestureRecognizer(
                target: self,
                action: #selector(handleScrollWheelGesture(_:))
            ))
            let pointerInteraction = UIPointerInteraction(delegate: self)
            addInteraction(pointerInteraction)
            pointer.pointerInteraction = pointerInteraction
            let hover = UIHoverGestureRecognizer(
                target: self,
                action: #selector(handlePointerHover(_:))
            )
            hover.cancelsTouchesInView = false
            hover.delegate = self
            addGestureRecognizer(hover)
            pointer.hoverRecognizer = hover
            #if !targetEnvironment(macCatalyst)
                setupTouchScrollInput()
            #endif
        }

        #if !targetEnvironment(macCatalyst)
            func setupTouchScrollInput() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleTouchScrollGesture(_:))
                )
                gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                gesture.maximumNumberOfTouches = 1
                addGestureRecognizer(gesture)

                // Starts a touch selection (+TouchSelection). (Waycar patch)
                let longPress = UILongPressGestureRecognizer(
                    target: self,
                    action: #selector(handleLongPressForSelection(_:))
                )
                longPress.minimumPressDuration = 0.5
                longPress.allowableMovement = 10
                longPress.numberOfTouchesRequired = 1
                longPress.numberOfTapsRequired = 0
                longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                longPress.cancelsTouchesInView = false
                longPress.delegate = self
                addGestureRecognizer(longPress)

                setupIndirectPointerSelectionGesture()
                setupPinchZoomGesture()
            }

            /// One left click at `point`, the way a finger tap reaches the
            /// terminal: a press and a release with no drag between them.
            /// Any pointer-drag selection is over by definition — ghostty
            /// clears its selection on the click.
            func sendTapClick(at point: CGPoint) {
                guard let surface else { return }
                let mods = pointerMods()
                sendPointerPosition(at: point)
                surface.sendMouseButton(
                    state: GHOSTTY_MOUSE_PRESS,
                    button: GHOSTTY_MOUSE_LEFT,
                    mods: mods
                )
                surface.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: GHOSTTY_MOUSE_LEFT,
                    mods: mods
                )
                pointer.lastSelectionRect = nil
                pointer.selectionStartPoint = nil
            }
        #endif
    }
#endif
