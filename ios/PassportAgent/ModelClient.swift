import Foundation

struct ModelSettings: Codable, Sendable {
    var endpoint = "https://api.openai.com/v1/chat/completions"
    var model = "gpt-5-mini"
}

struct ModelClient: Sendable {
    let settings: ModelSettings
    let apiKey: String

    func next(task: String, imageJPEG: Data, history: [String]) async throws -> ModelStep {
        guard let url = URL(string: settings.endpoint), url.scheme == "https" else { throw ModelError.invalidEndpoint }
        let prompt = """
        You control an iPhone/iPad with a calibrated pointer and HID keyboard. Complete this task: \(task)
        Choose exactly one next action. Recent observations and outcomes: \(history.suffix(12).joined(separator: "; "))
        For tap, use dx and dy as normalized coordinates from 0 to 1000 across the visible screenshot,
        with (0,0) at the top-left and (1000,1000) at the bottom-right. Never emit raw mouse move,
        click, press, or release actions; every visual click must use tap so calibration and correction run.
        Return JSON only: {"observation":"...","action":{"action":"device_home|tap|scroll|type|key|wait|user_action|finish", ...}}
        scroll uses vertical/horizontal; wait uses milliseconds. Use wait when the screen is transitioning.
        Do not finish merely because one attempt was uncertain. Finish only after the screenshot visibly confirms
        success, or after explaining a genuine blocker. If the next step requires a password, passcode, biometric
        confirmation, payment data or approval, or account deletion confirmation, return user_action with a short
        reason telling the user exactly what to complete. Never type, click, approve, infer, or expose that sensitive
        information yourself, and never finish or report a blocker merely because user action is required. The app
        will wait indefinitely without repeatedly calling you; after the user changes the screen, you will receive a
        new screenshot and must inspect it, continue the original task, or request user_action again if it is still
        required. Ordinary navigation and permission screens may be handled when required by the task.
        """
        let body: [String: Any] = [
            "model": settings.model,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"]]
            ]]],
            "response_format": ["type": "json_object"]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw ModelError.http(String(data: data, encoding: .utf8) ?? "HTTP error") }
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = envelope.choices.first?.message.content.data(using: .utf8) else { throw ModelError.empty }
        return try JSONDecoder().decode(ModelStep.self, from: content)
    }
}

private struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
enum ModelError: LocalizedError {
    case invalidEndpoint, http(String), empty

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "API 地址无效"
        case let .http(message): "模型请求失败：\(message)"
        case .empty: "模型返回为空"
        }
    }
}
