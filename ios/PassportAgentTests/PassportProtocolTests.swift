import XCTest
@testable import PassportAgent

final class PassportProtocolTests: XCTestCase {
    func testMoveDecodingAndCommand() throws {
        let json = #"{"observation":"button","action":{"action":"move","dx":12,"dy":-8}}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(ModelStep.self, from: json)
        XCTAssertEqual(step.action, .move(dx: 12, dy: -8))
        XCTAssertEqual(step.action.passportCommand, "move 12 -8")
    }

    func testTypeUsesDedicatedInputPath() throws {
        let json = #"{"observation":"field","action":{"action":"type","text":"hello\nworld"}}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(ModelStep.self, from: json)
        XCTAssertNil(step.action.passportCommand)
        XCTAssertEqual(TextInputPlan.make(for: "hello\nworld"), .hid("hello world"))
    }

    func testChineseTextUsesLocalPasteboardPath() {
        XCTAssertEqual(TextInputPlan.make(for: "你好，世界"), .paste("你好，世界"))
    }

    func testMixedTextUsesLocalPasteboardPath() {
        XCTAssertEqual(TextInputPlan.make(for: "订单 123"), .paste("订单 123"))
    }

    func testTapUsesAbsoluteCoordinates() throws {
        let json = #"{"observation":"button","action":{"action":"tap","dx":417,"dy":469}}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(ModelStep.self, from: json)
        XCTAssertEqual(step.action, .tap(x: 417, y: 469))
        XCTAssertNil(step.action.passportCommand)
    }

    func testSensitiveActionRequestsUserAndHasNoPassportCommand() throws {
        let json = #"{"observation":"Payment confirmation is visible","action":{"action":"user_action","reason":"请确认支付"}}"#.data(using: .utf8)!
        let step = try JSONDecoder().decode(ModelStep.self, from: json)
        XCTAssertEqual(step.action, .userAction("请确认支付"))
        XCTAssertNil(step.action.passportCommand)
    }

    func testPointerCalibrationCompensatesForOffset() {
        let calibration = PointerCalibration(
            width: 500,
            height: 1000,
            xSamples: [.init(commanded: 0.3, landed: 0.34), .init(commanded: 0.7, landed: 0.74)],
            ySamples: [.init(commanded: 0.3, landed: 0.27), .init(commanded: 0.7, landed: 0.67)]
        )
        let result = calibration.units(x: 0.5, y: 0.5)
        XCTAssertLessThanOrEqual(abs(result.x - 230), 1)
        XCTAssertLessThanOrEqual(abs(result.y - 530), 1)
    }

    func testPointerCalibrationRejectsImplausibleFit() {
        let calibration = PointerCalibration(
            width: 500,
            height: 1000,
            xSamples: [.init(commanded: 0.2, landed: 0.2), .init(commanded: 0.8, landed: 1.7)],
            ySamples: []
        )
        XCTAssertEqual(calibration.units(x: 0.5, y: 0.5).x, 250)
    }
}
