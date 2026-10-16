import Foundation

@MainActor
final class PointerController {
    private let passport: PassportBLEClient
    private let capture: ScreenCaptureService
    private var span: (width: Double, height: Double)?
    private let nudge = 12

    init(passport: PassportBLEClient, capture: ScreenCaptureService) {
        self.passport = passport
        self.capture = capture
    }

    func invalidate() { span = nil }

    func calibrate() async throws {
        try await command("home")
        var samples: [(units: Int, point: PointerVision.Point)] = []
        var previous = 0
        for units in [150, 350] {
            try await command("move \(units - previous) \(units - previous)")
            try await Task.sleep(for: .milliseconds(350))
            guard let point = try await locatePointer(expectedShift: 0.025) else {
                span = nil
                throw PointerError.pointerNotFound
            }
            samples.append((units, point)); previous = units
        }
        let dx = samples[1].point.x - samples[0].point.x
        let dy = samples[1].point.y - samples[0].point.y
        guard dx > 0.05, dy > 0.05 else { throw PointerError.invalidCalibration }
        let measured = (width: 200 / dx, height: 200 / dy)
        guard measured.width > 250, measured.width < 4000,
              measured.height > 250, measured.height < 5000 else { throw PointerError.invalidCalibration }
        span = measured
    }

    func tap(pixelX: Int, pixelY: Int, imageWidth: Int = 768, imageHeight: Int = 1366) async throws {
        if span == nil { try await calibrate() }
        guard let span else { throw PointerError.notCalibrated }
        let target = PointerVision.Point(
            x: min(max(Double(pixelX) / Double(imageWidth), 0), 1),
            y: min(max(Double(pixelY) / Double(imageHeight), 0), 1)
        )
        try await command("home")
        try await command("move \(Int((target.x * span.width).rounded())) \(Int((target.y * span.height).rounded()))")
        try await Task.sleep(for: .milliseconds(350))
        if let actual = try await locatePointer(expectedShift: Double(nudge) / span.width, near: target) {
            let correctionX = Int(((target.x - actual.x) * span.width).rounded())
            let correctionY = Int(((target.y - actual.y) * span.height).rounded())
            if abs(correctionX) > 3 || abs(correctionY) > 3 {
                guard abs(correctionX) < Int(span.width * 0.12),
                      abs(correctionY) < Int(span.height * 0.12) else { throw PointerError.unreliableReading }
                try await command("move \(correctionX) \(correctionY)")
            }
        }
        try await command("click")
    }

    private func locatePointer(expectedShift: Double, near: PointerVision.Point? = nil) async throws -> PointerVision.Point? {
        guard let before = capture.frame() else { return nil }
        try await command("move \(nudge) 0")
        try await Task.sleep(for: .milliseconds(420))
        guard let after = capture.frame() else { return nil }
        try await command("move -\(nudge) 0")
        return PointerVision.locate(before: before, after: after, expectedShift: expectedShift, near: near)
    }

    private func command(_ value: String) async throws {
        let reply = try await passport.send(value)
        guard reply == "ok" else { throw AgentError.command(reply) }
    }
}

enum PointerError: LocalizedError {
    case notCalibrated, pointerNotFound, invalidCalibration, unreliableReading

    var errorDescription: String? {
        switch self {
        case .notCalibrated: "鼠标尚未校准"
        case .pointerNotFound: "无法在画面中识别鼠标指针，请保持屏幕静止后重试"
        case .invalidCalibration: "鼠标校准结果异常，请检查辅助触控指针是否可见"
        case .unreliableReading: "指针位置变化过大，已取消本次点击"
        }
    }
}
