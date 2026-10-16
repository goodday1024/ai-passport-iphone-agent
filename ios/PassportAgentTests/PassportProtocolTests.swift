import XCTest
@testable import PassportAgent

final class PassportProtocolTests: XCTestCase {
    func testMoveDecodingAndCommand() throws {
        let json = #"{"observation":"button","action":{"action":"move","dx":12,"dy":-8}}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(ModelStep.self, from: json)
        XCTAssertEqual(step.action, .move(dx: 12, dy: -8))
        XCTAssertEqual(step.action.passportCommand, "move 12 -8")
    }

    func testTypeRemovesNewlines() throws {
        let json = #"{"observation":"field","action":{"action":"type","text":"hello\nworld"}}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(ModelStep.self, from: json)
        XCTAssertEqual(step.action.passportCommand, "type hello world")
    }

    func testTapUsesAbsoluteCoordinates() throws {
        let json = #"{"observation":"button","action":{"action":"tap","dx":320,"dy":640}}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(ModelStep.self, from: json)
        XCTAssertEqual(step.action, .tap(x: 320, y: 640))
        XCTAssertNil(step.action.passportCommand)
    }
}
