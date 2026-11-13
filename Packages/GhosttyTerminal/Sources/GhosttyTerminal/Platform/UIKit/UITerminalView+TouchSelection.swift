//
//  UITerminalView+TouchSelection.swift
//  libghostty-spm (Waycar patch)
//
//  Native touch selection on ghostty's own selection, and the link hit test
//  a tap uses. Upstream answered a long press by handing the host a plain-text
//  snapshot of the viewport to present somewhere else; here the selection is
//  made, drawn, extended and copied where the text is.
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyKit
    import UIKit

    /// The link under a point: its target, and whether that target is the
    /// very text drawn there. (Waycar patch)
    public struct TerminalLinkHit: Equatable, Sendable {
        public let target: String
        public let isVisibleText: Bool

        public init(target: String, isVisibleText: Bool) {
            self.target = target
            self.isVisibleText = isVisibleText
        }
    }

    /// The path characters drawn around a point, carried across row breaks
    /// Ghostty cannot see as wraps; see `UITerminalView.pathRun(at:)`.
    /// (Waycar patch)
    public struct TerminalPathRun: Equatable, Sendable {
        /// Where a row's part of a run lies on the grid, in cells, a
        /// character a cell, so a host can judge a break by where it falls.
        public struct RowLayout: Equatable, Sendable {
            /// The row's text from ``textStart`` on.
            public let text: String
            /// The cell the row's text starts in: past its indentation and
            /// a frame column opening it — on a framed row, its frame's.
            public let textStart: Int
            /// The cell the row's word ending with its part starts in: past
            /// the last blank before it, so a bracket or quote opening the
            /// word is part of it.
            public let wordStart: Int
            /// The cell just past the row's part.
            public let end: Int
            /// The cell just past the last the row's text can reach: the
            /// grid's width, or, where a frame column past the part fills
            /// the grid's last cell, that column's.
            public let edge: Int
            /// Whether the part ends within
            /// ``UITerminalView/pathRunEdgeSlack`` cells of ``edge``.
            public let endsNearEdge: Bool

            public init(text: String, textStart: Int, wordStart: Int, end: Int, edge: Int, endsNearEdge: Bool) {
                self.text = text
                self.textStart = textStart
                self.wordStart = wordStart
                self.end = end
                self.edge = edge
                self.endsNearEdge = endsNearEdge
            }
        }

        /// The whole run, its rows joined without a break.
        public let text: String
        /// The run's part on each row it spans, top to bottom, so a host
        /// can judge each break on its own.
        public let rows: [String]
        /// Where each of ``rows`` lies on the grid.
        public let layouts: [RowLayout]
        /// Which of ``rows`` is the point's own.
        public let tappedRow: Int

        public init(rows: [String], layouts: [RowLayout], tappedRow: Int) {
            text = rows.joined()
            self.rows = rows
            self.layouts = layouts
            self.tappedRow = tappedRow
        }

        /// The part of the run drawn on the point's own row.
        public var rowText: String { rows[tappedRow] }

        /// Whether the run starts on an earlier row: the point's row holds a
        /// continuation, which may begin mid-word (`hot.png` of `/s|hot.png`).
        public var continuesFromPreviousRow: Bool { tappedRow > 0 }

        /// Whether the run continues onto another row.
        public var spansRows: Bool { rows.count > 1 }
    }

    /// A zero-based cell of the visible grid.
    public struct TerminalCellPosition: Hashable, Comparable, Sendable {
        public var column: Int
        public var row: Int

        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }

        /// Reading order: row first, then column.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.row, lhs.column) < (rhs.row, rhs.column)
        }
    }

    /// Where ghostty draws the grid inside the view, in points.
    struct TerminalCellGeometry: Equatable {
        let origin: CGPoint
        let cellSize: CGSize
        let columns: Int
        let rows: Int

        init?(metrics: TerminalGridMetrics, scale: CGFloat) {
            guard scale > 0, metrics.columns > 0, metrics.rows > 0,
                  metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0
            else { return nil }
            // ghostty's default `window-padding-x/y = 2` is points at 72 dpi,
            // drawn at 96 dpi and floored to whole pixels (Surface.zig
            // `scaledPadding`). With padding balance off the leftover sits
            // right and bottom, so the grid's top-left is this fixed inset.
            let padding = (2 * 96 / 72 * scale).rounded(.down) / scale
            origin = CGPoint(x: padding, y: padding)
            cellSize = CGSize(
                width: CGFloat(metrics.cellWidthPixels) / scale,
                height: CGFloat(metrics.cellHeightPixels) / scale
            )
            columns = Int(metrics.columns)
            rows = Int(metrics.rows)
        }

        /// The cell under `point`, clamped to the grid.
        func cell(at point: CGPoint) -> TerminalCellPosition {
            let column = Int(((point.x - origin.x) / cellSize.width).rounded(.down))
            let row = Int(((point.y - origin.y) / cellSize.height).rounded(.down))
            return TerminalCellPosition(
                column: min(max(column, 0), columns - 1),
                row: min(max(row, 0), rows - 1)
            )
        }

        func rect(for cell: TerminalCellPosition) -> CGRect {
            CGRect(
                x: origin.x + CGFloat(cell.column) * cellSize.width,
                y: origin.y + CGFloat(cell.row) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            )
        }

        /// A point inside `cell`, as fractions of its width and height.
        func point(in cell: TerminalCellPosition, x: CGFloat, y: CGFloat) -> CGPoint {
            let rect = rect(for: cell)
            return CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        /// The rectangle the cells from `start` through `end` cover.
        func bounds(from start: TerminalCellPosition, to end: TerminalCellPosition) -> CGRect {
            let first = rect(for: start)
            let last = rect(for: end)
            if start.row == end.row {
                return first.union(last)
            }
            let gridWidth = cellSize.width * CGFloat(columns)
            return CGRect(
                x: origin.x,
                y: first.minY,
                width: gridWidth,
                height: last.maxY - first.minY
            )
        }
    }

    extension UITerminalView {
        public enum TouchSelectionHandle: Sendable {
            case start
            case end
        }

        /// Touch selection state; behavior lives in +TouchSelection.
        struct TouchSelectionState {
            enum Drag {
                /// The long press still holds its second click: moving the
                /// finger extends the word selection it made.
                case longPress
                /// A handle is being dragged. The opposite end of the
                /// selection is the pressed anchor; `grabOffset` keeps the
                /// knob under the finger instead of snapping it to the tip.
                case handle(TouchSelectionHandle, anchor: TerminalCellPosition, grabOffset: CGSize)
            }

            /// The handles and menu belong to ghostty's current selection.
            var isShown = false
            /// A handle touched but not yet moved: a tap unless it drags.
            var handlePress: (handle: TouchSelectionHandle, point: CGPoint)?
            var drag: Drag?
            var lastDragPoint: CGPoint?
            /// Where and when the last synthesized left press landed, so the
            /// next one can stay out of ghostty's double-click reach.
            var lastPress: (point: CGPoint, time: CFTimeInterval)?
            var startHandle: TerminalSelectionHandleView?
            var endHandle: TerminalSelectionHandleView?
            var isMenuVisible = false
            var layoutIsScheduled = false
            var linkUnhover: Task<Void, Never>?
        }

        static let touchSelectionMenuIdentifier = "terminal.touch-selection" as NSString

        /// Held (with shift) for the length of every synthesized gesture.
        /// ghostty sends a program that captured the mouse a motion report for
        /// every pointer move while no button is down, shift or not; with a
        /// button down, shift keeps the whole gesture local. Button 10 has no
        /// action of its own in ghostty, unlike right (word select) or middle
        /// (paste). Not 11: ghostty's per-button state array stops at 10, so
        /// an 11 is written past its end.
        static let selectionGuardButton = GHOSTTY_MOUSE_TEN

        /// ghostty counts a press as a double or triple click when it lands
        /// within one cell width of the previous press inside the platform
        /// click interval (500 ms on iOS). Presses are kept out of that reach
        /// for a little longer than the interval.
        static let selectionRepeatWindow: CFTimeInterval = 0.75

        // MARK: - Geometry

        func touchCellGeometry() -> TerminalCellGeometry? {
            guard let metrics = surface?.size() else { return nil }
            return TerminalCellGeometry(metrics: metrics, scale: resolvedDisplayScale())
        }

        /// The selection's first and last visible cells, or nil when there is
        /// no selection or none of it is on screen. Ghostty clamps an end that
        /// is off screen to the viewport's first or last cell; such an end is
        /// flagged, since it is not where the selection really ends.
        func touchSelectionRange() -> TouchSelectionRange? {
            guard let surface,
                  let geometry = touchCellGeometry(),
                  let selection = surface.readSelectionResult(),
                  selection.isInViewport
            else { return nil }
            let columns = geometry.columns
            let first = Int(selection.offsetStart)
            let last = first + Int(selection.offsetLength)
            let lastRow = geometry.rows - 1
            let start = TerminalCellPosition(
                column: first % columns,
                row: min(first / columns, lastRow)
            )
            let end = TerminalCellPosition(
                column: last % columns,
                row: min(last / columns, lastRow)
            )
            // The visible cells hold the whole selection unless an end is
            // clamped; which one, the clamp position tells.
            let visible = surface.readViewportText(
                from: (start.column, start.row), to: (end.column, end.row))
            let isWhole = visible == selection.text
            return TouchSelectionRange(
                start: start,
                end: end,
                startIsClamped: !isWhole && start == TerminalCellPosition(column: 0, row: 0),
                endIsClamped: !isWhole
                    && end == TerminalCellPosition(column: columns - 1, row: lastRow)
            )
        }

        struct TouchSelectionRange {
            let start: TerminalCellPosition
            let end: TerminalCellPosition
            let startIsClamped: Bool
            let endIsClamped: Bool
        }

        /// The area the selection covers on screen.
        func touchSelectionBounds() -> CGRect? {
            guard let geometry = touchCellGeometry(),
                  let range = touchSelectionRange()
            else { return nil }
            return geometry.bounds(from: range.start, to: range.end)
        }

        /// Whether ghostty holds a selection, touch-made or not.
        public var hasSelection: Bool {
            surface?.hasSelection() ?? false
        }

        /// Where the visible selection handles take touches, in this view's
        /// coordinates; empty while no handle is up.
        public var touchSelectionHandleAreas: [CGRect] {
            guard touchSelection.isShown else { return [] }
            return [touchSelection.startHandle, touchSelection.endHandle].compactMap { handle in
                guard let handle, !handle.isHidden else { return nil }
                return handle.convert(handle.touchArea, to: self)
            }
        }

        // MARK: - Long Press

        @objc func handleLongPressForSelection(
            _ gesture: UILongPressGestureRecognizer
        ) {
            let point = gesture.location(in: self)
            switch gesture.state {
            case .began:
                softwareKeyboard.tapCandidateArmed = false
                beginTouchSelection(at: point)
            case .changed:
                moveTouchSelectionDrag(to: point)
            case .ended:
                finishTouchSelectionDrag(presentingMenu: true)
            case .cancelled, .failed:
                finishTouchSelectionDrag(presentingMenu: false)
            default:
                break
            }
        }

        /// Selects the word under `point` — or the whole URL or path, which
        /// ghostty's double click recognizes — and keeps the second click
        /// down so a drag extends the selection word by word.
        func beginTouchSelection(at point: CGPoint) {
            guard let surface, let geometry = touchCellGeometry() else { return }
            stopMomentumScrolling()
            touchSelectionWillBegin()
            cancelTouchSelectionDrag()
            dismissTouchSelectionMenu()
            surface.clearSelection(restoringPreedit: inputHandler.markedText)

            let press = selectionPressPoint(in: geometry.cell(at: point), x: 0.5, geometry: geometry)
            beginSelectionGesture(on: surface)
            sendSelectionButton(GHOSTTY_MOUSE_PRESS, at: press, on: surface)
            sendSelectionButton(GHOSTTY_MOUSE_RELEASE, at: press, on: surface)
            sendSelectionButton(GHOSTTY_MOUSE_PRESS, at: press, on: surface)
            touchSelection.drag = .longPress
            touchSelection.lastDragPoint = press
            touchSelection.isShown = true
            layoutTouchSelection()

            TerminalDebugLog.log(
                .input,
                "touch selection began point=\(NSCoder.string(for: point)) selection=\(surface.hasSelection())"
            )
            #if !os(visionOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        }

        // MARK: - Handles

        /// How far a finger on a handle moves before it drags. Less is a tap,
        /// which goes to the selection as any tap does: a handle's touch area
        /// covers most of a short selection.
        static let handleDragSlop: CGFloat = 4

        @objc func handleSelectionHandleDrag(_ gesture: UILongPressGestureRecognizer) {
            guard let handleView = gesture.view as? TerminalSelectionHandleView else { return }
            let point = gesture.location(in: self)
            switch gesture.state {
            case .began:
                touchSelection.handlePress = (handleView.handle, point)
            case .changed:
                if let press = touchSelection.handlePress {
                    guard hypot(point.x - press.point.x, point.y - press.point.y)
                        > Self.handleDragSlop
                    else { return }
                    touchSelection.handlePress = nil
                    beginHandleDrag(press.handle, at: press.point)
                }
                moveTouchSelectionDrag(to: point)
            case .ended:
                if touchSelection.handlePress != nil {
                    touchSelection.handlePress = nil
                    _ = handleTapWithSelection(at: point)
                } else {
                    finishTouchSelectionDrag(presentingMenu: true)
                }
            case .cancelled, .failed:
                touchSelection.handlePress = nil
                finishTouchSelectionDrag(presentingMenu: true)
            default:
                break
            }
        }

        /// Re-presses at the selection's other end and drags this one, which
        /// is how a mouse moves one end of a selection in ghostty.
        func beginHandleDrag(_ handle: TouchSelectionHandle, at finger: CGPoint) {
            // A clamped end is not the selection's end. The re-press lands
            // on the other end, so either end clamped would cut off the part
            // scrolled out of view: the anchor if it is clamped, and the
            // moving end's hidden part once the drag starts.
            guard let surface,
                  let geometry = touchCellGeometry(),
                  let range = touchSelectionRange(),
                  !range.startIsClamped, !range.endIsClamped
            else { return }
            dismissTouchSelectionMenu()
            cancelTouchSelectionDrag()

            let anchor = handle == .start ? range.end : range.start
            let moving = handle == .start ? range.start : range.end
            let grabbed = Self.handleDragPoint(for: handle, in: moving, geometry: geometry)
            let grabOffset = CGSize(width: finger.x - grabbed.x, height: finger.y - grabbed.y)

            surface.clearSelection(restoringPreedit: inputHandler.markedText)
            beginSelectionGesture(on: surface)
            // ghostty includes a pressed cell only when the drag moves away
            // from the side of it that was pressed: the far side of the
            // anchor, so the anchor cell stays selected.
            let anchorPoint = selectionPressPoint(
                in: anchor,
                x: handle == .start ? 0.9 : 0.1,
                geometry: geometry
            )
            sendSelectionButton(GHOSTTY_MOUSE_PRESS, at: anchorPoint, on: surface)
            touchSelection.drag = .handle(handle, anchor: anchor, grabOffset: grabOffset)
            moveTouchSelectionDrag(to: finger)
        }

        /// Where a dragged end presses into its cell: just inside the cell's
        /// outer side, on the near side of ghostty's 60% inclusion threshold
        /// for that direction, so the cell is always part of the selection.
        static func handleDragPoint(
            for handle: TouchSelectionHandle,
            in cell: TerminalCellPosition,
            geometry: TerminalCellGeometry
        ) -> CGPoint {
            geometry.point(in: cell, x: handle == .start ? 0.1 : 0.9, y: 0.5)
        }

        func moveTouchSelectionDrag(to finger: CGPoint) {
            guard let drag = touchSelection.drag,
                  let surface,
                  let geometry = touchCellGeometry()
            else { return }
            let target: CGPoint
            switch drag {
            case .longPress:
                target = CGPoint(x: max(finger.x, 0), y: finger.y)
            case let .handle(handle, anchor, grabOffset):
                let aim = CGPoint(x: finger.x - grabOffset.width, y: finger.y - grabOffset.height)
                var cell = geometry.cell(at: aim)
                // The ends never cross: past the anchor, a handle stops at it.
                cell = handle == .start ? min(cell, anchor) : max(cell, anchor)
                target = Self.handleDragPoint(for: handle, in: cell, geometry: geometry)
            }
            surface.sendMousePos(x: Double(target.x), y: Double(target.y), modifiers: .shift)
            touchSelection.lastDragPoint = target
            layoutTouchSelection()
        }

        func finishTouchSelectionDrag(presentingMenu: Bool) {
            guard touchSelection.drag != nil else { return }
            cancelTouchSelectionDrag()
            guard hasSelection else {
                endTouchSelection()
                return
            }
            touchSelection.isShown = true
            layoutTouchSelection()
            if presentingMenu {
                presentTouchSelectionMenu()
            }
        }

        /// Lets go of any synthesized button still down. The selection it
        /// made stays.
        func cancelTouchSelectionDrag() {
            guard touchSelection.drag != nil else { return }
            touchSelection.drag = nil
            guard let surface else { return }
            if let point = touchSelection.lastDragPoint {
                surface.sendMousePos(x: Double(point.x), y: Double(point.y), modifiers: .shift)
            }
            surface.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_LEFT,
                modifiers: .shift
            )
            endSelectionGesture(on: surface)
        }

        // MARK: - Synthesized Input

        func beginSelectionGesture(on surface: TerminalSurface) {
            surface.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: Self.selectionGuardButton,
                modifiers: .shift
            )
        }

        func endSelectionGesture(on surface: TerminalSurface) {
            surface.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: Self.selectionGuardButton,
                modifiers: .shift
            )
        }

        /// Shift makes ghostty select even while a program has captured the
        /// mouse; the host configures `mouse-shift-capture = never` so no
        /// program can take that back.
        func sendSelectionButton(
            _ state: ghostty_input_mouse_state_e,
            at point: CGPoint,
            on surface: TerminalSurface
        ) {
            surface.sendMousePos(x: Double(point.x), y: Double(point.y), modifiers: .shift)
            surface.sendMouseButton(state: state, button: GHOSTTY_MOUSE_LEFT, modifiers: .shift)
            if state == GHOSTTY_MOUSE_PRESS {
                touchSelection.lastPress = (point, CACurrentMediaTime())
            }
        }

        /// A press point in `cell` at fraction `x` of its width, placed high
        /// or low in the cell so that it is more than a cell width from a
        /// recent press — ghostty would otherwise take it for a double click.
        /// A cell is always taller than it is wide, so one of the two works.
        func selectionPressPoint(
            in cell: TerminalCellPosition,
            x: CGFloat,
            geometry: TerminalCellGeometry
        ) -> CGPoint {
            let high = geometry.point(in: cell, x: x, y: 0.15)
            guard let last = touchSelection.lastPress,
                  CACurrentMediaTime() - last.time < Self.selectionRepeatWindow
            else { return high }
            let low = geometry.point(in: cell, x: x, y: 0.85)
            let highDistance = hypot(high.x - last.point.x, high.y - last.point.y)
            let lowDistance = hypot(low.x - last.point.x, low.y - last.point.y)
            return highDistance >= lowDistance ? high : low
        }

        // MARK: - Presentation

        /// Places the handles on the selection, hiding them while it is off
        /// screen and ending the touch selection once ghostty has dropped it
        /// (typing, a new screen, a click).
        func layoutTouchSelection() {
            guard touchSelection.isShown else {
                setTouchSelectionHandlesHidden(true)
                return
            }
            defer { touchSelectionHandlesDidChange() }
            guard let geometry = touchCellGeometry(),
                  let range = touchSelectionRange()
            else {
                if hasSelection {
                    setTouchSelectionHandlesHidden(true)
                } else {
                    endTouchSelection()
                }
                return
            }
            let (startHandle, endHandle) = touchSelectionHandles()
            let first = geometry.rect(for: range.start)
            let last = geometry.rect(for: range.end)
            startHandle.place(edge: first.minX, line: first, within: bounds)
            endHandle.place(edge: last.maxX, line: last, within: bounds)
            // An end scrolled out of view has no handle: it cannot be moved
            // from where ghostty clamps it, and the other end's handle does
            // not drag while it is (`beginHandleDrag`).
            startHandle.isHidden = range.startIsClamped
            endHandle.isHidden = range.endIsClamped
        }

        func touchSelectionHandles() -> (TerminalSelectionHandleView, TerminalSelectionHandleView) {
            if let start = touchSelection.startHandle, let end = touchSelection.endHandle {
                return (start, end)
            }
            let start = makeSelectionHandle(.start)
            let end = makeSelectionHandle(.end)
            // Their touch areas overlap on a short selection.
            start.sibling = end
            end.sibling = start
            touchSelection.startHandle = start
            touchSelection.endHandle = end
            return (start, end)
        }

        private func makeSelectionHandle(_ handle: TouchSelectionHandle) -> TerminalSelectionHandleView {
            let view = TerminalSelectionHandleView(handle: handle)
            let drag = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleSelectionHandleDrag(_:))
            )
            drag.minimumPressDuration = 0
            drag.allowableMovement = .greatestFiniteMagnitude
            view.addGestureRecognizer(drag)
            view.isHidden = true
            addSubview(view)
            return view
        }

        func setTouchSelectionHandlesHidden(_ hidden: Bool) {
            touchSelection.startHandle?.isHidden = hidden
            touchSelection.endHandle?.isHidden = hidden
            touchSelectionHandlesDidChange()
        }

        /// Forgets the touch selection's chrome; ghostty's selection itself is
        /// the caller's to clear.
        func endTouchSelection() {
            cancelTouchSelectionDrag()
            touchSelection.handlePress = nil
            touchSelection.isShown = false
            setTouchSelectionHandlesHidden(true)
            dismissTouchSelectionMenu()
        }

        /// Clears ghostty's selection and its touch chrome.
        public func clearSelection() {
            surface?.clearSelection(restoringPreedit: inputHandler.markedText)
            endTouchSelection()
        }

        /// Output moves a selection with its text, so the handles follow each
        /// render — at most every 50 ms, since reading the selection back
        /// copies its text.
        func touchSelectionDidRender() {
            guard touchSelection.isShown,
                  touchSelection.drag == nil,
                  !touchSelection.layoutIsScheduled
            else { return }
            touchSelection.layoutIsScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                touchSelection.layoutIsScheduled = false
                layoutTouchSelection()
            }
        }

        /// A finger tap while ghostty holds a selection belongs to the
        /// selection: on it, the menu toggles; anywhere else the selection
        /// goes. Either way the tap reaches nothing else.
        func handleTapWithSelection(at point: CGPoint) -> Bool {
            guard hasSelection else { return false }
            if let geometry = touchCellGeometry(),
               let range = touchSelectionRange(),
               case let cell = geometry.cell(at: point),
               range.start <= cell, cell <= range.end
            {
                touchSelection.isShown = true
                layoutTouchSelection()
                if touchSelection.isMenuVisible {
                    dismissTouchSelectionMenu()
                } else {
                    presentTouchSelectionMenu()
                }
            } else {
                clearSelection()
            }
            return true
        }

        func presentTouchSelectionMenu() {
            guard #available(iOS 16.0, *), let bounds = touchSelectionBounds() else { return }
            selectionEditMenuInteraction.presentEditMenu(
                with: UIEditMenuConfiguration(
                    identifier: Self.touchSelectionMenuIdentifier,
                    sourcePoint: CGPoint(x: bounds.midX, y: bounds.minY)
                )
            )
            touchSelection.isMenuVisible = true
        }

        func dismissTouchSelectionMenu() {
            guard touchSelection.isMenuVisible else { return }
            touchSelection.isMenuVisible = false
            if #available(iOS 16.0, *) {
                selectionEditMenuInteraction.dismissMenu()
            }
        }

        // MARK: - Links

        /// The link ghostty resolves under `point`: an OSC 8 hyperlink's
        /// target, else text its URL and path matcher recognizes, including a
        /// link soft-wrapped across rows. Asked the way a desktop pointer
        /// hovering with ⌘ asks, without a click and without a report to a
        /// program that captured the mouse.
        func linkTarget(at point: CGPoint) -> String? {
            guard let surface, touchSelection.drag == nil else { return nil }
            endLinkFlash(on: surface)
            var target: String?
            core.onHoverLink = { url in
                if let url, !url.isEmpty { target = url }
            }
            hoverLink(at: point, on: surface)
            core.onHoverLink = nil
            unhoverLink(on: surface)
            return target
        }

        /// What a tap at `point` would open, and whether it is exactly the
        /// text drawn there. Ghostty's matcher reports the text it matched,
        /// which is always on screen; an OSC 8 hyperlink reports its hidden
        /// target, which may say anything, including the first part of the
        /// longer text it is drawn over. Nil on a blank cell, whatever link
        /// covers it.
        public func linkHit(at point: CGPoint) -> TerminalLinkHit? {
            guard let target = linkTarget(at: point),
                  let surface,
                  let geometry = touchCellGeometry()
            else { return nil }
            let cell = geometry.cell(at: point)
            guard let under = surface.readViewportText(
                from: (cell.column, cell.row), to: (cell.column, cell.row)),
                !under.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return TerminalLinkHit(
                target: target,
                isVisibleText: viewportShows(target, covering: cell, on: surface, geometry: geometry)
            )
        }

        /// What Ghostty's path matcher takes as part of a path besides word
        /// characters (`path_chars` in its `src/config/url.zig`).
        private static let pathRunSymbols: Set<Character> = [
            "_", "-", ".", "~", ":", "/", "?", "#", "@", "!", "$", "&", "*", "+", ";", "=", "%",
        ]
        /// How many blank cells may follow a row's text for the row still to
        /// read as broken at the edge: agent TUIs keep their text a cell or
        /// two in from the right.
        static let pathRunEdgeSlack = 2
        /// How many rows a run may continue onto, either way.
        static let pathRunRowLimit = 8

        static func isPathRunCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || pathRunSymbols.contains(character)
        }

        /// Whether `character` is a box-drawing character (U+2500–U+257F),
        /// which TUIs frame bordered text with (`│`, `┃`). (Waycar patch)
        nonisolated static func isBoxDrawingBorder(_ character: Character) -> Bool {
            isSingleScalar(character, in: 0x2500 ... 0x257F)
        }

        /// Whether `character` is a block element (U+2580–U+259F), which a
        /// TUI draws a scrollbar with in its last column (OpenCode's `█`).
        /// (Waycar patch)
        nonisolated static func isBlockElement(_ character: Character) -> Bool {
            isSingleScalar(character, in: 0x2580 ... 0x259F)
        }

        private nonisolated static func isSingleScalar(
            _ character: Character,
            in range: ClosedRange<UInt32>
        ) -> Bool {
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1
            else { return false }
            return range.contains(scalar.value)
        }

        /// The frame a row's text sits in, by character index. Either the
        /// row's last character is a box-drawing border, and the nearest
        /// same border before the text is the box's left side — so of two
        /// boxes side by side, the one holding the text; or it is a block
        /// element, a scrollbar, and the left side is the nearest
        /// box-drawing border before the text (OpenCode's `┃` before its
        /// `█`), or none, where the row's indentation starts the text.
        /// (Waycar patch)
        private struct PathRunFrame {
            let left: Int?
            let right: Int
            let leftBorder: Character?
            let rightBorder: Character

            init?(_ line: [Character], around index: Int) {
                guard let edge = line.last else { return nil }
                let left: Int?
                if UITerminalView.isBoxDrawingBorder(edge) {
                    guard let same = line[..<index].lastIndex(of: edge) else { return nil }
                    left = same
                } else if UITerminalView.isBlockElement(edge) {
                    left = line[..<index].lastIndex(where: UITerminalView.isBoxDrawingBorder)
                } else {
                    return nil
                }
                self.left = left
                right = line.count - 1
                leftBorder = left.map { line[$0] }
                rightBorder = edge
            }

            /// Where the text inside the frame may start.
            var contentStart: Int { left.map { $0 + 1 } ?? 0 }

            /// Whether `line` is framed alike in the same columns: the same
            /// border on each side, or for a scrollbar any block element in
            /// its column or nothing there — OpenCode draws the scrollbar's
            /// thumb on some rows only — with no text past it.
            func holds(_ line: [Character]) -> Bool {
                if UITerminalView.isBlockElement(rightBorder) {
                    guard line.count <= right + 1 else { return false }
                    if line.count == right + 1, !UITerminalView.isBlockElement(line[right]) {
                        return false
                    }
                } else {
                    guard line.count == right + 1, line[right] == rightBorder else { return false }
                }
                guard let left else { return true }
                return line.indices.contains(left) && line[left] == leftBorder
            }

            /// The scrollbar frame `line` sits in when `below`, the row under
            /// it, holds it: a row with no thumb carries on the text of one
            /// with it.
            static func scrollbar(of line: [Character], holding below: [Character]) -> PathRunFrame? {
                guard let frame = PathRunFrame(line, around: line.count - 1),
                      UITerminalView.isBlockElement(frame.rightBorder), frame.holds(below)
                else { return nil }
                return frame
            }
        }

        /// Where a row's text ends: in `frame`, before its right border and
        /// at most ``pathRunEdgeSlack`` blanks — any number when
        /// `shortOfEdge` — else nil; unframed, at the row's last character.
        private static func pathRunContentEnd(
            _ line: [Character], in frame: PathRunFrame?, shortOfEdge: Bool
        ) -> Int? {
            guard let frame else { return line.count }
            var end = min(frame.right, line.count)
            while end > frame.contentStart, line[end - 1].isWhitespace { end -= 1 }
            return shortOfEdge || frame.right - end <= pathRunEdgeSlack ? end : nil
        }

        /// Where a row's text starts: in `frame` — another row's, so `line`
        /// must hold it too — past its left border and the blanks after it;
        /// unframed, past the row's indentation and a frame column opening
        /// it where the row is open on the right (Kilo's `┃`) or `above`,
        /// the row over it, has the same glyph in that column (OpenCode's
        /// cell above a row its scrollbar's thumb covers), as Waycar's link
        /// scanner reads a row. A row framed on both sides below an unframed
        /// one is a box's, no continuation of it, so its text starts at its
        /// border. Nil for no text there.
        private static func pathRunContentStart(
            _ line: [Character], in frame: PathRunFrame?, above: [Character]?
        ) -> Int? {
            guard let frame else {
                func isFrame(_ character: Character) -> Bool {
                    isBoxDrawingBorder(character) || isBlockElement(character)
                }
                guard let first = line.firstIndex(where: { !$0.isWhitespace }) else { return nil }
                let opensFrame = isFrame(line[first]) && first + 1 < line.count && line[first + 1].isWhitespace
                let isOpenOnTheRight = line.last.map(isFrame) == false
                let sharesFrameAbove = above.map { $0.indices.contains(first) && $0[first] == line[first] } ?? false
                guard opensFrame, isOpenOnTheRight || sharesFrameAbove else { return first }
                return line[(first + 1)...].firstIndex { !$0.isWhitespace }
            }
            guard frame.holds(line) else { return nil }
            return line[frame.contentStart ..< min(frame.right, line.count)].firstIndex { !$0.isWhitespace }
        }

        /// Where the part of a run ending at index `end` of `line`, a row
        /// whose text starts at `textStart`, lies on a grid `columns` wide.
        private static func pathRunLayout(
            _ line: [Character], textStart: Int, end: Int, columns: Int
        ) -> TerminalPathRun.RowLayout {
            var wordStart = end
            while wordStart > 0, !line[wordStart - 1].isWhitespace { wordStart -= 1 }
            let edge = line.count == columns && line.count != end ? columns - 1 : columns
            return TerminalPathRun.RowLayout(
                text: String(line[min(textStart, end)...]), textStart: textStart,
                wordStart: wordStart, end: end, edge: edge,
                endsNearEdge: end >= edge - pathRunEdgeSlack)
        }

        /// Viewport rows as characters, trailing blanks dropped, each read
        /// once for one run.
        @MainActor
        private final class PathRunRows {
            private let surface: TerminalSurface
            let geometry: TerminalCellGeometry
            private var lines: [Int: [Character]] = [:]

            init(surface: TerminalSurface, geometry: TerminalCellGeometry) {
                self.surface = surface
                self.geometry = geometry
            }

            func line(_ row: Int) -> [Character]? {
                if let known = lines[row] { return known }
                guard let text = surface.readViewportText(
                    from: (0, row), to: (geometry.columns - 1, row))
                else { return nil }
                var characters = Array(text.filter { !$0.isNewline })
                while characters.last?.isWhitespace == true { characters.removeLast() }
                lines[row] = characters
                return characters
            }

            /// Whether `row`'s text reaches within ``pathRunEdgeSlack`` cells
            /// of the right edge.
            func endsAtEdge(_ row: Int) -> Bool {
                let first = max(0, geometry.columns - 1 - UITerminalView.pathRunEdgeSlack)
                return surface.readViewportText(from: (first, row), to: (geometry.columns - 1, row))?
                    .contains { !$0.isWhitespace } ?? false
            }

            /// Where in its row's ``line(_:)`` the character drawn at `cell`
            /// is. Rows are read as text, so a wide character before it does
            /// not shift it; nil for a cell past the row's text.
            func index(of cell: TerminalCellPosition) -> Int? {
                guard let under = surface.readViewportText(
                    from: (cell.column, cell.row), to: (cell.column, cell.row)),
                    let drawn = under.first(where: { !$0.isNewline }),
                    let prefix = surface.readViewportText(
                        from: (0, cell.row), to: (cell.column, cell.row)),
                    let line = line(cell.row)
                else { return nil }
                let index = prefix.filter { !$0.isNewline }.count - 1
                guard line.indices.contains(index), line[index] == drawn else { return nil }
                return index
            }
        }

        /// A run and where it lies: its first character, and the index just
        /// past its last, each on its row.
        private struct PathRunSpan {
            let run: TerminalPathRun
            let start: (row: Int, index: Int)
            let end: (row: Int, index: Int)
        }

        /// The path characters drawn around `point`, continued across row
        /// breaks that are not soft wraps. (Waycar patch)
        ///
        /// Ghostty's matcher joins soft-wrapped rows only. A multiplexer that
        /// repaints its pane by cursor moves (`herdr terminal attach`, mosh)
        /// and an agent TUI that wraps its own text both break a long path
        /// with no wrap flag, so the matcher sees one row's fragment of it,
        /// or nothing where the fragment has no slash. A run continues onto
        /// the next row when it is the last text on its row, that text ends
        /// within ``pathRunEdgeSlack`` cells of the edge, and the next row's
        /// text starts with a path character; and back onto the row before
        /// the same way. A bordered box's rows (`│ …/pa │` over `│ th.png │`)
        /// join the same way inside their borders: the row's last character
        /// is a box-drawing border at the edge, at most ``pathRunEdgeSlack``
        /// blanks after the run, the same border comes before the run, and
        /// the other row has that border in both of those columns, then the
        /// path — so text in a box beside it never joins. A scrollbar of
        /// block elements in the last column (OpenCode's `█`) is an edge the
        /// same way: the run ends at most ``pathRunEdgeSlack`` blanks before
        /// it and the other row has a block element there too, inside the
        /// nearest box-drawing border before the run if there is one
        /// (OpenCode's `┃`), past its indentation if not. A row's text starts
        /// past its indentation and a frame column opening it (Kilo's `┃`
        /// with nothing on the right), as the link scanner reads it. That
        /// also joins a path which merely ended near the edge to the next
        /// row's first word, so a host should keep the row's own reading as
        /// a fallback, or judge each break by where it falls
        /// (``TerminalPathRun/layouts``).
        /// With `joiningRowsShortOfEdge`, a run continues from the last text
        /// on its row however far short of the edge or its frame that text
        /// ends, ``TerminalPathRun/RowLayout/endsNearEdge`` telling the host
        /// which breaks were short of it: OpenCode and Kilo wrap a URL at a
        /// `/` or `-` well short of the edge, and a host that reads such
        /// breaks by its own rule can open the URL whole from either row.
        /// Nil unless the cell under `point` holds a path character. Rows
        /// are read as text, so a wide character does not shift the run.
        public func pathRun(at point: CGPoint, joiningRowsShortOfEdge: Bool = false) -> TerminalPathRun? {
            guard let surface, let geometry = touchCellGeometry() else { return nil }
            let rows = PathRunRows(surface: surface, geometry: geometry)
            let cell = geometry.cell(at: point)
            guard let index = rows.index(of: cell) else { return nil }
            return pathRunSpan(
                row: cell.row, index: index, in: rows, shortOfEdge: joiningRowsShortOfEdge)?.run
        }

        /// The path a selection over more than one row spells: the run
        /// ``pathRun(at:)`` reads there, when the selection covers exactly
        /// that run — from its first character to its last, blanks, box
        /// borders and a scrollbar at either end aside. Rows that only sit
        /// one above another (a list of paths, a path over a box's bottom
        /// rule) are no one run, so nil; so is a selection on one row, or
        /// with an end off screen.
        /// (Waycar patch)
        public func selectedPathRun() -> TerminalPathRun? {
            guard let surface, let geometry = touchCellGeometry(),
                  let range = touchSelectionRange(),
                  !range.startIsClamped, !range.endIsClamped,
                  range.start.row < range.end.row
            else { return nil }
            let rows = PathRunRows(surface: surface, geometry: geometry)
            func isFraming(_ character: Character) -> Bool {
                character.isWhitespace || Self.isBoxDrawingBorder(character)
                    || Self.isBlockElement(character)
            }
            guard let from = rows.index(of: range.start), let to = rows.index(of: range.end),
                  let first = rows.line(range.start.row), let last = rows.line(range.end.row),
                  let start = first[from...].firstIndex(where: { !isFraming($0) }),
                  let span = pathRunSpan(row: range.start.row, index: start, in: rows, shortOfEdge: false),
                  span.start == (range.start.row, start),
                  span.end.row == range.end.row, span.end.index <= to + 1,
                  last[span.end.index ..< to + 1].allSatisfy(isFraming)
            else { return nil }
            return span.run
        }

        private func pathRunSpan(
            row tappedRow: Int, index: Int, in rows: PathRunRows, shortOfEdge: Bool
        ) -> PathRunSpan? {
            guard let tappedLine = rows.line(tappedRow), tappedLine.indices.contains(index),
                  Self.isPathRunCharacter(tappedLine[index])
            else { return nil }
            var start = index
            while start > 0, Self.isPathRunCharacter(tappedLine[start - 1]) { start -= 1 }
            var end = index + 1
            while end < tappedLine.count, Self.isPathRunCharacter(tappedLine[end]) { end += 1 }
            let columns = rows.geometry.columns
            var rowTexts = [String(tappedLine[start ..< end])]
            let tappedStart = Self.pathRunContentStart(
                tappedLine, in: PathRunFrame(tappedLine, around: start),
                above: tappedRow > 0 ? rows.line(tappedRow - 1) : nil) ?? start
            var layouts = [Self.pathRunLayout(tappedLine, textStart: tappedStart, end: end, columns: columns)]

            var row = tappedRow
            var current = tappedLine
            var runStart = start
            var runEnd = end
            while row - tappedRow < Self.pathRunRowLimit,
                  row + 1 < rows.geometry.rows, shortOfEdge || rows.endsAtEdge(row),
                  case let frame = PathRunFrame(current, around: runStart),
                  Self.pathRunContentEnd(current, in: frame, shortOfEdge: shortOfEdge) == runEnd,
                  let next = rows.line(row + 1),
                  let first = Self.pathRunContentStart(next, in: frame, above: current),
                  Self.isPathRunCharacter(next[first])
            {
                var nextEnd = first + 1
                while nextEnd < next.count, Self.isPathRunCharacter(next[nextEnd]) { nextEnd += 1 }
                rowTexts.append(String(next[first ..< nextEnd]))
                layouts.append(Self.pathRunLayout(next, textStart: first, end: nextEnd, columns: columns))
                row += 1
                current = next
                runStart = first
                runEnd = nextEnd
            }
            let spanEnd = (row: row, index: runEnd)

            row = tappedRow
            current = tappedLine
            runStart = start
            while tappedRow - row < Self.pathRunRowLimit, row > 0,
                  let previous = rows.line(row - 1),
                  case let frame = PathRunFrame(current, around: runStart),
                  Self.pathRunContentStart(current, in: frame, above: previous) == runStart,
                  frame?.holds(previous) ?? true,
                  // A row with no scrollbar thumb under one with it.
                  case let previousFrame = frame ?? PathRunFrame.scrollbar(of: previous, holding: current),
                  let edge = Self.pathRunContentEnd(previous, in: previousFrame, shortOfEdge: shortOfEdge),
                  edge > 0, Self.isPathRunCharacter(previous[edge - 1]),
                  shortOfEdge || rows.endsAtEdge(row - 1)
            {
                var previousStart = edge - 1
                while previousStart > 0, Self.isPathRunCharacter(previous[previousStart - 1]) {
                    previousStart -= 1
                }
                rowTexts.insert(String(previous[previousStart ..< edge]), at: 0)
                let previousTextStart = Self.pathRunContentStart(
                    previous, in: previousFrame, above: row > 1 ? rows.line(row - 2) : nil) ?? previousStart
                layouts.insert(
                    Self.pathRunLayout(previous, textStart: previousTextStart, end: edge, columns: columns),
                    at: 0)
                row -= 1
                current = previous
                runStart = previousStart
            }
            return PathRunSpan(
                run: TerminalPathRun(rows: rowTexts, layouts: layouts, tappedRow: tappedRow - row),
                start: (row, runStart),
                end: spanEnd)
        }

        /// Opening brackets and quotes that prose puts before a link — the
        /// backtick of a Markdown code span included.
        private static let linkLeadingDelimiters: Set<Character> = ["(", "[", "{", "<", "'", "\"", "`"]
        /// Sentence punctuation and closing brackets and quotes that prose
        /// puts after a link.
        private static let linkTrailingPunctuation: Set<Character> = [
            ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "'", "\"", "`",
        ]
        /// The longest run of that punctuation a link's own text may be
        /// followed by.
        private static let linkTrailingPunctuationLimit = 4

        /// Whether `text` is all that is drawn on consecutive cells (soft
        /// wraps allowed) that include `cell`, not the start or middle of
        /// something longer: an OSC 8 target `https://a.example` drawn over
        /// `https://a.example.evil.example/`, or `~/.ssh/key` over
        /// `~/.ssh/key.pub`. Before the text must be the viewport's first
        /// cell, a blank, a hard line end or an opening bracket or quote;
        /// after it a blank, a line end or the viewport's last cell, at most
        /// after a short run of sentence punctuation; and neither neighbouring
        /// cell may resolve to the same target, so an OSC 8 run longer than
        /// its target never counts. Anything else reads as not shown, which
        /// errs toward asking — wide characters too, since they make cells
        /// and characters disagree.
        ///
        /// Linear in `text`, which may be no longer than the viewport: the
        /// rows around `cell` are read once, searched once, and only the
        /// first candidate that looks bounded there is confirmed, with one
        /// read of its cells, one of each boundary, and a link probe of each
        /// neighbouring cell.
        private func viewportShows(
            _ text: String,
            covering cell: TerminalCellPosition,
            on surface: TerminalSurface,
            geometry: TerminalCellGeometry
        ) -> Bool {
            let pattern = Array(text)
            let length = pattern.count
            let columns = geometry.columns
            let total = columns * geometry.rows
            guard length > 0, length <= total else { return false }
            func position(_ index: Int) -> (column: Int, row: Int) {
                (index % columns, index / columns)
            }
            let tapped = cell.row * columns + cell.column
            // Every run of `length` cells covering `cell`, and one more cell
            // on either side.
            let firstRow = max(0, tapped - length) / columns
            let lastRow = min(total - 1, tapped + length) / columns
            guard let cells = Self.viewportCells(rows: firstRow ... lastRow, columns: columns, of: surface)
            else { return false }
            let base = firstRow * columns
            let candidates = (max(0, tapped - length + 1) - base) ... (min(total - 1, tapped + length - 1) - base)
            let found = Self.firstOccurrence(of: pattern, in: cells, within: candidates) { offset in
                let start = base + offset
                let end = start + length
                // A row edge may be a hard line end; the reads below decide.
                let bounded = start == 0 || start % columns == 0
                    || cells[offset - 1].isWhitespace
                    || Self.linkLeadingDelimiters.contains(cells[offset - 1])
                return bounded
                    && (end == total || end % columns == 0
                        || cells[offset + length].isWhitespace
                        || Self.linkTrailingPunctuation.contains(cells[offset + length]))
            }
            guard let found else { return false }

            let start = base + found
            let end = start + length
            guard surface.readViewportText(from: position(start), to: position(end - 1)) == text,
                  start == 0 || Self.isLinkLeadingBoundary(
                      surface.readViewportText(from: position(start - 1), to: position(start)))
            else { return false }
            if end < total {
                let readEnd = min(total - 1, end + Self.linkTrailingPunctuationLimit)
                guard Self.isLinkTrailingBoundary(
                    surface.readViewportText(from: position(end - 1), to: position(readEnd)),
                    following: readEnd - end + 1,
                    reachesViewportEnd: readEnd == total - 1
                ) else { return false }
            }
            // An OSC 8 hyperlink drawn over more than its target: the target
            // ends on a boundary the text itself does not.
            for neighbour in [start - 1, end] where neighbour >= 0 && neighbour < total {
                let (column, row) = position(neighbour)
                let point = geometry.point(
                    in: TerminalCellPosition(column: column, row: row), x: 0.5, y: 0.5)
                if linkTarget(at: point) == text { return false }
            }
            return true
        }

        /// Viewport `rows` as one character per cell. A row reads only as
        /// far as its last non-blank cell, so the rest is padded with blanks;
        /// a wide character leaves its row a character short and shifts the
        /// cells after it, which the confirming read then rejects.
        private static func viewportCells(
            rows: ClosedRange<Int>,
            columns: Int,
            of surface: TerminalSurface
        ) -> [Character]? {
            var cells: [Character] = []
            cells.reserveCapacity(rows.count * columns)
            for row in rows {
                guard let line = surface.readViewportText(from: (0, row), to: (columns - 1, row))
                else { return nil }
                var count = 0
                for character in line where !character.isNewline && count < columns {
                    cells.append(character)
                    count += 1
                }
                cells.append(contentsOf: repeatElement(" ", count: columns - count))
            }
            return cells
        }

        /// The first offset in `range` where `pattern` starts in `cells`,
        /// ends inside `range`, and `accepts`. Knuth–Morris–Pratt, so linear
        /// however much the pattern repeats itself.
        private static func firstOccurrence(
            of pattern: [Character],
            in cells: [Character],
            within range: ClosedRange<Int>,
            where accepts: (Int) -> Bool
        ) -> Int? {
            var fallback = [Int](repeating: 0, count: pattern.count)
            var matched = 0
            for index in pattern.indices.dropFirst() {
                while matched > 0, pattern[index] != pattern[matched] {
                    matched = fallback[matched - 1]
                }
                if pattern[index] == pattern[matched] { matched += 1 }
                fallback[index] = matched
            }
            matched = 0
            for index in range {
                while matched > 0, cells[index] != pattern[matched] {
                    matched = fallback[matched - 1]
                }
                if cells[index] == pattern[matched] { matched += 1 }
                if matched == pattern.count {
                    let start = index - matched + 1
                    if accepts(start) { return start }
                    matched = fallback[matched - 1]
                }
            }
            return nil
        }

        /// Whether `read`, the cell before a link's text and its first cell,
        /// shows a boundary: a hard line end between them, or a blank or an
        /// opening bracket or quote before.
        private static func isLinkLeadingBoundary(_ read: String?) -> Bool {
            guard let read else { return false }
            if read.contains(where: \.isNewline) { return true }
            guard read.count == 2, let before = read.first else { return false }
            return before.isWhitespace || linkLeadingDelimiters.contains(before)
        }

        /// Whether `read`, a link text's last cell and the `following` cells
        /// after it, shows a boundary after the text: a blank or a line end,
        /// straight away or after a short run of sentence punctuation. A read
        /// shorter than the cells asked for stopped at trailing blanks, which
        /// is a line end.
        private static func isLinkTrailingBoundary(
            _ read: String?,
            following: Int,
            reachesViewportEnd: Bool
        ) -> Bool {
            guard let read else { return false }
            let after = read.dropFirst()
            var punctuation = 0
            for character in after {
                // Blanks, and the `\n` of a hard line end.
                if character.isWhitespace { return true }
                guard punctuation < linkTrailingPunctuationLimit,
                      linkTrailingPunctuation.contains(character)
                else { return false }
                punctuation += 1
            }
            return after.count < following || reachesViewportEnd
        }

        /// Underlines the link under `point` for a moment, the way ghostty
        /// marks a hovered link, as feedback for a tap that opened it.
        public func flashLink(at point: CGPoint) {
            guard let surface, touchSelection.drag == nil else { return }
            endLinkFlash(on: surface)
            hoverLink(at: point, on: surface)
            touchSelection.linkUnhover = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, let surface = self.surface else { return }
                touchSelection.linkUnhover = nil
                unhoverLink(on: surface)
            }
        }

        /// ghostty refreshes links on a pointer move only while no program
        /// captured the mouse or while shift overrides the capture, and then
        /// matches with shift taken back out; ⌘ is its link modifier on Apple
        /// platforms. The guard button keeps the move out of a capturing
        /// program's motion reports, and releasing it with the same modifiers
        /// leaves ghostty's link highlight in place.
        private func hoverLink(at point: CGPoint, on surface: TerminalSurface) {
            let modifiers: TerminalInputModifiers = surface.isMouseCaptured
                ? [.shift, .super_]
                : [.super_]
            surface.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: Self.selectionGuardButton,
                modifiers: modifiers
            )
            // ghostty re-resolves the link only when the pointer changes
            // cells; a selection gesture that ended on this cell would leave
            // it cached as "no link". Off the surface resets that.
            surface.sendMousePos(x: -1, y: -1, modifiers: modifiers)
            surface.sendMousePos(x: Double(point.x), y: Double(point.y), modifiers: modifiers)
            surface.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: Self.selectionGuardButton,
                modifiers: modifiers
            )
        }

        /// A link still flashing is unhovered first: probing from its hover
        /// state misses the link on the first try.
        private func endLinkFlash(on surface: TerminalSurface) {
            guard let unhover = touchSelection.linkUnhover else { return }
            unhover.cancel()
            touchSelection.linkUnhover = nil
            unhoverLink(on: surface)
        }

        /// A position off the surface clears ghostty's hover state.
        private func unhoverLink(on surface: TerminalSurface) {
            beginSelectionGesture(on: surface)
            surface.sendMousePos(x: -1, y: -1, modifiers: .shift)
            endSelectionGesture(on: surface)
        }
    }

    // UIKit calls the delegate on the main thread; the SDK just does not say
    // so in the protocol's isolation.
    @available(iOS 16.0, *)
    extension UITerminalView: @preconcurrency UIEditMenuInteractionDelegate {
        public func editMenuInteraction(
            _: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard (configuration.identifier as? NSString) == Self.touchSelectionMenuIdentifier else {
                return UIMenu(children: suggestedActions)
            }
            guard let text = surface?.readSelection(), !text.isEmpty else { return nil }
            let copy = UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.copySelectedTextToPasteboard()
            }
            return UIMenu(children: [copy] + touchSelectionMenuElements(forSelectedText: text))
        }

        public func editMenuInteraction(
            _: UIEditMenuInteraction,
            targetRectFor configuration: UIEditMenuConfiguration
        ) -> CGRect {
            guard (configuration.identifier as? NSString) == Self.touchSelectionMenuIdentifier else {
                return .null
            }
            return touchSelectionBounds() ?? .null
        }

        public func editMenuInteraction(
            _: UIEditMenuInteraction,
            willDismissMenuFor configuration: UIEditMenuConfiguration,
            animator _: any UIEditMenuInteractionAnimating
        ) {
            guard (configuration.identifier as? NSString) == Self.touchSelectionMenuIdentifier else {
                return
            }
            touchSelection.isMenuVisible = false
        }
    }
#endif
