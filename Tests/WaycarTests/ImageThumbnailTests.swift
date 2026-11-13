import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Waycar

@Suite("Image thumbnail")
struct ImageThumbnailTests {
    @Test func downsamplesDataToTheLongSideAndKeepsTheAspectRatio() async throws {
        let data = try Self.encodedImage(width: 400, height: 200, type: .png)

        let thumbnail = try #require(await ImageThumbnail.make(data: data, maxPixelSize: 100))

        Self.expectDownsampled(thumbnail.image, sourceWidth: 400, sourceHeight: 200, maxPixelSize: 100)
    }

    @Test func downsamplesAFileOnDisk() async throws {
        let data = try Self.encodedImage(width: 200, height: 400, type: .jpeg)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try #require(await ImageThumbnail.make(contentsOf: url, maxPixelSize: 100))

        Self.expectDownsampled(thumbnail.image, sourceWidth: 200, sourceHeight: 400, maxPixelSize: 100)
    }

    @Test func undecodableDataYieldsNil() async {
        let garbage = Data("definitely not an image".utf8)
        #expect(await ImageThumbnail.make(data: garbage, maxPixelSize: 100) == nil)
    }

    @Test func missingFileYieldsNil() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).png")
        #expect(await ImageThumbnail.make(contentsOf: url, maxPixelSize: 100) == nil)
    }

    @Test func sourceWiderThanTheSideLimitYieldsNil() async throws {
        let data = try Self.encodedImage(width: 70_000, height: 1, type: .png)
        #expect(await ImageThumbnail.make(data: data, maxPixelSize: 100) == nil)
    }

    @Test func exifOrientationIsApplied() async throws {
        // Stored landscape 400×200 with orientation 6 (rotate 90° CW) displays
        // as portrait, so the thumbnail must come back taller than wide.
        let data = try Self.encodedImage(width: 400, height: 200, type: .jpeg, orientation: 6)

        let thumbnail = try #require(await ImageThumbnail.make(data: data, maxPixelSize: 100))

        Self.expectDownsampled(thumbnail.image, sourceWidth: 200, sourceHeight: 400, maxPixelSize: 100)
    }

    // MARK: Fixtures

    private static func expectDownsampled(
        _ image: CGImage, sourceWidth: Int, sourceHeight: Int, maxPixelSize: Int
    ) {
        #expect(max(image.width, image.height) <= maxPixelSize)
        #expect(max(image.width, image.height) >= maxPixelSize - 1)
        // Orientation: the long side stays on the same axis.
        #expect((image.width > image.height) == (sourceWidth > sourceHeight))
        let expectedShort = Double(min(sourceWidth, sourceHeight))
            * Double(max(image.width, image.height)) / Double(max(sourceWidth, sourceHeight))
        #expect(abs(Double(min(image.width, image.height)) - expectedShort) <= 1)
    }

    private struct EncodingFailed: Error {}

    private static func encodedImage(
        width: Int, height: Int, type: UTType, orientation: Int? = nil
    ) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw EncodingFailed() }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
        guard let image = context.makeImage() else { throw EncodingFailed() }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, type.identifier as CFString, 1, nil)
        else { throw EncodingFailed() }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodingFailed() }
        return output as Data
    }
}
