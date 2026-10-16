import Foundation

struct PointerCalibration: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        let commanded: Double
        let landed: Double
    }

    let width: Double
    let height: Double
    var xSamples: [Sample]
    var ySamples: [Sample]

    func correctedFraction(_ target: Double, samples: [Sample]) -> Double {
        guard samples.count >= 2 else { return target }
        let count = Double(samples.count)
        let meanCommanded = samples.reduce(0) { $0 + $1.commanded } / count
        let meanLanded = samples.reduce(0) { $0 + $1.landed } / count
        let variance = samples.reduce(0) { $0 + pow($1.commanded - meanCommanded, 2) }
        guard variance > 0.0001 else { return target }
        var slope = samples.reduce(0) {
            $0 + ($1.commanded - meanCommanded) * ($1.landed - meanLanded)
        } / variance
        if !(0.85..<1.15).contains(slope) { slope = 1 }
        let intercept = meanLanded - slope * meanCommanded
        guard abs(intercept) < 0.1 else { return target }
        return (target - intercept) / slope
    }

    func units(x: Double, y: Double) -> (x: Int, y: Int) {
        let fixedX = min(max(correctedFraction(x, samples: xSamples), 0), 1)
        let fixedY = min(max(correctedFraction(y, samples: ySamples), 0), 1)
        return (Int((fixedX * width).rounded()), Int((fixedY * height).rounded()))
    }

    mutating func learn(target: PointerVision.Point, landed: PointerVision.Point) {
        let commanded = units(x: target.x, y: target.y)
        xSamples.append(Sample(commanded: Double(commanded.x) / width, landed: landed.x))
        ySamples.append(Sample(commanded: Double(commanded.y) / height, landed: landed.y))
        xSamples = Array(xSamples.suffix(12))
        ySamples = Array(ySamples.suffix(12))
    }
}

@MainActor
final class PointerController {
    private let passport: PassportBLEClient
    private let capture: ScreenCaptureService
    private var calibration: PointerCalibration?
    private let nudge = 12
    private let calibrationKey = "pointer-calibration-v2"

    init(passport: PassportBLEClient, capture: ScreenCaptureService) {
        self.passport = passport
        self.capture = capture
        if let data = UserDefaults.standard.data(forKey: calibrationKey) {
            calibration = try? JSONDecoder().decode(PointerCalibration.self, from: data)
        }
    }

    func invalidate() { calibration = nil }

    func calibrate() async throws {
        try await command("home")
        var samples: [(units: Double, point: PointerVision.Point)] = []
        var previous = 0
        for units in [150, 350] {
            try await command("move \(units - previous) \(units - previous)")
            try await Task.sleep(for: .milliseconds(350))
            guard let point = try await locatePointer(expectedShift: 0.025) else {
                calibration = nil
                throw PointerError.pointerNotFound
            }
            samples.append((Double(units), point)); previous = units
        }
        guard let width = fittedSpan(samples.map { ($0.units, $0.point.x) }),
              let height = fittedSpan(samples.map { ($0.units, $0.point.y) }) else {
            throw PointerError.invalidCalibration
        }
        guard width > 250, width < 4000, height > 250, height < 5000 else {
            throw PointerError.invalidCalibration
        }
        calibration = PointerCalibration(
            width: width,
            height: height,
            xSamples: samples.map { .init(commanded: $0.units / width, landed: $0.point.x) },
            ySamples: samples.map { .init(commanded: $0.units / height, landed: $0.point.y) }
        )
        saveCalibration()
    }

    func tap(pixelX: Int, pixelY: Int, imageWidth: Int = 768, imageHeight: Int = 1366) async throws {
        if calibration == nil { try await calibrate() }
        guard var calibration else { throw PointerError.notCalibrated }
        let target = PointerVision.Point(
            x: min(max(Double(pixelX) / Double(imageWidth), 0), 1),
            y: min(max(Double(pixelY) / Double(imageHeight), 0), 1)
        )
        let destination = calibration.units(x: target.x, y: target.y)
        try await command("home")
        try await command("move \(destination.x) \(destination.y)")
        try await Task.sleep(for: .milliseconds(150))
        if let actual = try await locatePointer(expectedShift: Double(nudge) / calibration.width,
                                                near: target, searchEverywhere: true) {
            let miss = max(abs(actual.x - target.x), abs(actual.y - target.y))
            if miss <= 0.06 {
                calibration.learn(target: target, landed: actual)
                self.calibration = calibration
                saveCalibration()
            }
            if abs(actual.x - target.x) > 0.008 || abs(actual.y - target.y) > 0.008 {
                let correctionX = Int(((target.x - actual.x) * calibration.width).rounded())
                let correctionY = Int(((target.y - actual.y) * calibration.height).rounded())
                try await command("move \(correctionX) \(correctionY)")
            }
        }
        try await command("click")
    }

    private func locatePointer(expectedShift: Double, near: PointerVision.Point? = nil,
                               searchEverywhere: Bool = false) async throws -> PointerVision.Point? {
        guard let before = capture.snapshot() else { return nil }
        let direction = (near?.x ?? 0.5) < 0.9 ? nudge : -nudge
        try await command("move \(direction) 0")
        try await Task.sleep(for: .milliseconds(350))
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(900))
        var found: PointerVision.Point?
        while ContinuousClock.now < deadline {
            guard let after = capture.snapshot(), after.sequence > before.sequence else {
                try? await Task.sleep(for: .milliseconds(60)); continue
            }
            let shift = expectedShift * (direction > 0 ? 1 : -1)
            found = PointerVision.locate(before: before.data, after: after.data,
                                         expectedShift: shift, near: near)
            if found == nil, searchEverywhere {
                found = PointerVision.locate(before: before.data, after: after.data,
                                             expectedShift: shift)
            }
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try await command("move \(-direction) 0")
        return found
    }

    private func command(_ value: String) async throws {
        let reply = try await passport.send(value)
        guard reply == "ok" else { throw AgentError.command(reply) }
    }

    private func fittedSpan(_ samples: [(units: Double, fraction: Double)]) -> Double? {
        let meanUnits = samples.map(\.units).reduce(0, +) / Double(samples.count)
        let meanFraction = samples.map(\.fraction).reduce(0, +) / Double(samples.count)
        let covariance = samples.reduce(0) { $0 + ($1.units - meanUnits) * ($1.fraction - meanFraction) }
        let variance = samples.reduce(0) { $0 + pow($1.fraction - meanFraction, 2) }
        guard variance > 0.002 else { return nil }
        return covariance / variance
    }

    private func saveCalibration() {
        guard let calibration, let data = try? JSONEncoder().encode(calibration) else { return }
        UserDefaults.standard.set(data, forKey: calibrationKey)
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
