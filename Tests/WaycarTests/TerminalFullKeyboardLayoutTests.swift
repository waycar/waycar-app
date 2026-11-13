import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Terminal full keyboard layout", .serialized)
struct TerminalFullKeyboardLayoutTests {
    @Test(arguments: [320, 390, 600, 834, 1024, 1366])
    func rowsFillTheAvailableWidthWithoutChangingHeight(width: Int) {
        for height in [220, 320, 420] {
            let layout = TerminalFullKeyboardLayout(size: CGSize(width: width, height: height))
            let gap = layout.keySpacing
            let character = layout.characterWidth
            let fullRow = 10 * character + 9 * gap
            let homeRow = 9 * character + 8 * gap + 2 * layout.homeRowInset
            let bottomRow = 9 * layout.bottomKeyWidth + layout.spaceWidth + 9 * gap
            for occupiedWidth in [fullRow, homeRow, bottomRow] {
                #expect(abs(occupiedWidth - layout.contentWidth) < 0.001)
            }
            for count in [6, 7] {
                let lowerRow = CGFloat(count) * character + CGFloat(count + 1) * gap
                    + 2 * layout.sideKeyWidth(characterCount: count)
                #expect(abs(lowerRow - layout.contentWidth) < 0.001)
                #expect(layout.sideKeyWidth(characterCount: count) > character)
            }
            #expect(layout.spaceWidth > 2 * character)
            #expect(abs(6 * layout.rowHeight + 5 * TerminalFullKeyboardLayout.rowSpacing
                + 12 - CGFloat(height)) < 0.001)
            #expect(layout.rowHeight == TerminalFullKeyboardLayout(
                size: CGSize(width: 390, height: height)).rowHeight)
        }
    }

    /// Render the production keyboard, including UIKit Backspace. The old
    /// centered width cap fails the edge checks on wide windows.
    @Test(arguments: [390, 600, 834, 1024, 1366], [220, 320])
    func renderedKeysReachBothEdges(width: Int, height: Int) async throws {
        let size = CGSize(width: width, height: height)
        let bounds = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView:
            TerminalFullKeyboard(isEnabled: true, keyboardControl: TerminalKeyboardControl(), send: { _ in })
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        controller.safeAreaRegions = []
        controller.view.frame = bounds
        let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "terminal-keyboard-\(width)x\(height)", as: .png)

        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmap = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(cgImage, in: bounds)
        let layout = TerminalFullKeyboardLayout(size: size)
        for (row, expectedCount) in [7, 10, 10, 9, 9, 10].enumerated() {
            // Below the rounded top corners and above the centered labels.
            let y = Int(4 + CGFloat(row) * (layout.rowHeight + 4) + 8)
            var runs: [Range<Int>] = []
            var start: Int?
            for x in 0...width {
                let isKey = x < width && pixels[(y * width + x) * 4] > 20
                if isKey, start == nil { start = x }
                if !isKey, let lower = start {
                    runs.append(lower..<x)
                    start = nil
                }
            }
            #expect(runs.count == expectedCount, "row \(row), \(width)x\(height): \(runs)")
            let first = try #require(runs.first)
            let last = try #require(runs.last)
            if row != 3 {
                #expect(first.lowerBound <= 13)
                #expect(width - last.upperBound <= 13)
            }
            if row == 1 || row == 2 || row == 3 {
                for run in runs {
                    #expect(abs(CGFloat(run.count) - layout.characterWidth) <= 2)
                }
            }
        }
    }
}
