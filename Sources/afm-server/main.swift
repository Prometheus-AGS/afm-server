import Foundation
import Hummingbird
import NIOCore

// afm-server: an OpenAI-compatible HTTP API for Apple's on-device Foundation Model.
// Listens on 127.0.0.1 only. Environment:
//   AFM_HOST     default 127.0.0.1
//   AFM_PORT     default 11435
//   AFM_API_KEY  if set, requests must send "Authorization: Bearer <key>"

let env = ProcessInfo.processInfo.environment
let host = env["AFM_HOST"] ?? "127.0.0.1"
let port = Int(env["AFM_PORT"] ?? "") ?? 11435
let apiKey = env["AFM_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
let maxBody = 4 * 1024 * 1024

let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]; return e }()

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
}

func errorResponse(_ e: APIError) -> Response {
    json(e, status: HTTPResponse.Status(code: e.status))
}

struct AuthAndErrors<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let key = apiKey, request.uri.path != "/health",
           request.headers[.authorization] != "Bearer \(key)" {
            return errorResponse(APIError(401, "Missing or wrong API key.", type: "authentication_error"))
        }
        do {
            return try await next(request, context)
        } catch let e as APIError {
            return errorResponse(e)
        }
    }
}

func now() -> Int { Int(Date().timeIntervalSince1970) }

let router = Router()
router.add(middleware: AuthAndErrors())

router.get("/health") { _, _ -> Response in
    let a = Engine.availability()
    return json(["status": a.ok ? "ok" : "unavailable", "model": Engine.modelID, "availability": a.reason],
                status: a.ok ? .ok : .serviceUnavailable)
}

router.get("/v1/models") { _, _ -> Response in
    json(ModelList(data: Engine.models.map { .init(id: $0.id) }))
}

router.post("/v1/chat/completions") { request, _ -> Response in
    let a = Engine.availability()
    guard a.ok else { throw APIError(503, "Apple's on-device model is unavailable: \(a.reason)", type: "server_error") }

    let buffer = try await request.body.collect(upTo: maxBody)
    let req: ChatRequest
    do {
        req = try JSONDecoder().decode(ChatRequest.self, from: Data(buffer: buffer))
    } catch {
        throw APIError(400, "Couldn't read the request: \(error)")
    }
    let modelName = (req.model?.isEmpty == false ? req.model : nil) ?? Engine.modelID
    _ = try Engine.model(for: modelName)
    let id = "chatcmpl-\(UUID().uuidString.lowercased())"
    let created = now()
    let promptChars = req.messages.map(\.text).joined(separator: "\n")

    if req.stream == true {
        let pieces = try Engine.stream(req)
        let body = ResponseBody { writer in
            func send<T: Encodable>(_ v: T) async throws {
                let data = (try? encoder.encode(v)) ?? Data()
                var b = ByteBuffer(string: "data: ")
                b.writeBytes(data)
                b.writeString("\n\n")
                try await writer.write(b)
            }
            func chunk(_ delta: ChatChunk.Choice.Delta, _ finish: String?) -> ChatChunk {
                ChatChunk(id: id, created: created, model: modelName,
                          choices: [.init(delta: delta, finish_reason: finish)])
            }
            try await send(chunk(.init(role: "assistant", content: ""), nil))
            do {
                for try await piece in pieces {
                    try await send(chunk(.init(content: piece), nil))
                }
                try await send(chunk(.init(), "stop"))
            } catch let e as APIError {
                try await send(e)
            } catch {
                try await send(APIError(500, "\(error)", type: "server_error"))
            }
            try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
            try await writer.finish(nil)
        }
        return Response(status: .ok,
                        headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                        body: body)
    }

    let text = try await Engine.respond(req)
    return json(ChatCompletion(
        id: id, created: created, model: modelName,
        choices: [.init(message: .init(content: text), finish_reason: "stop")],
        usage: Usage(prompt_tokens: estimateTokens(promptChars), completion_tokens: estimateTokens(text))))
}

let app = Application(
    router: router,
    configuration: .init(address: .hostname(host, port: port), serverName: "afm-server")
)
print("afm-server: \(Engine.modelID) on http://\(host):\(port)/v1 (availability: \(Engine.availability().reason))")
try await app.runService()
