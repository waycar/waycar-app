import SwiftUI
import Testing

@testable import Waycar

@Suite("Console sheet presentation")
struct ConsoleSheetPresentationTests {
    @Test func regularWidthUsesFormSizing() {
        #expect(ConsoleSheetPresentation(horizontalSizeClass: .regular) == .form)
    }

    @Test func compactWidthPreservesDestinationSizing() {
        #expect(ConsoleSheetPresentation(horizontalSizeClass: .compact) == .inheritedSheet)
    }

    @Test func unknownSizeClassPreservesDestinationSizing() {
        #expect(ConsoleSheetPresentation(horizontalSizeClass: nil) == .inheritedSheet)
    }
}
