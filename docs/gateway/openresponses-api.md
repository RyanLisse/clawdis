---
summary: "OpenResponses API endpoint for agentic workflows with item-based inputs and semantic streaming"
read_when:
  - Integrating with OpenResponses-compatible clients
  - Building agentic applications with tool calling
  - Migrating from Chat Completions to the modern Responses API
---
# OpenResponses API (HTTP)

Clawdbot's Gateway implements the [OpenResponses](https://www.open-responses.com/) specification, an open inference standard designed for agentic workflows.

> [!NOTE]
> OpenResponses is the **recommended API** for new integrations. The legacy [Chat Completions endpoint](/gateway/openai-http-api) remains available for compatibility.

## Quick Start

```bash
curl -X POST http://127.0.0.1:18789/v1/responses \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "clawdbot",
    "input": "Hello, what can you help me with?"
  }'
```

## Enabling the Endpoint

The endpoint is **disabled by default**. Enable it in your config:

```json5
{
  gateway: {
    http: {
      endpoints: {
        responses: { enabled: true }
      }
    }
  }
}
```

## Authentication

Uses Gateway auth configuration. Send a bearer token:

```text
Authorization: Bearer <token>
```

- When `gateway.auth.mode="token"`, use `gateway.auth.token` (or `CLAWDBOT_GATEWAY_TOKEN`).
- When `gateway.auth.mode="password"`, use `gateway.auth.password`.

## Request Format

### Simple String Input

```json
{
  "model": "clawdbot",
  "input": "What's the weather like?"
}
```

### Item-Based Input (Conversations)

```json
{
  "model": "clawdbot",
  "input": [
    { "type": "message", "role": "system", "content": "You are a helpful assistant." },
    { "type": "message", "role": "user", "content": "Hello!" },
    { "type": "message", "role": "assistant", "content": "Hi there! How can I help?" },
    { "type": "message", "role": "user", "content": "What's 2+2?" }
  ]
}
```

### With Images

```json
{
  "model": "clawdbot",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        { "type": "input_image", "source": { "type": "url", "url": "https://example.com/photo.jpg" } },
        { "type": "input_text", "text": "What's in this image?" }
      ]
    }
  ]
}
```

### With Client Tools

```json
{
  "model": "clawdbot",
  "input": [{ "type": "message", "role": "user", "content": "What's the weather in Paris?" }],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
          "type": "object",
          "properties": { "location": { "type": "string" } },
          "required": ["location"]
        }
      }
    }
  ]
}
```

## Choosing an Agent

Encode the agent ID in the model field:

- `model: "clawdbot:<agentId>"` (e.g., `"clawdbot:main"`, `"clawdbot:beta"`)

Or use the header:

- `x-clawdbot-agent-id: <agentId>` (default: `main`)

## Session Behavior

By default, each request creates a new session. To maintain conversation state:

- Include `user: "your-user-id"` in the request body
- Or use `x-clawdbot-session-key: <sessionKey>` header

## Streaming (SSE)

Set `stream: true` for Server-Sent Events:

```bash
curl -N http://127.0.0.1:18789/v1/responses \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "clawdbot",
    "stream": true,
    "input": "Tell me a story"
  }'
```

### Streaming Events

| Event Type | Description |
|------------|-------------|
| `response.created` | Response object created |
| `response.output_item.added` | New output item started |
| `response.content_part.added` | Content part started |
| `response.output_text.delta` | Text chunk (incremental) |
| `response.output_text.done` | Text content complete |
| `response.content_part.done` | Content part complete |
| `response.output_item.done` | Output item complete |
| `response.completed` | Response finished |
| `[DONE]` | Stream terminated |

## Response Format

```json
{
  "id": "resp_abc123",
  "object": "response",
  "created_at": 1705678901,
  "status": "completed",
  "model": "clawdbot",
  "output": [
    {
      "type": "message",
      "id": "msg_xyz789",
      "role": "assistant",
      "content": [{ "type": "output_text", "text": "Hello! I'm here to help." }]
    }
  ],
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "total_tokens": 0
  }
}
```

## Supported Features

| Feature | Status |
|---------|--------|
| String input | ✅ |
| Item-based input (messages) | ✅ |
| System/developer messages | ✅ |
| Conversation history | ✅ |
| `function_call_output` items | ✅ |
| Images (`input_image`) | ✅ |
| Files (`input_file`) | ✅ |
| Client tools | ✅ |
| Streaming (SSE) | ✅ |
| Instructions field | ✅ |

## Migration from Chat Completions

| Chat Completions | OpenResponses |
|-----------------|---------------|
| `messages` array | `input` (string or items) |
| `role: "system"` | `type: "message", role: "system"` |
| Tool results in messages | `type: "function_call_output"` |
| `data: [DONE]` | `event: [DONE]` with `data: [DONE]` |

## See Also

- [OpenResponses Specification](https://www.open-responses.com/)
- [Chat Completions (Legacy)](/gateway/openai-http-api)
