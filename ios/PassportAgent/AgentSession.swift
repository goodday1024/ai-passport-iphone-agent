import Foundation
import Observation

@MainActor
@Observable
final class AgentSession {
    private let passport: PassportBLEClient
    private let capture: ScreenCaptureService
    private let pointer: PointerController
    private var runTask: Task<Void, Never>?
    var settings: ModelSettings
    var status = "待机"
    var captureStatus = "未共享"
    var events: [String] = []
    var isRunning = false
    var passportStatus: String { passport.status }
    var currentAPIKey: String { KeychainStore.loadAPIKey() }

    init() {
        let passport = PassportBLEClient()
        let capture = ScreenCaptureService()
        self.passport = passport
        self.capture = capture
        pointer = PointerController(passport: passport, capture: capture)
        settings = (try? UserDefaults.standard.data(forKey: "model-settings").flatMap { try JSONDecoder().decode(ModelSettings.self, from: $0) }) ?? ModelSettings()
        capture.onStatus = { [weak self] value in Task { @MainActor in self?.captureStatus = value } }
    }

    func connectPassport() { passport.connect() }

    func saveSettings(endpoint: String, model: String, apiKey: String) {
        settings = ModelSettings(endpoint: endpoint, model: model)
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "model-settings") }
        KeychainStore.saveAPIKey(apiKey)
    }

    func start(task: String) async {
        guard !isRunning else { return }
        guard !currentAPIKey.isEmpty else { status = "请先配置 API Key"; return }
        isRunning = true; status = "请确认共享整个屏幕"; events.removeAll()
        capture.presentPicker()
        runTask = Task { [weak self] in await self?.run(task: task) }
    }

    func stop() {
        runTask?.cancel(); runTask = nil
        Task { _ = try? await passport.send("release"); await capture.stop() }
        isRunning = false; status = "已停止"
    }

    private func run(task: String) async {
        defer { runTask = nil; isRunning = false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        var consecutiveFailures = 0
        for _ in 0..<100 {
            if Task.isCancelled { return }
            guard ContinuousClock.now < deadline else { break }
            guard captureStatus == "共享中", let frame = capture.frame() else {
                try? await Task.sleep(for: .milliseconds(300)); continue
            }
            do {
                status = "正在理解画面"
                let step = try await ModelClient(settings: settings, apiKey: currentAPIKey).next(task: task, imageJPEG: frame, history: events)
                events.append(step.observation)
                switch step.action {
                case let .finish(summary):
                    status = summary
                    await finishTask()
                    return
                case let .wait(ms): try await Task.sleep(for: .milliseconds(min(max(ms, 100), 5000)))
                case let .tap(x, y):
                    let px = min(max(x, 0), 1000)
                    let py = min(max(y, 0), 1000)
                    status = "校准并点击：\(px), \(py)"
                    do {
                        try await pointer.tap(pixelX: px, pixelY: py, imageWidth: 1000, imageHeight: 1000)
                    } catch {
                        pointer.invalidate()
                        events.append("首次定位失败，正在重新校准：\(error.localizedDescription)")
                        try await pointer.tap(pixelX: px, pixelY: py, imageWidth: 1000, imageHeight: 1000)
                    }
                    events.append("精确点击 \(px),\(py) → ok")
                    try await Task.sleep(for: .milliseconds(650))
                case .move, .click, .press, .release:
                    throw AgentError.unsupportedRawPointerAction
                default:
                    guard let command = step.action.passportCommand else { continue }
                    status = "执行：\(command)"
                    let reply = try await passport.send(command)
                    events.append("\(command) → \(reply)")
                    guard reply == "ok" else { throw AgentError.command(reply) }
                    try await Task.sleep(for: .milliseconds(650))
                }
                consecutiveFailures = 0
            } catch {
                if Task.isCancelled { return }
                consecutiveFailures += 1
                events.append("第 \(consecutiveFailures) 次错误：\(error.localizedDescription)")
                if consecutiveFailures < 4 {
                    status = "暂时失败，正在重试（\(consecutiveFailures)/3）"
                    try? await Task.sleep(for: .milliseconds(900))
                    continue
                }
                status = "连续失败，任务已停止：\(error.localizedDescription)"
                await finishTask(); return
            }
        }
        status = "达到安全限制，任务已停止"; isRunning = false
        await finishTask()
    }

    private func finishTask() async {
        _ = try? await passport.send("release")
        await capture.stop()
    }
}

enum AgentError: LocalizedError {
    case command(String), unsupportedRawPointerAction

    var errorDescription: String? {
        switch self {
        case let .command(reply): "Passport 指令失败：\(reply)"
        case .unsupportedRawPointerAction: "模型返回了未经校准的鼠标动作"
        }
    }
}
