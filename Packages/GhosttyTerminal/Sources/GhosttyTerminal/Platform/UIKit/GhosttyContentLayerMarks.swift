//
//  GhosttyContentLayerMarks.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import Foundation
    import ObjectiveC
    import QuartzCore

    /// (Waycar patch) Moves the display mark ghostty's renderer thread puts on
    /// its content layer to the main thread.
    ///
    /// libghostty-spm's iOS rendering patch kicks the first frame with
    /// `setNeedsDisplay` from `Metal.loopEnter`, which runs on the renderer
    /// thread. Off the main thread that mark opens an implicit CATransaction
    /// the thread never commits; Core Animation commits it as the thread exits,
    /// inside `ghostty_surface_free`'s join, and that commit lays out UIKit on
    /// the renderer thread. On iPadOS it laid out a navigation controller and
    /// Auto Layout threw NSInternalInconsistencyException. `CA_DEBUG_TRANSACTIONS`
    /// names this mark as the creator of every such transaction, so made on
    /// the main thread it leaves the renderer thread nothing to commit.
    enum GhosttyContentLayerMarks {
        /// Installs the redirect; run once, before ghostty creates a surface.
        static let install: Void = {
            let selector = NSSelectorFromString("setNeedsDisplayInRect:")
            guard let method = class_getInstanceMethod(CALayer.self, selector) else { return }
            typealias Mark = @convention(c) (CALayer, Selector, CGRect) -> Void
            let mark = unsafeBitCast(method_getImplementation(method), to: Mark.self)
            let redirect: @convention(block) (CALayer, CGRect) -> Void = { layer, rect in
                guard !Thread.isMainThread, isContentLayer(layer) else {
                    mark(layer, selector, rect)
                    return
                }
                // Ghostty marks the whole layer; on the main thread
                // `setNeedsDisplay` comes back through here.
                layer.performSelector(
                    onMainThread: NSSelectorFromString("setNeedsDisplay"),
                    with: nil,
                    waitUntilDone: false)
            }
            method_setImplementation(method, imp_implementationWithBlock(redirect))
        }()

        /// Ghostty's `IOSurfaceLayer`, a class its Metal renderer registers at
        /// runtime.
        private static func isContentLayer(_ layer: CALayer) -> Bool {
            guard let contentLayer = NSClassFromString("IOSurfaceLayer") else { return false }
            return layer.isKind(of: contentLayer)
        }
    }
#endif
