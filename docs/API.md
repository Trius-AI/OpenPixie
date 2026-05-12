## API

### WebSocket (`/ws`)

The primary interface. Connect with `ws://host:8080/ws?token=<API_KEY>`.

**Client → Server:**

| Type | Description |
|------|-------------|
| `connect` | Connect to or create a topic |
| `chat` | Send a message (triggers agent loop) |
| `new_topic` | Create a new conversation topic |
| `switch_topic` | Switch to a different topic |
| `list_topics` | Request topic list for sidebar |
| `resolve_topic` | Mark topic as resolved |
| `tool_confirm` | Approve/deny a pending tool execution |
| `set_permission_mode` | Change permission mode |
| `interrupt` | Kill the running agent process |
| `heartbeat` | Respond to server heartbeat |

**Server → Client:**

| Type | Description |
|------|-------------|
| `connected` | Connection established with history |
| `response` | Agent finished responding |
| `chunk` | Streaming text from LLM |
| `thinking` | Agent is processing |
| `tool_step` | Tool execution progress |
| `kirino_check` | Kirino watchdog checking a self-modification |
| `kirino_result` | Kirino validation result (passed/rejected/warned) |
| `dashboard_refresh_hint` | Dashboard was modified, refresh to see changes |
| `error` | Error occurred |

See [`docs/INTERNAL.md`](docs/INTERNAL.md) for the complete protocol specification.

### REST

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | No | Health check |
| POST | `/api/v1/chat` | Yes | Synchronous chat |
| GET | `/api/v1/topics` | Yes | List topics |
| POST | `/api/v1/topics` | Yes | Create topic |
| DELETE | `/api/v1/topics/:id` | Yes | Delete topic |
| GET | `/api/v1/models` | Yes | List Ollama models |
| GET | `/api/v1/skills` | Yes | List skills |

Auth via `Authorization: Bearer <key>` header or `?key=<key>` query param.
