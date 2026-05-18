# OpenPixie Internal Documentation

> **Canonical reference for self-modification safety.**
> This document describes every protocol, API, data structure, and behavioral contract
> that the running system depends on. Any self-modification MUST preserve these contracts
> or update this document accordingly.

---

## 1. Architecture Overview

OpenPixie is an Erlang/OTP application that provides an autonomous AI assistant with self-modification capabilities. It connects to an Ollama LLM backend and exposes both a WebSocket interface (for the real-time dashboard) and a REST API (for programmatic access).

```
┌─────────────────────────────────────────────────────────┐
│  Docker Container                                       │
│                                                         │
│  ┌──────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │ Frontend │◄──►│  Cowboy HTTP │    │  LLM (Ollama) │  │
│  │ Dashboard│    │  + WebSocket │───►│  API          │  │
│  └──────────┘    └──────┬───────┘    └───────────────┘  │
│                         │                                │
│                    ┌────▼─────┐                          │
│                    │  Agent   │                          │
│                    │  Loop    │                          │
│                    └────┬─────┘                          │
│                         │                                │
│         ┌───────────────┼───────────────┐                │
│         │               │               │                │
│    ┌────▼────┐   ┌──────▼──────┐  ┌────▼─────┐          │
│    │ Topics  │   │  Tools &    │  │  Memory  │          │
│    │ (gen_   │   │  Permissions│  │  & Soul  │          │
│    │ server) │   │             │  │          │          │
│    └─────────┘   └─────────────┘  └──────────┘          │
│                                                         │
│  /data/pixie/     ← Runtime state directory              │
│  /data/workspace/ ← Source code (self-modifiable)        │
│  /opt/openpixie/  ← Release base (read-only)            │
└─────────────────────────────────────────────────────────┘
```

### Supervisor Tree

```
openpixie_sup (one_for_one)
├── openpixie_auth          (worker, permanent)
├── openpixie_permissions   (worker, permanent)
├── openpixie_circuit_breaker (worker, permanent)
├── openpixie_semaphore     (worker, permanent)
├── openpixie_skills       (worker, permanent)
├── openpixie_memory       (worker, permanent)
├── openpixie_channel      (worker, permanent)
├── openpixie_topic_store  (worker, permanent)
├── openpixie_cron         (worker, permanent)
├── openpixie_metrics      (worker, permanent)
├── openpixie_archive      (worker, permanent)
├── openpixie_guardian      (worker, permanent)
├── openpixie_topic_sup    (supervisor, simple_one_for_one, transient)
│   └── openpixie_topic*   (worker, transient)  — dynamically spawned
└── openpixie_http         (supervisor)
    └── cowboy_http_listener (port 8080)
```

---

## 2. Module Index

| Module | Type | Responsibility |
|--------|------|---------------|
| `openpixie_app` | application | Startup, directory init, workspace code path |
| `openpixie_sup` | supervisor | Root supervisor, starts all permanent children |
| `openpixie_config` | module | Configuration access, env vars, file-based config |
| `openpixie_auth` | gen_server | API key SHA-256 authentication |
| `openpixie_http` | supervisor | Cowboy routes, port binding, static file serving |
| `openpixie_ws` | cowboy_ws | WebSocket handler: all real-time client communication |
| `openpixie_http_health` | cowboy_handler | `GET /health` — health check |
| `openpixie_http_chat` | cowboy_handler | `POST /api/v1/chat` — synchronous chat |
| `openpixie_http_topics` | cowboy_handler | `GET/POST/DELETE /api/v1/topics` |
| `openpixie_http_skills` | cowboy_handler | `GET /api/v1/skills` |
| `openpixie_http_models` | cowboy_handler | `GET /api/v1/models` |
| `openpixie_http_recover` | cowboy_handler | `POST /recover` — crash recovery |
| `openpixie_topic_sup` | supervisor | Dynamic topic process supervisor |
| `openpixie_topic` | gen_server | Conversation topic lifecycle & message journal |
| `openpixie_topic_store` | gen_server | Topic registry (ETS), persistence, archival |
| `openpixie_channel` | gen_server | Named channels for organizing topics |
| `openpixie_ollama` | module | Ollama API client (sync, stream, tools) |
| `openpixie_context` | module | System prompt builder, context trimming |
| `openpixie_tools` | module | Tool dispatch registry & schema aggregation |
| `openpixie_tools_file` | module | File I/O tools (read, write, edit, verify) |
| `openpixie_tools_git` | module | Git operation tools |
| `openpixie_tools_command` | module | Shell command execution |
| `openpixie_tools_search` | module | grep/find file search |
| `openpixie_tools_memory` | module | Memory search & retrieval |
| `openpixie_tools_skills` | module | Skill listing & loading |
| `openpixie_tools_self` | module | Self-modification tools (compile, reload, soul) |
| `openpixie_tools_meta` | module | Metacognitive tools (metrics, snapshots) |
| `openpixie_tools_schema` | module | Tool argument validation & type coercion |
| `openpixie_permissions` | gen_server | Permission modes (trust/ask/plan/sandbox) |
| `openpixie_soul` | module | SOUL.md personality management with proposal workflow |
| `openpixie_memory` | gen_server | Long-term memory storage & condensation |
| `openpixie_skills` | gen_server | Skill scanning, loading, YAML frontmatter parsing |
| `openpixie_circuit_breaker` | gen_server | LLM call circuit breaker (closed/open/half-open) |
| `openpixie_semaphore` | gen_server | LLM concurrency limiter |
| `openpixie_metrics` | gen_server | Time-series metrics recording & trend analysis |
| `openpixie_cron` | gen_server | Scheduled tasks (reflection, condensation, archival) |
| `openpixie_archive` | gen_server | SOUL.md + source code snapshots |
| `openpixie_guardian` | gen_server | Self-modification watchdog (validation + documentation sync) |
| `openpixie_reflection` | module | Self-reflection engine |
| `openpixie_log` | module | Logging wrapper (lager fallback) |
| `openpixie_setup` | module | First-run setup wizard |

---

## 3. WebSocket Protocol

The WebSocket connection is established at `ws://<host>:<port>/ws` (or `wss://` for HTTPS).

### 3.1 Authentication

Authentication must occur at connection time. Three methods are supported:

1. **Query parameter**: `ws://host:8080/ws?token=<API_KEY>`
2. **Authorization header**: `Authorization: Bearer <API_KEY>`
3. **Same-origin**: If the `Origin` header matches the `Host` header, authentication is bypassed (for dashboard usage)

If authentication fails, the connection is rejected with HTTP 401.

### 3.2 Message Format

All messages are JSON text frames. Every message has a `"type"` field.

### 3.3 Client → Server Messages

| Type | Fields | Description |
|------|--------|-------------|
| `connect` | `topic_id?` | Connect to an existing topic (by ID) or create a new one (omit `topic_id`) |
| `chat` | `content` (string) | Send a user message in the current topic. Triggers agent loop. |
| `new_topic` | `title?`, `channel_id?`, `parent_id?` | Create a new topic |
| `switch_topic` | `topic_id` | Switch to a different topic |
| `list_topics` | `channel_id?` | Request topic list for sidebar |
| `resolve_topic` | `topic_id` | Mark a topic as resolved |
| `reopen_topic` | `topic_id` | Reopen a resolved topic |
| `delete_topic` | `topic_id` | Permanently delete a topic |
| `tool_confirm` | `approved` (boolean) | Approve or deny a pending tool execution |
| `frontend_error` | `message`, `source?`, `lineno?`, `colno?`, `stack?` | Report a frontend JS error |
| `heartbeat` | _(none)_ | Respond to server heartbeat |
| `interrupt` | _(none)_ | Kill the running agent process |

### 3.4 Server → Client Messages

| Type | Fields | Description |
|------|--------|-------------|
| `connected` | `topic_id`, `history`, `title`, `channel_id`, `status?`, `parent_id?` | Connection established; includes conversation history |
| `response` | `message` (`{content: string}`) | Agent finished; final response content |
| `chunk` | `content` (string) | Streaming text chunk from LLM |
| `thinking` | `topic_id` | Agent is processing (show thinking indicator) |
| `stream_done` | _(none)_ | Streaming complete for this turn |
| `tool_step` | `tool`, `args`, `status` (`running`/`done`/`approved`/`denied`/`timeout`) | Tool execution progress |
| `guardian_check` | `tool`, `args` | Guardian watchdog is checking this self-modification tool |
| `guardian_result` | `tool`, `status` (`passed`/`rejected`/`warned`), `reason?` | Guardian watchdog validation result |
| `tool_confirm_request` | `tool`, `args`, `reason` | Tool requires user approval |
| `tool_approved` | `tool` | Confirmation: tool was approved |
| `tool_rejected` | `tool` | Confirmation: tool was denied |
| `topic_created` | `topic_id`, `title`, `channel_id`, `parent_id?` | New topic created |
| `topic_switched` | `topic_id`, `history`, `title?`, `channel_id?`, `status?` | Switched to a different topic |
| `topics_list` | `topics` (array), `channels` (array) | Full topic/channel listing for sidebar |
| `topic_resolved` | `topic_id` | Topic marked resolved |
| `topic_reopened` | `topic_id` | Topic reopened |
| `topic_deleted` | `topic_id` | Topic deleted |
| `topic_reopened` | `topic_id` | Topic was reopened (sent from `handle_reopen_topic`) |
| `topic_ended` | `topic_id`, `reason` | Topic process died |
| `session_ended` | `reason` | Unknown process died |
| `heartbeat` | _(none)_ | Server heartbeat (client must reply with `heartbeat`) |
| `interrupted` | _(none)_ | Agent was interrupted |
| `error` | `error`, `message?` | General error |

### 3.5 Heartbeat Protocol

- Server sends `heartbeat` every 30 seconds (`?HEARTBEAT_INTERVAL = 30000`)
- Client must respond with `{"type":"heartbeat"}` 
- If server sends heartbeat and receives no client response within 60 minutes (`?HEARTBEAT_TIMEOUT = 3600000`), the connection is closed
- Heartbeat timers are paused while a `tool_confirm_request` is pending

### 3.6 Agent Loop Flow (WebSocket)

When the client sends `{"type":"chat","content":"..."}`:

1. Server sends `{"type":"thinking","topic_id":"..."}` immediately
2. Server spawns a new agent process
3. Agent acquires semaphore (`openpixie_semaphore`), calls Ollama streaming API
4. Each LLM token chunk → server sends `{"type":"chunk","content":"..."}`
5. If LLM returns tool calls:
   - Server sends `{"type":"tool_step","tool":"...","args":{...},"status":"running"}`
   - If tool is self-modification (Guardian-relevant) → server sends `{"type":"guardian_check","tool":"...","args":{...}}` immediately after tool_step
   - After tool execution → if Guardian was engaged, server sends `{"type":"guardian_result","tool":"...","status":"passed|rejected|warned","reason":"..."}`
   - After tool execution → server sends `{"type":"tool_step","tool":"...","args":{...},"status":"done"}` (or `approved`/`denied`/`timeout`)
   - If tool requires confirmation → server sends `{"type":"tool_confirm_request",...}`, waits up to 600 seconds
   - Loop back to step 3 with tool results appended to history
6. When LLM returns no tool calls → server sends `{"type":"response","message":{"content":"..."}}`
7. Maximum loop iterations: 200

### 3.7 Error Handling

Errors are returned as `{"type":"error","error":"<code>","message":"<human text>"}`.

Known error codes:
- `no_active_topic` — no topic connected
- `topic_died` — topic process crashed
- `topic_not_found` — topic ID doesn't exist
- `topic_load_failed` — topic exists but can't be loaded
- `missing_topic_id` — required `topic_id` field missing
- `unknown_message_type` — unrecognized `"type"` field
- `agent_crash` — agent process crashed
- `max_iterations` — agent exceeded 200 tool loops
- `circuit_open` — circuit breaker tripped
- `confirmation_denied` — user denied tool execution
- `confirmation_timeout` — tool approval timed out
- `guardian_rejected` — Guardian watchdog blocked a self-modification

---

## 4. REST API

### 4.1 Authentication

All API endpoints (except `/health`) require an API key via:
- `Authorization: Bearer <API_KEY>` header, OR
- `?key=<API_KEY>` query parameter (chat endpoint only)

### 4.2 Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | No | Health check (`{status, ollama, uptime_seconds}`) |
| POST | `/api/v1/chat` | Yes | Synchronous chat (blocking, returns full response) |
| GET | `/api/v1/topics` | Yes | List topics (`?channel=<id>` filter) |
| POST | `/api/v1/topics` | Yes | Create topic (`{title, channel_id, parent_id?}`) |
| DELETE | `/api/v1/topics/:id` | Yes | Delete topic |
| GET | `/api/v1/models` | Yes | List Ollama models |
| GET | `/api/v1/skills` | Yes | List skills |
| POST | `/recover` | Yes | Crash recovery |
| GET | `/ws` | Token/Origin | WebSocket upgrade |
| GET | `/` | — | Dashboard (static HTML) |

### 4.3 Chat API Details

**POST `/api/v1/chat`**

Request body:
```json
{
  "content": "user message text",
  "topic_id": "optional_existing_topic_id"
}
```

Response body:
```json
{
  "type": "response",
  "message": {"content": "assistant response text"},
  "topic_id": "topic_id",
  "tool_steps": [...]
}
```

The HTTP chat endpoint auto-approves all tool confirmations (unlike WebSocket where the user can deny).

### 4.4 HTTP Status Codes

- `200` — Success
- `201` — Created (topic)
- `401` — Unauthorized
- `405` — Method Not Allowed
- `503` — Ollama unavailable

---

## 5. Topic Lifecycle

### 5.1 Topic States

```
                 ┌─────────┐
     start() ──► │ active  │
                 └────┬────┘
                      │ no subscribers + idle timeout
                      ▼
                 ┌─────────┐
                 │  idle   │
                 └────┬────┘
                      │ user sends message
                      ▼
                 ┌─────────┐
                 │ active  │ ◄── reopen
                 └────┬────┘
                      │ resolve()
                      ▼
                 ┌─────────┐
                 │resolved │ ── reopen() ──► active
                 └────┬────┘
                      │ archive_idle cron
                      ▼
                 ┌─────────┐
                 │archived │ (terminal, data moved to archive/topics/)
                 └─────────┘
```

### 5.2 Topic Persistence

Each topic stores data in `<topics_dir>/<topic_id>/`:
- `context.json` — metadata (id, channel_id, title, status, token_count, timestamps)
- `conversation.jsonl` — append-only message journal (one JSON object per line)

### 5.3 Topic Eviction

- Every 60 seconds, each topic process checks its last activity
- If no subscribers AND idle > `idle_evict_minutes` (default 1440 = 24h), process stops
- If no subscribers AND idle > `idle_timeout_minutes` (default 30m), status changes to `idle`
- `archive_idle` cron job (daily 02:00) moves old resolved/idle topics to archive

---

## 6. Tool System

### 6.1 Tool Registry

Tools are registered in `openpixie_tools:dispatch/2`. The full dispatch table:

| Tool Name | Module | Category |
|-----------|--------|----------|
| `read_file` | `openpixie_tools_file` | file |
| `write_file` | `openpixie_tools_file` | file |
| `edit_file` | `openpixie_tools_file` | file |
| `create_directory` | `openpixie_tools_file` | file |
| `list_files` | `openpixie_tools_file` | file |
| `file_exists` | `openpixie_tools_file` | file |
| `verify_file` | `openpixie_tools_file` | file |
| `git_status` | `openpixie_tools_git` | git |
| `git_diff` | `openpixie_tools_git` | git |
| `git_log` | `openpixie_tools_git` | git |
| `git_add` | `openpixie_tools_git` | git |
| `git_commit` | `openpixie_tools_git` | git |
| `git_branch` | `openpixie_tools_git` | git |
| `git_stash` | `openpixie_tools_git` | git |
| `git_pull` | `openpixie_tools_git` | git |
| `git_push` | `openpixie_tools_git` | git |
| `git_remote` | `openpixie_tools_git` | git |
| `run_command` | `openpixie_tools_command` | command |
| `grep_files` | `openpixie_tools_search` | search |
| `find_files` | `openpixie_tools_search` | search |
| `search_memories` | `openpixie_tools_memory` | memory |
| `recent_memories` | `openpixie_tools_memory` | memory |
| `list_skills` | `openpixie_tools_skills` | skills |
| `load_skill` | `openpixie_tools_skills` | skills |
| `compile_and_reload` | `openpixie_tools_self` | self-modification |
| `reload_module` | `openpixie_tools_self` | self-modification |
| `get_self_modules` | `openpixie_tools_self` | self-modification |
| `analyze_self` | `openpixie_tools_self` | self-modification |
| `list_models` | `openpixie_tools_self` | self-modification |
| `show_model` | `openpixie_tools_self` | self-modification |
| `propose_soul_edit` | `openpixie_tools_self` | self-modification |
| `get_soul_proposal` | `openpixie_tools_self` | self-modification |
| `apply_soul_proposal` | `openpixie_tools_self` | self-modification |
| `reject_soul_proposal` | `openpixie_tools_self` | self-modification |
| `get_performance_trend` | `openpixie_tools_meta` | metacognitive |
| `get_improvements` | `openpixie_tools_meta` | metacognitive |
| `save_snapshot` | `openpixie_tools_meta` | metacognitive |
| `list_snapshots` | `openpixie_tools_meta` | metacognitive |
| `load_snapshot` | `openpixie_tools_meta` | metacognitive |

| `register_tool` | `openpixie_tools_self` | self-modification |
| `list_schedules` | `unknown` | unknown |
| `git_remote` | `openpixie_tools_git` | git |
| `read_file` | `openpixie_tools_file` | file |
| `reject_soul_proposal` | `openpixie_tools_self` | self-modification |
| `create_directory` | `openpixie_tools_file` | file |
| `git_status` | `openpixie_tools_git` | git |
| `search_memories` | `openpixie_tools_memory` | memory |
| `ask_user` | `openpixie_tools_ask` | interaction |
| `sync_import` | `openpixie_tools_sync` | self-modification |
| `unregister_tool` | `openpixie_tools_self` | self-modification |
| `edit_file` | `openpixie_tools_file` | file |
| `cancel_schedule` | `unknown` | unknown |
| `analyze_self` | `openpixie_tools_self` | self-modification |
| `get_self_modules` | `openpixie_tools_self` | self-modification |
| `find_files` | `openpixie_tools_search` | search |
| `list_files` | `openpixie_tools_file` | file |
| `recent_memories` | `openpixie_tools_memory` | memory |
| `run_command` | `openpixie_tools_command` | command |
| `get_soul_proposal` | `openpixie_tools_self` | self-modification |
| `write_file` | `openpixie_tools_file` | file |
| `propose_soul_edit` | `openpixie_tools_self` | self-modification |
| `load_snapshot` | `openpixie_tools_meta` | metacognitive |
| `push_message` | `unknown` | unknown |
| `git_log` | `openpixie_tools_git` | git |
| `get_improvements` | `openpixie_tools_meta` | metacognitive |
| `self_improve` | `unknown` | unknown |
| `git_branch` | `openpixie_tools_git` | git |
| `list_skills` | `openpixie_tools_skills` | skills |
| `git_stash` | `openpixie_tools_git` | git |
| `save_snapshot` | `openpixie_tools_meta` | metacognitive |
| `compile_and_reload` | `openpixie_tools_self` | self-modification |
| `git_commit` | `openpixie_tools_git` | git |
| `schedule_prompt` | `unknown` | unknown |
| `git_pull` | `openpixie_tools_git` | git |
| `get_performance_trend` | `openpixie_tools_meta` | metacognitive |
| `grep_files` | `openpixie_tools_search` | search |
| `file_exists` | `openpixie_tools_file` | file |
| `show_model` | `openpixie_tools_self` | self-modification |
| `sync_export` | `openpixie_tools_sync` | self-modification |
| `git_add` | `openpixie_tools_git` | git |
| `git_push` | `openpixie_tools_git` | git |
| `git_diff` | `openpixie_tools_git` | git |
| `list_snapshots` | `openpixie_tools_meta` | metacognitive |
| `schedule_message` | `unknown` | unknown |
| `list_models` | `openpixie_tools_self` | self-modification |
| `verify_file` | `openpixie_tools_file` | file |
| `apply_soul_proposal` | `openpixie_tools_self` | self-modification |
| `reload_module` | `openpixie_tools_self` | self-modification |
| `load_skill` | `openpixie_tools_skills` | skills |
### 6.2 Tool Execution Pipeline

```
LLM returns tool_calls
        │
        ▼
openpixie_tools_schema:validate(Name, Args)
        │
        ▼
openpixie_permissions:check(Name, Args)
        │
   ┌────┼────────────┐
   │    │             │
allow  ask          deny
   │    │             │
   ▼    ▼             ▼
   │   → WS: tool_confirm_request  → {error, permission_denied}
   │         │
   │    ┌────┴─────┐
   │  approved    denied
   │    │           │
   │    │      {error, confirmation_denied}
   ▼    ▼
openpixie_guardian:is_guardian_relevant(Name, Args)?
   │
   ├── no ──► dispatch
   │
   └── yes
       │
       ▼
   openpixie_guardian:pre_check(Name, Args)
       │
  ┌────┼──────────┐
  │    │           │
 ok  warn       reject
  │    │           │
  ▼    ▼           ▼
dispatch       dispatch   {error, guardian_rejected}
  │    │
  ▼    ▼
openpixie_guardian:post_check(Name, Args, Result)
       │
  ┌────┴───────┐
  │            │
 ok    {update_doc, Changes}
  │            │
  ▼            ▼
return     update docs/INTERNAL.md
result     → write guardian_state.json
```

### 6.3 Permission Modes

| Mode | Behavior |
|------|----------|
| `trust` | All tools always allowed |
| `ask` | Read-only tools auto-allowed; self-modification tools + write tools require confirmation |
| `sandbox` | Self-modification tools denied; read-only auto-allowed; write requires confirmation |
| `plan` | Only read-only tools allowed; all writes denied |

**Readonly tools**: `read_file`, `list_files`, `file_exists`, `grep_files`, `find_files`, `git_status`, `git_log`, `git_diff`, `list_models`, `show_model`, `list_skills`, `load_skill`, `search_memories`, `recent_memories`, `get_self_modules`, `analyze_self`, `get_soul_proposal`, `list_snapshots`, `health`, `get_performance_trend`, `get_improvements`

**Self-modification tools**: `reload_module`, `deploy_module`, `compile_and_reload`, `edit_file`, `write_file`, `propose_soul_edit`, `apply_soul_proposal`, `reject_soul_proposal`

### 6.4 Tool Schema Format

Each tool's schema is defined in its module's `schema/0` function. The format follows Ollama's tool calling convention:

```erlang
#{
    type => function,
    function => #{
        name => tool_name,        % binary
        description => <<"...">>, % binary
        parameters => #{
            type => object,
            properties => #{
                param_name => #{type => string, description => <<"...">>}
            },
            required => [param_name]
        }
    }
}
```

### 6.5 Tool Result Format

All tools return maps with at minimum:
- `success` (boolean) — whether the tool execution succeeded
- On success: tool-specific fields
- On failure: `error` (atom/binary) describing the failure, plus optional `reason`

### 6.6 Self-Modification Safety Mechanisms

1. **Auto-checkpoint**: Before `write_file` or `edit_file` on a `.erl` or `index.html` file, git auto-commits the current state (`maybe_auto_checkpoint`)
2. **Compile-and-reload revert**: If `compile_and_reload` fails compilation, the source file is auto-reverted via `git checkout`
3. **File locking**: `write_file` and `edit_file` use an ETS-based file lock to prevent concurrent writes
4. **Path validation**: All file operations validate the target path is within the workspace directory
5. **SOUL proposal workflow**: Soul edits go through propose → review → apply/reject, with git commit on apply
6. **Confirmations**: In `ask`/`sandbox` modes, dangerous tools require explicit user approval

---

## 7. Ollama Integration

### 7.1 API Endpoints Used

| Ollama Endpoint | Method | OpenPixie Function |
|----------------|--------|-------------------|
| `/api/chat` | POST | `chat/2`, `chat_with_tools/3`, `stream_chat_with_tools/4` |
| `/api/tags` | GET | `list_models/0` |
| `/api/show` | POST | `show_model/1` |

### 7.2 Streaming Protocol

The streaming chat uses hackney's async mode. Each newline-delimited JSON chunk contains:
```json
{"message": {"content": "...", "tool_calls": [...]}, "done": false}
```
Final chunk: `{"done": true}`

### 7.3 Tool Calling

Tool schemas are sent in the `tools` field of the chat request. The Ollama model may return `tool_calls` in its response message. Each tool call has the structure:
```json
{
  "id": "call_id",
  "function": {
    "name": "tool_name",
    "arguments": {"key": "value"}
  }
}
```

### 7.4 Rate Limiting & Resilience

- **Semaphore**: Limits concurrent LLM calls (`max_llm_concurrency`, default 1)
- **Circuit Breaker**: Trips after N consecutive failures (`circuit_breaker_failures`, default 5), cooldown period (`circuit_breaker_cooldown_ms`, default 30s)
- **Retry**: Streaming calls retry up to 3 times with exponential backoff on transient errors (429, 503, 500, timeout, econnrefused, connection lost)
- **Context Trimming**: If conversation exceeds `max_context_tokens`, oldest messages are evicted (tool results first), with optional LLM-based summarization

### 7.5 Token Counting

Tokens are estimated at 4 characters per token (char count / 4). This is a rough approximation used for context window management only.

---

## 8. Data Layout

### 8.1 Directory Structure

```
/opt/openpixie/           — Release (read-only in Docker)
├── bin/openpixie         — Start script
├── releases/             — OTP release
├── src/                  — Source files (copied to workspace at startup)
├── priv/
│   ├── dashboard/index.html  — Frontend
│   ├── skills/               — Built-in skills
│   └── soul_templates/       — Default SOUL.md template
└── log/

/data/pixie/              — Runtime state (OPENPIXIE_DIR)
├── config.json           — Configuration file
├── API_KEY                — Generated API key
├── SOUL.md                — Current personality definition
├── SOUL.md.proposed       — Pending soul edit proposal
├── IMPROVEMENTS.md        — Improvement history (JSONL)
├── memories/
│   ├── MEMORY.md          — Top-level memory
│   ├── years/INDEX.md     — Yearly indices
│   ├── <year>/INDEX.md    — Yearly summary
│   └── <year>/month/<month>/INDEX.md — Monthly summaries
│       └── <day>.md       — Daily memories
├── topics/
│   └── <topic_id>/
│       ├── context.json   — Topic metadata
│       └── conversation.jsonl — Message journal
├── channels/
│   └── <channel_name>.json
├── skills/                — User-defined skills
└── archive/
    ├── <snapshot_id>/
    │   ├── metadata.json
    │   ├── SOUL.md
    │   └── src/            — Archived BEAM files
    └── topics/             — Archived topics

/data/workspace/           — Self-modifiable source (OPENPIXIE_WORKSPACE)
├── .git/                  — Git repository for tracking changes
├── src/                   — Erlang source (synced from release)
├── priv/                  — Frontend + skills (synced from release)
├── ebin/                  — Compiled BEAM files (for hot-reload)
└── .gitignore
```

### 8.2 Configuration File Format

`config.json` (in pixie dir):
```json
{
  "ollama_host": "http://localhost:11434",
  "ollama_model": "glm-5:cloud",
  "workspace": "/data/workspace",
  "http_port": 8080,
  "permission_mode": "ask",
  "api_key_hash": "<sha256 hex of api key>"
}
```

### 8.3 Environment Variable Overrides

| Env Var | Config Key | Conversion |
|---------|-----------|------------|
| `OPENPIXIE_DIR` | `pixie_dir` | string |
| `OPENPIXIE_WORKSPACE` | `workspace` | string |
| `OPENPIXIE_PORT` | `http_port` | integer |
| `OLLAMA_HOST` | `ollama_host` | string |
| `OLLAMA_MODEL` | `ollama_model` | binary |

### 8.4 Key Configuration Defaults

| Key | Default | Description |
|-----|---------|-------------|
| `http_port` | 8080 | HTTP listener port |
| `ollama_host` | `http://localhost:11434` | Ollama API URL |
| `ollama_model` | `glm-5:cloud` | Default model |
| `permission_mode` | `ask` | Tool permission mode |
| `idle_timeout_minutes` | 30 | Topic idle → idle status |
| `idle_evict_minutes` | 1440 | Topic idle → stop (24h) |
| `max_llm_concurrency` | 1 | Simultaneous LLM calls |
| `circuit_breaker_failures` | 5 | Failures before circuit opens |
| `circuit_breaker_cooldown_ms` | 30000 | Circuit breaker cooldown |
| `llm_timeout_ms` | 36000000 | LLM request timeout (10h) |
| `max_context_tokens` | 128000 | Context window limit |
| `reflection_hour` | 22 | Daily reflection time |

---

## 9. Frontend (Dashboard)

### 9.1 Location

The dashboard is a single HTML file: `priv/dashboard/index.html` (929 lines, self-contained HTML+CSS+JS).

### 9.2 Authentication Flow

1. Page loads → check `sessionStorage` for `openpixie_api_key`
2. If no key → show login form
3. User enters key → stored in `sessionStorage` → connect WebSocket with `?token=` parameter
4. On auth failure → clear `sessionStorage` → show login

### 9.3 Frontend Architecture

- **Single-page app** with no framework
- WebSocket is the sole communication channel
- Each browser tab gets a unique `tabId` (stored in `sessionStorage` via `crypto.randomUUID()`)
- Last active topic per tab stored in `localStorage` as `openpixie_last_topic_<tabId>`
- Per-topic UI state (`topicStates` object) saves/restores `isSending`, `hasToolConfirm`, `toolConfirmData` when switching topics

### 9.4 Frontend Error Reporting

The frontend sets `window.onerror` and `unhandledrejection` handlers that send `{"type":"frontend_error",...}` to the backend. The backend extracts source context around the error line from the dashboard HTML and feeds it back to the agent as a `tool` message with `name: "frontend_error"`.

### 9.5 Tool Confirmation UI

When the server sends `tool_confirm_request`, a fixed bar appears at the bottom with Allow/Deny buttons. The bar is associated with the `agentTopicId` (the topic the agent is running for), not necessarily the currently-viewed topic.

---

## 10. Scheduled Tasks (Cron)

| Job Name | Schedule | Function | Description |
|----------|----------|----------|-------------|
| `day_condense` | Daily 23:00 | `openpixie_memory:condense_day/0` | Condense day memories |
| `daily_reflection` | Daily `reflection_hour` (default 22) | `openpixie_reflection:reflect/0` | Self-reflection + soul proposals |
| `archive_idle` | Daily 02:00 | `openpixie_topic_store:archive_idle/0` | Archive old idle/resolved topics |

Cron specs supported: `{daily, Hour}`, `{interval, Minutes}`, `{monthly, Day}`, `{yearly, Month, Day}`.

---

## 11. Memory System

### 11.1 Storage

Memories are Markdown files organized hierarchically:
- Daily: `memories/<year>/month/<month>/<day>.md`
- Monthly index: `memories/<year>/month/<month>/INDEX.md`
- Yearly index: `memories/<year>/INDEX.md`
- Master: `memories/MEMORY.md`

### 11.2 Typed Memories

`save_typed_memory(Type, Content, Confidence)` appends to the current day file:
```
[insight] 2024-01-15T14:30:00 Some observation (confidence: 0.85)
```

### 11.3 Condensation

The `condense_day` cron job collects all topic `memory.md` files, sends them to the LLM for summarization, and writes the result to the day file. Monthly and yearly condensation further summarize lower-level files.

### 11.4 Search

`search_memories/1` recursively finds all `.md` files under `memories/` and does a binary substring match. Returns file path and 100-character excerpt around the match.

---

## 12. Soul System

### 12.1 SOUL.md

The personality definition file at `<pixie_dir>/SOUL.md`. Its content is injected into the system prompt.

### 12.2 Proposal Workflow

1. `propose_soul_edit(content)` — writes content to `SOUL.md.proposed`
2. `get_soul_proposal()` — reads the pending proposal
3. `apply_soul_proposal(approval)` — atomically moves proposal to `SOUL.md`, deletes proposal file, git commits
4. `reject_soul_proposal(reason)` — deletes proposal file

---

## 13. Reflection System

The `daily_reflection` cron job:

1. Saves a `pre_reflection` snapshot
2. Gathers recent conversations + performance metrics + improvement history + current SOUL.md
3. Calls LLM with a structured prompt asking for JSON output
4. Parses the response, which may contain: analysis, memory entry, soul proposal, improvement record
5. Applies: saves typed memory, proposes soul edit (if any), records improvement

---

## 14. Archive System

Snapshots capture the current SOUL.md and all loaded OpenPixie BEAM modules:
- Saved to `<archive_dir>/<label>_<timestamp_base36>/`
- Contains: `metadata.json`, `SOUL.md`, `src/*.beam`

---

## 15. Docker Distribution

### 15.1 Dockerfile

Multi-stage build:
1. **Build stage** (`erlang:28`): `rebar3 as prod release`, copies source + priv
2. **Runtime stage** (`erlang:28-slim`): Copies release, source, priv, entrypoint script

### 15.2 Entrypoint

`docker-entrypoint.sh` performs:
1. Resolves `host.docker.internal` on Linux
2. Creates data directories
3. Syncs source/priv from `/opt/openpixie/` to workspace
4. Clears stale BEAM files
5. Writes `.gitignore`
6. Initializes git repo + baseline commit
7. Sets env vars and execs the release

### 15.3 Volumes & Ports

- Port: 8080 (configurable via `OPENPIXIE_PORT`)
- Volume: `/data` (contains both pixie dir and workspace)
- Health check: `curl -f http://localhost:8080/health`

---

## 16. Behavioral Contracts for Self-Modification

This section defines the invariants that MUST hold for the system to function correctly after a self-modification and reload.

### 16.1 WebSocket Protocol Contract

- Every client message MUST have a `"type"` field; unknown types get `{"type":"error","error":"unknown_message_type"}`
- The `handle_chat` function requires `current_topic_id` to be set; sending chat without a topic returns `no_active_topic`
- Tool confirmation uses a blocking receive with 600s timeout; the `pending_confirmation` state field must be cleared after resolution
- Heartbeat timer references must be cancelled on connection close or confirmation flow
- Agent process is spawned per chat message; its PID is tracked in `agent_ref` state field for interrupt support

### 16.2 Topic Process Contract

- Topic processes are `gen_server` with `transient` restart (won't restart if stopped normally)
- `topic_store` ETS table records: `{TopicId, Pid | undefined, Status, ChannelId, Title}`
- A topic can be resumed from disk if its directory exists under `topics_dir`
- `context.json` must contain at minimum: `id`, `channel_id`, `title`, `status`
- `conversation.jsonl` must have one valid JSON object per line

### 16.3 Tool Schema/Dispatch Contract

- `openpixie_tools:tool_schema/0` aggregates schemas from all tool modules
- `openpixie_tools:dispatch/2` maps tool names to module functions
- Adding a new tool requires: (1) schema in the module's `schema/0`, (2) dispatch clause in `openpixie_tools:dispatch/2`, (3) validation in `openpixie_tools_schema`
- Tool arguments must be binary keys in the `Args` map (not atoms)
- All tool modules accept a single `Args` map argument and return a map with at least `success` key

### 16.4 Permission Contract

- `openpixie_permissions:is_self_modification/1` defines which tools are self-modification tools
- `openpixie_permissions:is_readonly/1` defines which tools are read-only
- These lists must be kept in sync with `openpixie_tools:dispatch/2`

### 16.5 Configuration Contract

- All config access goes through `openpixie_config` functions
- Config can come from 3 sources (priority: env > file > app env defaults)
- `config.json` is written atomically (tmp + rename)
- Adding new config keys requires: (1) default in `openpixie_config`, (2) loader in `load_config/0`, (3) env override in `apply_env_overrides/0` if applicable

### 16.6 Frontend Contract

- Dashboard is a single `index.html` file
- It communicates exclusively via WebSocket at `/ws?token=<key>`
- JS globals used: `ws`, `apiKey`, `currentTopicId`, `currentTopicStatus`, `agentTopicId`, `heartbeatTimer`, `isSending`, `streamingEl`, `lastThinkingEl`, `lastToolStepEl`, `topicStates`, `currentToolConfirmData`, `tabId`
- `window.onerror` and `unhandledrejection` must be preserved for error reporting to backend
- The `TOOL_LABELS` object maps tool names to display labels

### 16.7 Process Registry Contract

- Named gen_servers registered with `{local, Module}`: auth, permissions, circuit_breaker, semaphore, skills, memory, channel, topic_store, cron, metrics, archive, guardian
- Topic processes are NOT registered; they are tracked by PID in ETS and state maps

### 16.8 Guardian (Watchdog) Contract

- Guardian (`openpixie_guardian`) is a gen_server registered as `openpixie_guardian` under `openpixie_sup`
- It hooks into `openpixie_tools:execute/3` via the `guardian_dispatch/3` helper
- `pre_check/2` is called before dispatch; `post_check/3` (with Result) is called after
- Only self-modification tool calls targeting system source paths engage Guardian (checked via `is_guardian_relevant/2`)
- Guardian failure (timeout, crash) MUST NOT block tool execution — the `guardian_dispatch` helper catches exit/timeouts and falls through to dispatch
- `docs/INTERNAL.md` missing → Guardian enters permissive mode (all checks return `ok` with critical log warnings)
- See `docs/GUARDIAN.md` for the full design

---

## Appendix A: Message Flow Sequence Diagrams

### A.1 WebSocket Chat with Tool Call

```
Client                  Server                  Topic Process          LLM (Ollama)
  │                        │                        │                     │
  │── chat ───────────────►│                        │                     │
  │                        │── send_message ───────►│                     │
  │                        │                        │                     │
  │◄── thinking ───────────│                        │                     │
  │                        │──[spawn agent]─────────┼────────────────────►│
  │                        │                        │                     │
  │◄── chunk ──────────────│◄── stream ────────────┼─────────────────────┤
  │◄── chunk ──────────────│                       │                     │
  │                        │                        │                     │
  │◄── stream_done ────────│                        │                     │
  │                        │──[if tool_calls]───────┼────────────────────►│
  │                        │                        │                     │
  │◄── tool_step(running)──│                        │                     │
  │                        │── execute tool ─────►│                     │
  │                        │                        │                     │
  │◄── tool_step(done) ────│                        │                     │
  │                        │──[loop back to LLM]───┼────────────────────►│
  │                        │                        │                     │
  │◄── chunk ──────────────│◄── stream ────────────┼─────────────────────┤
  │◄── response ──────────│                        │                     │
  │                        │                        │                     │
```

### A.2 Tool Confirmation Flow

```
Client                  Server                  Agent Process
  │                        │                        │
  │◄── tool_confirm_request─│◄── {ask, reason} ────│
  │                        │                        │
  │── tool_confirm(true) ─►│── {approved} ────────►│
  │◄── tool_approved ──────│                        │
  │                        │                  [dispatch executes]
   │◄── tool_step(done) ───│                        │

---

## 13. Instance Sync

The sync system enables bidirectional transfer of self-modification changes between a running OpenPixie instance and the host development repository.

### 13.1 How It Works

Each running instance maintains a git repository in its workspace directory. On first start, the entrypoint script copies source files from the release image and creates a "Baseline" commit. Subsequent restarts preserve the workspace (smart skip: if `.pixie_baseline` exists, the source copy is skipped).

When the agent modifies its own code via `edit_file`/`write_file`/`compile_and_reload`, these changes are tracked in the workspace git repo via auto-checkpoint commits.

### 13.2 API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/sync?action=export` | Download a git patch of all instance-local changes vs baseline |
| GET | `/api/v1/sync?action=diff` | Show a summary (stat) of instance-local changes |
| POST | `/api/v1/sync` | Import a patch: `{action: "import", patch: "<base64>"}` or plain text diff |

All endpoints require Bearer token authentication (same API key as other endpoints).

### 13.3 Agent Tools

| Tool | Description |
|------|-------------|
| `sync_export` | Returns the git patch content of all instance-local changes |
| `sync_import` | Applies a git patch to the running instance, auto-compiles changed Erlang modules |

These are classified as self-modification tools (require approval in ask/plan modes).

### 13.4 Host-Side Script

`sync.sh` provides a command-line interface:

```sh
./sync.sh export   # Download patch and apply to host repo
./sync.sh import   # Generate patch from host repo and push to instance
./sync.sh diff     # Show what changed inside the instance
```

Requires the API key (auto-detected from `data/pixie/API_KEY` or set via `OPENPIXIE_KEY`).

### 13.5 Recovery Dashboard

The `/recover` page includes "Export Changes" and "Import Changes" buttons in the "Sync Instance Changes" section.

### 13.6 Key Files

| File | Purpose |
|------|---------|
| `src/openpixie_sync.erl` | Core sync logic: `export_patch/0`, `import_patch/1`, `auto_compile_changed/0` |
| `src/openpixie_http_sync.erl` | HTTP handler for `/api/v1/sync` |
| `src/openpixie_tools_sync.erl` | Agent tool definitions and dispatch |
| `sync.sh` | Host-side convenience script |
| `docker-entrypoint.sh` | Smart skip: only copies source on first start |
```