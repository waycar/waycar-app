import Testing

@testable import Waycar

@Suite("CarPlay typing dots")
struct CarPlayTypingDotsTests {
    @Test func eachDotRisesInTurnThenTwoRestFrames() {
        #expect(CarPlayTypingDots.raisedDotPerFrame == [0, 1, 2, nil, nil])
        #expect(CarPlayTypingDots.dotCount == 3)
        #expect(CarPlayTypingDots.cycleDuration == 1.2)
    }
}
