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
        You control an iPhone/iPad using a relative BLE mouse and HID keyboard. Complete this task: \(task)
        Choose exactly one next action. Recent actions: \(history.suffix(10).joined(separator: "; "))
        The screenshot is 768 by 1366 pixels. Prefer tap with dx=x and dy=y absolute screenshot coordinates.
        Return JSON only: {"observation":"...","action":{"action":"device_home|tap|move|click|press|release|scroll|type|key|wait|finish", ...}}
        tap uses absolute dx/dy screenshot pixels; move uses relative units; scroll uses vertical/horizontal; wait uses milliseconds.
        Do not act on passwords, payments, account deletion, or permissions; finish with an explanation instead.
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
enum ModelError: Error { case invalidEndpoint, http(String), empty }
