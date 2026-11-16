import Foundation

/// The subset of the OpenAI chat-completions API this server understands.
struct ChatRequest: Decodable, Sendable {
    var model: String?
    var messages: [ChatMessage]
    var temperature: Double?
    var max_tokens: Int?
    var max_completion_tokens: Int?
    var stream: Bool?

    var maxTokens: Int? { max_completion_tokens ?? max_tokens }
}

struct ChatMessage: Decodable, Sendable {
    var role: String
    var text: String

    private enum CodingKeys: String, CodingKey { case role, content }
    private struct Part: Decodable { var type: String; var text: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        if let s = try? c.decode(String.self, forKey: .content) {
            text = s
        } else if let parts = try? c.decode([Part].self, forKey: .content) {
            // Only text parts are supported; images and audio are dropped.
            text = parts.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        } else {
            text = ""
        }
    }
}

struct Usage: Encodable, Sendable {
    var prompt_tokens: Int
    var completion_tokens: Int
    var total_tokens: Int { prompt_tokens + completion_tokens }
    private enum CodingKeys: String, CodingKey { case prompt_tokens, completion_tokens, total_tokens }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(prompt_tokens, forKey: .prompt_tokens)
        try c.encode(completion_tokens, forKey: .completion_tokens)
        try c.encode(total_tokens, forKey: .total_tokens)
    }
}

struct ChatCompletion: Encodable, Sendable {
    struct Choice: Encodable, Sendable {
        struct Msg: Encodable, Sendable { var role = "assistant"; var content: String }
        var index = 0
        var message: Msg
        var finish_reason: String
    }
    var id: String
    var object = "chat.completion"
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: Usage
}

struct ChatChunk: Encodable, Sendable {
    struct Choice: Encodable, Sendable {
        struct Delta: Encodable, Sendable { var role: String?; var content: String? }
        var index = 0
        var delta: Delta
        var finish_reason: String?
    }
    var id: String
    var object = "chat.completion.chunk"
    var created: Int
    var model: String
    var choices: [Choice]
}

struct ModelList: Encodable, Sendable {
    struct Model: Encodable, Sendable {
        var id: String
        var object = "model"
        var created = 0
        var owned_by = "apple"
    }
    var object = "list"
    var data: [Model]
}

struct APIError: Error, Encodable, Sendable {
    struct Body: Encodable, Sendable { var message: String; var type: String; var code: String? }
    var status: Int
    var error: Body
    private enum CodingKeys: String, CodingKey { case error }

    init(_ status: Int, _ message: String, type: String = "invalid_request_error", code: String? = nil) {
        self.status = status
        self.error = Body(message: message, type: type, code: code)
    }
}

/// Rough token estimate for the `usage` field (about 4 characters a token).
func estimateTokens(_ s: String) -> Int { max(1, (s.utf8.count + 3) / 4) }
