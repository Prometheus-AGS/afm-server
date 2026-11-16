# afm-server

An OpenAI-compatible HTTP API for Apple's on-device Foundation Model (Apple Intelligence), written in Swift with [Hummingbird](https://github.com/hummingbird-project/hummingbird).

Any tool that can talk to an OpenAI-style endpoint (LiteLLM, liter-llm, the OpenAI SDKs, curl) can use the model that ships with macOS. It runs on your Mac, offline, and nothing leaves the machine.

## Requirements

- macOS 26 or later on Apple silicon, with Apple Intelligence turned on (System Settings › Apple Intelligence & Siri)
- Xcode 26 or later, or a Swift 6.2 toolchain with the macOS 26 SDK

## Models

| Model id | What it is |
|---|---|
| `apple-on-device` | The general on-device model with Apple's default guardrails. This is the default when `model` is omitted. |
| `apple-on-device-permissive` | The same model with `permissiveContentTransformations` guardrails, for summarizing, rewriting or translating text you supply. |
| `apple-on-device-content-tagging` | Apple's content-tagging adapter, for topic tags and entity or action extraction. |

Apple's Private Cloud Compute model needs macOS 27 and isn't served.

## Install

```bash
# 1. Create an API key once (the service refuses to start without one)
echo "export AFM_API_KEY=\"afm-$(openssl rand -hex 32)\"" >> ~/.bash_profile

# 2. Build, install to ~/.local/bin, and load the LaunchAgent (port 11435)
scripts/install.sh
```

This installs:

- `~/.local/bin/afm-server`: the server.
- `~/.local/bin/afm-server-launch`: the launchd entry point. It reads only the `export AFM_API_KEY=...` line from `~/.bash_profile`, so the plist never holds the key.
- `~/Library/LaunchAgents/local.afm-server.plist`: starts at login and restarts on failure.

Logs go to `~/Library/Logs/afm-server.log`.

To restart: `launchctl kickstart -k gui/$(id -u)/local.afm-server`
To uninstall: `launchctl bootout gui/$(id -u)/local.afm-server && rm ~/Library/LaunchAgents/local.afm-server.plist ~/.local/bin/afm-server ~/.local/bin/afm-server-launch`

## Configuration

These are environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `AFM_HOST` | `127.0.0.1` | Address to bind to. Keep it on loopback unless you mean to expose it. |
| `AFM_PORT` | `11435` | Port. |
| `AFM_API_KEY` | (unset) | If set, every request except `/health` must send `Authorization: Bearer <key>`. |

## API

- `GET /health`: model availability. No key is needed.
- `GET /v1/models`
- `POST /v1/chat/completions`: with `stream: true` it streams over SSE.

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Authorization: Bearer $AFM_API_KEY" -H 'content-type: application/json' \
  -d '{"model":"apple-on-device","messages":[{"role":"user","content":"Summarize: ..."}]}'
```

### Behaviour and limits

- **Instructions:** `system` and `developer` messages become the session's instructions.
- **Conversation history:** earlier turns are written into the prompt as a transcript. Every request gets a fresh session, and nothing is kept between requests.
- **Honoured parameters:** `temperature`, `max_tokens` and `max_completion_tokens`.
- **Ignored:** tools, `response_format` and image or audio parts. `usage` is an estimate (about 4 characters per token).
- **Context window:** about 4K tokens in total, counting the prompt and the reply. Going over it returns 400 `context_length_exceeded`.
- **Error codes:**
  - A guardrail refusal returns 400 `content_filter`.
  - An unknown model returns 404 `model_not_found`.
  - A busy model returns 429.

## Using it from liter-llm or LiteLLM

```toml
[[models]]
name = "apple-on-device"
provider_model = "openai/apple-on-device"
api_key = "${AFM_API_KEY}"
base_url = "http://127.0.0.1:11435/v1"
```

Repeat this block for `apple-on-device-permissive` and `apple-on-device-content-tagging`. If the gateway runs under launchd, its own environment must contain `AFM_API_KEY`.

## Development

```bash
swift build
AFM_PORT=11499 .build/debug/afm-server
```

## License

MIT. See [LICENSE](LICENSE).
