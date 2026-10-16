import Foundation

enum AgentAction: Codable, Equatable, Sendable {
    case deviceHome
    case tap(x: Int, y: Int)
    case move(dx: Int, dy: Int)
    case click
    case press
    case release
    case scroll(vertical: Int, horizontal: Int)
    case type(String)
    case key(String)
    case wait(milliseconds: Int)
    case userAction(String)
    case finish(String)

    private enum CodingKeys: String, CodingKey { case action, dx, dy, vertical, horizontal, text, key, milliseconds, reason, summary }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .action) {
        case "device_home": self = .deviceHome
        case "tap": self = .tap(x: try c.decode(Int.self, forKey: .dx), y: try c.decode(Int.self, forKey: .dy))
        case "move": self = .move(dx: try c.decode(Int.self, forKey: .dx), dy: try c.decode(Int.self, forKey: .dy))
        case "click": self = .click
        case "press": self = .press
        case "release": self = .release
        case "scroll": self = .scroll(vertical: try c.decode(Int.self, forKey: .vertical), horizontal: try c.decodeIfPresent(Int.self, forKey: .horizontal) ?? 0)
        case "type": self = .type(try c.decode(String.self, forKey: .text))
        case "key": self = .key(try c.decode(String.self, forKey: .key))
        case "wait": self = .wait(milliseconds: try c.decode(Int.self, forKey: .milliseconds))
        case "user_action": self = .userAction(try c.decodeIfPresent(String.self, forKey: .reason) ?? "请在设备上完成敏感操作")
        case "finish": self = .finish(try c.decodeIfPresent(String.self, forKey: .summary) ?? "完成")
        default: throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "Unsupported action")
        }
    }

    func encode(to encoder: Encoder) throws { fatalError("AgentAction encoding is not used") }

    var passportCommand: String? {
        switch self {
        case .deviceHome: "key cmd+h"
        case .tap: nil
        case let .move(dx, dy): "move \(dx) \(dy)"
        case .click: "click"
        case .press: "press"
        case .release: "release"
        case let .scroll(v, h): "scroll \(v) \(h)"
        case .type: nil
        case let .key(key): "key \(key)"
        case .wait, .userAction, .finish: nil
        }
    }
}

struct ModelStep: Decodable, Sendable {
    let observation: String
    let action: AgentAction
}

enum ProtocolError: Error { case invalidCommand }

enum TextInputPlan: Equatable, Sendable {
    case hid(String)
    case paste(String)

    static func make(for text: String) -> TextInputPlan {
        if text.unicodeScalars.allSatisfy(\.isASCII) {
            return .hid(text.replacingOccurrences(of: "\n", with: " "))
        }
        return .paste(text)
    }
}
