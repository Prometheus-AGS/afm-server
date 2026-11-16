import Foundation
import FoundationModels

enum Engine {
    /// The model ids this server answers to, one per on-device configuration
    /// Apple's FoundationModels framework offers on macOS 26.
    static let models: [(id: String, make: @Sendable () -> SystemLanguageModel)] = [
        ("apple-on-device", { SystemLanguageModel(useCase: .general) }),
        ("apple-on-device-permissive", { SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations) }),
        ("apple-on-device-content-tagging", { SystemLanguageModel(useCase: .contentTagging) }),
    ]
    static let modelID = models[0].id

    static func model(for id: String?) throws -> SystemLanguageModel {
        guard let id, !id.isEmpty else { return models[0].make() }
        guard let m = models.first(where: { $0.id == id }) else {
            throw APIError(404, "Unknown model \"\(id)\". Available: \(models.map(\.id).joined(separator: ", ")).", code: "model_not_found")
        }
        return m.make()
    }

    static func availability() -> (ok: Bool, reason: String) {
        switch SystemLanguageModel.default.availability {
        case .available: return (true, "available")
        case .unavailable(let r): return (false, "\(r)")
        }
    }

    /// Splits an OpenAI conversation into instructions (system messages) and one
    /// prompt. Earlier turns are written into the prompt as a labelled transcript;
    /// each request gets a fresh session, so nothing is kept between requests.
    static func split(_ messages: [ChatMessage]) throws -> (instructions: String?, prompt: String) {
        let system = messages.filter { $0.role == "system" || $0.role == "developer" }.map(\.text)
        let turns = messages.filter { $0.role != "system" && $0.role != "developer" }
        guard let last = turns.last, last.role == "user" else {
            throw APIError(400, "The last message must have role \"user\".")
        }
        let history = turns.dropLast()
        var prompt = ""
        if !history.isEmpty {
            prompt += "Conversation so far:\n"
            for m in history {
                let who = m.role == "assistant" ? "Assistant" : (m.role == "user" ? "User" : m.role.capitalized)
                prompt += "\(who): \(m.text)\n"
            }
            prompt += "\nReply to the user's latest message:\n"
        }
        prompt += last.text
        return (system.isEmpty ? nil : system.joined(separator: "\n\n"), prompt)
    }

    static func options(_ req: ChatRequest) -> GenerationOptions {
        GenerationOptions(temperature: req.temperature, maximumResponseTokens: req.maxTokens)
    }

    static func session(_ model: SystemLanguageModel, _ instructions: String?) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    static func respond(_ req: ChatRequest) async throws -> String {
        let model = try model(for: req.model)
        let (instructions, prompt) = try split(req.messages)
        do {
            return try await session(model, instructions).respond(to: prompt, options: options(req)).content
        } catch {
            throw map(error)
        }
    }

    /// Yields the text as it grows, one piece at a time.
    static func stream(_ req: ChatRequest) throws -> AsyncThrowingStream<String, Error> {
        let model = try model(for: req.model)
        let (instructions, prompt) = try split(req.messages)
        let opts = options(req)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sent = ""
                    for try await snapshot in session(model, instructions).streamResponse(to: prompt, options: opts) {
                        let now = snapshot.content
                        if now.hasPrefix(sent) {
                            let piece = String(now.dropFirst(sent.count))
                            if !piece.isEmpty { continuation.yield(piece) }
                        } else {
                            // The model revised earlier text; send what is new from here on.
                            continuation.yield(now)
                        }
                        sent = now
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func map(_ error: Error) -> Error {
        if let e = error as? APIError { return e }
        guard let g = error as? LanguageModelSession.GenerationError else {
            return APIError(500, "\(error)", type: "server_error")
        }
        switch g {
        case .exceededContextWindowSize:
            return APIError(400, "The conversation is longer than the on-device model's context window.", code: "context_length_exceeded")
        case .guardrailViolation, .refusal:
            return APIError(400, "The on-device model declined this request (Apple's safety guardrails).", code: "content_filter")
        case .unsupportedLanguageOrLocale:
            return APIError(400, "The on-device model doesn't support this language.", code: "unsupported_language")
        case .rateLimited, .concurrentRequests:
            return APIError(429, "The on-device model is busy; try again.", type: "rate_limit_error")
        case .assetsUnavailable:
            return APIError(503, "The on-device model's assets aren't available right now.", type: "server_error")
        default:
            return APIError(500, "\(g)", type: "server_error")
        }
    }
}
