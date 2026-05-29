# OpenPixie Capability State

> **Living document — maintained by the Guardian during self-improvement.**
> This file describes every capability the agent currently possesses, organized by subsystem.
> Use this as the primary reference when searching for improvement opportunities.
> Each section ends with a **Gaps & Improvement Opportunities** block highlighting known limitations.

---

## 1. Tool System

### 1.1 Tool Dispatch Pipeline

Every tool call passes through: **schema validation → type coercion → permission check → Guardian pre-check → dispatch → Guardian post-check → doc auto-update**.

- **45 static tools** in `openpixie_tools:schema()`
- **Dynamic tool registry** (`openpixie_tool_registry`) allows runtime registration/unregistration; persisted to `.tool_registry/tools.json`
- Tools are classified as `readonly`, `self_modification`, or `write` for permission gating

### 1.2 File Operations (`openpixie_tools_file`)

| Tool | Description |
|------|-------------|
| `read_file` | Read file content (relative to workspace) |
| `write_file` | Write content to file |
| `edit_file` | Find-and-replace: exact `old_string` → `new_string` |
| `create_directory` | Create a directory |
| `list_files` | List directory contents |
| `file_exists` | Check file existence |
| `verify_file` | Syntax validation: Erlang (compile), HTML (tag balance), JS (bracket balance) |

**Safeguards:** ETS file locking (30s timeout), workspace path validation, auto git-checkpoint before editing `.erl`/`.html`/`.js`.

#### Gaps & Improvement Opportunities
- No `move_file` or `rename_file` — must copy + delete
- `edit_file` rejects if `old_string` appears multiple times; no line-range or multi-occurrence edit
- `read_file` reads entire file; no offset/line-range support for large files
- `verify_file` JS validation is crude (bracket balance only)
- No diff viewing tool (agent must use `git_diff` or `run_command` with `diff`)

### 1.3 Git Operations (`openpixie_tools_git`)

| Tool | Operation |
|------|-----------|
| `git_status` | `git status --porcelain` |
| `git_diff` | `git diff [path]` |
| `git_log` | `git log --oneline -N` |
| `git_add` | `git add <path>` |
| `git_commit` | `git commit -m <msg>` |
| `git_branch` | List branches or `checkout -b <name>` |
| `git_stash` | `git stash` |
| `git_pull` | `git pull [remote]` |
| `git_push` | `git push [remote]` |
| `git_remote` | `git remote -v` or `git remote <action>` |

**Features:** SSH key support via `$PIXIE_DIR/ssh_key`, 30s timeout, output capped at 51,200 bytes, shell argument escaping.

#### Gaps & Improvement Opportunities
- No `git_merge`, `git_rebase`, `git_reset`, `git_fetch`, `git_checkout` (existing branch)
- No interactive git operations
- `git_branch` with name creates + switches (`checkout -b`), cannot just create
- No `git_tag` support
- No way to resolve merge conflicts programmatically

### 1.4 Shell Commands (`openpixie_tools_command`)

| Tool | Description |
|------|-------------|
| `run_command` | Execute shell command in workspace dir |

**Safeguards:** Injection check (rejects `<<<<<<<`/`>>>>>>>`), sandbox mode uses `bwrap`, 30s default timeout, output capped at 50KB.

#### Gaps & Improvement Opportunities
- No streaming output — collects all then returns
- Sandbox mode requires `bwrap` installed
- Injection check only catches merge conflict markers
- No way to run long-lived/background processes
- No environment variable control for commands

### 1.5 Search (`openpixie_tools_search`)

| Tool | Description |
|------|-------------|
| `grep_files` | Regex search: `grep -rn -E <pattern> <path>` |
| `find_files` | Glob search: `find <path> -name <glob>` |

Both capped at 100 results.

#### Gaps & Improvement Opportunities
- No context lines around matches (like `grep -C`)
- No file-type filtering (e.g., search only `.erl` files)
- No inverse search (exclude pattern)
- Cap of 100 results can miss matches in large codebases

### 1.6 Memory (`openpixie_tools_memory`)

| Tool | Description |
|------|-------------|
| `search_memories` | Full-text search across all memory files |
| `recent_memories` | Get paths of N most recent memory files |

#### Gaps & Improvement Opportunities
- No way to write/save memories from tool calls (only the agent loop saves via topic)
- No deletion of specific memories
- No memory summary/condensation trigger tool

### 1.7 Skills (`openpixie_tools_skills`)

| Tool | Description |
|------|-------------|
| `list_skills` | List available skill names + descriptions |
| `load_skill` | Load a skill's `SKILL.md` content |

#### Gaps & Improvement Opportunities
- No `create_skill` / `update_skill` / `delete_skill` via tool (only via REST API)
- No skill versioning or change history

### 1.8 Self-Modification (`openpixie_tools_self`)

| Tool | Description |
|------|-------------|
| `reload_module` | Hot-reload a BEAM module |
| `compile_and_reload` | Compile `.erl` from source + hot-load |
| `get_self_modules` | List all loaded `openpixie*` modules |
| `analyze_self` | System status (Ollama, CB, memory, metrics) |
| `list_models` / `show_model` | Query Ollama models |
| `propose_soul_edit` | Propose SOUL.md edit (requires user approval) |
| `get_soul_proposal` | View pending SOUL.md proposal |
| `apply_soul_proposal` | Apply approved SOUL.md edit |
| `reject_soul_proposal` | Reject pending SOUL.md proposal |
| `register_tool` / `unregister_tool` | Dynamic tool registration at runtime |

#### Gaps & Improvement Opportunities
- `analyze_self` returns flat data; no structured dependency graph
- No `unregister_tool` persistence across restarts
- No way to list dynamic vs static tools separately
- `compile_and_reload` fails if dependent modules aren't recompiled

### 1.9 Self-Improve (`openpixie_tools_self_improve`)

| Tool | Description |
|------|-------------|
| `self_improve` | Autonomous code edit: `issue`, `plan`, `file`, `old_string`, `new_string` |

**Behavior:** Finds/replaces code → compiles `.erl` → hot-reloads → git add/commit/push → records to `IMPROVEMENTS.md` → broadcasts notification. Max **5 edits per agent run**. On compile failure, edit is left in place with hint to retry.

#### Gaps & Improvement Opportunities
- `old_string` must be unique in file; no line-range edit support
- No dry-run / preview before applying
- No rollback on partial multi-step changes
- Always pushes to `origin`; no option to skip push
- No semantic understanding of code — purely textual matching

### 1.10 Metacognitive (`openpixie_tools_meta`)

| Tool | Description |
|------|-------------|
| `get_system_status` | Ollama status, uptime, topics, CB state, VM memory, metrics |
| `get_performance_trend` | Trend analysis of named metrics over time window |
| `get_improvements` | Read `IMPROVEMENTS.md` log |
| `save_snapshot` | Archive SOUL.md + source + metadata |
| `list_snapshots` | List snapshots, optionally filtered by label |
| `load_snapshot` | Load snapshot soul + metadata by ID |

#### Gaps & Improvement Opportunities
- `get_system_status` is a flat dump; no alerting or anomaly detection
- `get_performance_trend` only returns direction; no detailed analysis
- No `compare_snapshots` tool to diff two snapshots
- No automated rollback from a snapshot

### 1.11 Interaction (`openpixie_tools_ask`)

| Tool | Description |
|------|-------------|
| `ask_user` | Pause for human input; disabled in scheduled mode |

#### Gaps & Improvement Opportunities
- Only one question at a time; no multi-choice or structured input
- In scheduled mode, always fails — no async/deferred question queue

### 1.12 Push (`openpixie_tools_push`)

| Tool | Description |
|------|-------------|
| `push_message` | Send message to any topic conversation |

#### Gaps & Improvement Opportunities
- No way to push to all topics (broadcast)
- No message priority or urgency levels
- No message queueing for offline topics

### 1.13 Cron (`openpixie_tools_cron`)

| Tool | Description |
|------|-------------|
| `schedule_message` | Recurring message delivery |
| `schedule_prompt` | Schedule autonomous agent run |
| `list_schedules` | List scheduled jobs |
| `cancel_schedule` | Cancel a scheduled job |

**Schedule formats:** `daily:H`, `interval:M`, `monthly:D`, `yearly:M:D`. Persists across restarts.

#### Gaps & Improvement Opportunities
- `schedule_prompt` cannot be called from within a scheduled prompt (no nesting)
- No cron expression support (standard `* * * * *` format)
- No schedule editing (must cancel + recreate)
- No schedule status (last run, next run, success/failure history)
- No exponential backoff for failed scheduled prompts

### 1.14 Sync (`openpixie_tools_sync`)

| Tool | Description |
|------|-------------|
| `sync_export` | Export all instance-local changes as a git patch |
| `sync_import` | Import a git patch + auto-compile/reload changed modules |

#### Gaps & Improvement Opportunities
- No conflict resolution during import
- No partial sync (all-or-nothing)
- No sync status/history tracking
- No way to preview what an import would change before applying

---

## 2. WebSocket Protocol (`openpixie_ws`)

### 2.1 Client → Server

| Type | Description |
|------|-------------|
| `connect` | Connect to or create a topic |
| `chat` | Send message (triggers agent loop) |
| `new_topic` | Create a conversation topic |
| `switch_topic` | Switch to another topic |
| `list_topics` | List all topics |
| `resolve_topic` | Mark topic resolved |
| `reopen_topic` | Reopen a resolved topic |
| `delete_topic` | Delete a topic |
| `retry_from` | Retry from a specific message index |
| `tool_confirm` | Approve/deny tool execution |
| `ask_user_response` | Respond to agent question |
| `set_permission_mode` | Change permission mode |
| `get_config` / `set_config` | Read/write runtime config |
| `frontend_error` | Log frontend errors |
| `heartbeat` | Keep-alive ping |
| `interrupt` | Cancel current agent turn |
| `compact` | Compact conversation history |
| `rename_topic` | Rename a topic |

### 2.2 Server → Client

| Type | Description |
|------|-------------|
| `stream_chunk` / `stream_done` | Streaming LLM output |
| `message` | Complete message |
| `tool_step` | Tool execution progress |
| `tool_confirm_request` | Tool needs user confirmation |
| `ask_user_request` | Agent asks user a question |
| `guardian_check` / `guardian_result` | Guardian pre/post check notifications |
| `topic_list` | Topic listing |
| `dashboard_refresh_hint` | Dashboard file changed |
| `error` | Error messages |
| `heartbeat` | Heartbeat response |

### 2.3 Agent Turn Flow

Acquires LLM semaphore → builds system prompt → calls Ollama (with circuit breaker) → processes response → if tool calls, executes them (with permission + guardian checks) → feeds results back → loops until text-only response or max turns (5).

#### Gaps & Improvement Opportunities
- Max 5 tool-calling turns per agent response; complex tasks may need more
- No tool-call parallelism (serial execution only)
- No way to cancel a long-running tool mid-execution
- No partial streaming of tool results
- `retry_from` only retries from message index; no branch/fork from a point

---

## 3. REST API

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | No | System status |
| POST | `/api/v1/login` | Key | Create session |
| DELETE | `/api/v1/login` | Session | Logout |
| POST | `/api/v1/chat` | Yes | Synchronous chat |
| GET | `/api/v1/topics` | Yes | List topics |
| POST | `/api/v1/topics` | Yes | Create topic |
| DELETE | `/api/v1/topics/:id` | Yes | Delete topic |
| GET | `/api/v1/models` | Yes | List Ollama models |
| GET | `/api/v1/skills` | Yes | List skills |
| POST | `/api/v1/skills` | Yes | Create/update/delete/load/rescan skills |
| GET | `/api/v1/sync` | Yes | Export sync patch |
| POST | `/api/v1/sync` | Yes | Import sync patch |
| GET | `/api/v1/config` | Yes | Get config |
| POST | `/api/v1/config` | Yes | Update config |
| GET | `/api/v1/files` | Yes | Browse workspace files |
| GET | `/api/v1/pixie-data/:name` | Yes | Read internal data (SOUL, MEMORY, etc.) |
| GET | `/api/v1/tools` | Yes | List tools with permission info |
| POST | `/recover` | Yes | Crash recovery |
| GET | `/ws` | Token | WebSocket upgrade |

SPA routes: `/login`, `/dashboard`, `/chat`, `/chat/:topic_id`, `/settings`, `/guardian`, `/files`, `/skill2tool`

#### Gaps & Improvement Opportunities
- No batch API for multi-topic operations
- No WebSocket message history retrieval via REST
- No API versioning beyond `/v1`
- `/api/v1/chat` is synchronous only; no async REST chat
- No rate limiting on REST endpoints
- No CORS configuration
- No OpenAPI/Swagger spec

---

## 4. Agent Loop (`openpixie_agent`)

### 4.1 Interactive Mode (`start/2`)

Spawns a process with a real WebSocket PID for streaming and confirmation. Full tool access based on permission mode.

### 4.2 Standalone/Scheduled Mode (`start_standalone/3`)

Used for cron-triggered prompts. Sets `triggered_by=schedule`. Spawns a proxy that broadcasts via topic messages. **Restricted tools:** `ask_user` fails, `edit_file`/`write_file`/`compile_and_reload`/`reload_module`/`propose_soul_edit`/`apply_soul_proposal`/`sync_import`/`schedule_prompt` all blocked. Only `self_improve` is allowed for code changes.

#### Gaps & Improvement Opportunities
- Scheduled mode has no way to escalate to interactive mode for user input
- No timeout or watchdog for standalone agent runs
- No progress reporting during long scheduled runs
- No way to chain scheduled prompts (sequential dependencies)

---

## 5. Guardian System (`openpixie_guardian`)

### 5.1 Pre-Check Pipeline

Classifies tool calls → checks file content for dangerous patterns → enforces cooldowns → returns `reject`, `warn`, or `ok`.

### 5.2 Post-Check Pipeline

After tool execution → rebuilds snapshot → diffs old vs new snapshot → auto-updates `docs/INTERNAL.md` with changes (new modules, tools, routes, WS types, config keys).

### 5.3 Snapshot

Captures: modules + exports, tools + categories, routes, WS client/server types, config keys, permission self-mod tools, permission readonly tools. `snapshot_routes()` merges `?BASELINE_ROUTES` with live Cowboy dispatch routes.

### 5.4 State Persistence

Guardian state saved to `.pixie/guardian_state.json`.

#### Gaps & Improvement Opportunities
- Guardian only updates `INTERNAL.md`; does not update `CAPABILITIES.md`
- No automated test suite generation or verification after self-modification
- No rollback mechanism when Guardian detects post-check violations
- Guardian crash = tool execution continues (fail-open); could be fail-closed
- No Guardian audit trail beyond log messages

---

## 6. Cron System (`openpixie_cron`)

### 6.1 Built-in Scheduled Jobs

| Job | Schedule | Description |
|-----|----------|-------------|
| `day_condense` | Daily 23:00 | Memory condensation |
| `daily_reflection` | Configurable hour | Reflection on behavior |
| `archive_idle_topics` | Daily 02:00 | Archive idle resolved topics |

### 6.2 User-Scheduled Jobs

Created via `schedule_message` or `schedule_prompt`. Persisted to `.pixie/schedules/*.json`.

#### Gaps & Improvement Opportunities
- No job dependency management
- No retry/backoff for failed jobs
- No job status tracking (last run, next run, success count, failure count)
- No job priority levels
- Schedule format is limited; no standard cron expressions

---

## 7. Memory System (`openpixie_memory`)

### 7.1 Storage

Hierarchical: `.pixie/memories/{year}/month/{month}/{day}.md`

### 7.2 Operations

- `save_typed_memory(Type, Content, Confidence)` — append timestamped entries
- `search_memories(Query)` — full-text search across all `.md` files
- `recent_memories(N)` — N most recent memory file paths

### 7.3 Condensation

Daily cron at 23:00 uses LLM to summarize day's memories → monthly → yearly indexes. Retries up to 3 times on failure.

#### Gaps & Improvement Opportunities
- No structured query (by type, confidence, date range)
- No memory deletion or editing
- No memory expiration/retention policy
- Search is simple string matching; no semantic search
- Condensation is lossy; no way to recover original entries
- No memory versioning

---

## 8. Soul System (`openpixie_soul`)

### 8.1 SOUL.md

Defines personality, values, communication style. Injected into every system prompt.

### 8.2 Proposal Workflow

`propose_soul_edit` → saves to `SOUL.md.proposed` → user must `apply_proposal` or `reject_proposal`. Applied proposals are git-committed.

### 8.3 Initialization

`init_template/1` generates a default soul from config (name, personality, style).

#### Gaps & Improvement Opportunities
- No SOUL.md version history beyond git
- No way to A/B test personality changes
- Proposal workflow only works in interactive mode; scheduled mode cannot propose soul edits
- No soul validation (could break system prompt if malformed)

---

## 9. Permissions System (`openpixie_permissions`)

### 9.1 Modes

| Mode | Self-Mod | Write | Read | Command |
|------|----------|-------|------|---------|
| `trust` | Allow | Allow | Allow | Allow |
| `auto_noselfmod` | Ask | Allow | Allow | Allow |
| `ask` | Ask | Ask | Allow | Allow |
| `sandbox` | Deny | Ask | Allow | bwrap |
| `plan` | Deny | Deny | Allow | Deny |

### 9.2 Scheduled Mode Restrictions

When `triggered_by = schedule`: `edit_file`, `write_file`, `compile_and_reload`, `reload_module`, `propose_soul_edit`, `apply_soul_proposal`, `reject_soul_proposal`, `register_tool`, `unregister_tool`, `sync_import`, `schedule_prompt` are all blocked. Only `self_improve` is allowed for code changes.

#### Gaps & Improvement Opportunities
- No per-tool permission granularity (all-or-nothing per category)
- No role-based access (all users share one permission mode)
- No permission change audit trail
- `plan` mode denies all writes but can't propose changes for later approval
- No temporary permission escalation mechanism

---

## 10. Skills System (`openpixie_skills`)

### 10.1 Structure

Skills are directories containing `SKILL.md` files with YAML frontmatter (`description`, `always`, `tags`). Two directories: built-in (`priv/skills/`) and user (`.pixie/skills/`).

### 10.2 Operations

`list_skills()`, `load_skill(Name)`, `create_skill`, `update_skill`, `delete_skill`, `rescan()`. Always-loaded skills are injected into every system prompt.

#### Gaps & Improvement Opportunities
- No skill dependency management
- No skill versioning
- No skill testing/validation framework
- `rescan()` is manual; no filesystem watch
- No skill marketplace or sharing mechanism

---

## 11. Sync System (`openpixie_sync`)

### 11.1 Export

Commits dirty files → diffs from baseline commit to HEAD → produces unified diff patch.

### 11.2 Import

Writes patch to temp file → `git apply --3way` → commits → auto-compiles and hot-reloads changed `.erl` files.

### 11.3 Baseline

Maintains a "Baseline" git commit as the sync anchor point.

#### Gaps & Improvement Opportunities
- No conflict resolution during import
- No partial/incremental sync
- No sync status dashboard
- No way to preview import before applying
- No bidirectional auto-sync

---

## 12. Reflection System (`openpixie_reflection`)

### 12.1 Daily Reflection

Cron job at configurable hour (default 22:00). Reads recent memories + topic history → sends structured prompt to LLM → writes identified improvements to `IMPROVEMENTS.md`.

#### Gaps & Improvement Opportunities
- Reflection output is passive; no automatic action on identified improvements
- No reflection quality metric
- No way to trigger reflection manually via tool
- Reflection prompt is fixed; no adaptation over time

---

## 13. Archive System (`openpixie_archive`)

### 13.1 Snapshots

`save_snapshot(Label, Metadata)` saves SOUL.md + loaded module `.beam` files + metadata.json.

### 13.2 Topic Archiving

Idle resolved topics (>7 days) archived by cron at 02:00, moving from `topics/` to `archive/topics/`.

#### Gaps & Improvement Opportunities
- Snapshots don't include config or memory state
- No automated restore from snapshot
- No incremental snapshots (always full)
- No snapshot expiration/cleanup policy
- Archived topics can't be searched

---

## 14. Circuit Breaker (`openpixie_circuit_breaker`)

Classic 3-state: **closed** → **open** → **half-open**. Opens after N consecutive failures (default 5). Cooldown before half-open test (default 30s). Wraps all Ollama API calls.

#### Gaps & Improvement Opportunities
- No per-endpoint circuit breakers (one breaker for all Ollama calls)
- No circuit breaker metrics beyond basic state
- No warm-up period after recovery
- Half-open allows only one test call; no gradual ramp-up

---

## 15. Metrics System (`openpixie_metrics`)

ETS-backed time-series: `record/3`, `get_trend/2`, `get_statistics/1`, `get_all_keys/0`, `get_recent/2`. Auto-cleanup: entries older than 24 hours pruned hourly.

#### Gaps & Improvement Opportunities
- 24-hour retention only; no long-term metrics
- No histogram/percentile support
- No metric alerting or threshold triggers
- No metric export (Prometheus, etc.)
- Trend detection is simplistic (direction only)

---

## 16. Topic Lifecycle (`openpixie_topic`)

### 16.1 States

`active` → `idle` (30min timeout) → `evicted` (process stops, state to disk) → `resolved` (user marks done) → `archived` (cron after 7 days idle).

### 16.2 Features

Lazy-restart evicted topics on access, fork/child topics, history compaction, message journaling as JSONL.

#### Gaps & Improvement Opportunities
- No topic search (must list all then filter)
- No topic tagging or categorization beyond channels
- No topic export (e.g., to Markdown)
- No concurrent topic access by multiple agent instances
- No topic priority or pinning

---

## 17. Ollama Integration (`openpixie_ollama`)

`chat/3,4` (non-streaming), `chat_stream/5` (streaming with callback), `list_models/0`, `show_model/1`, `count_tokens/1` (rough: chars ÷ 4). All calls through circuit breaker + semaphore (default concurrency 1).

#### Gaps & Improvement Opportunities
- Token counting is approximate (chars ÷ 4); no tiktoken or model-specific tokenizer
- No model switching mid-conversation
- No fallback model if primary is unavailable
- No streaming error recovery (stream breaks = lost response)
- Semaphore default of 1 is conservative; no auto-tuning
- No request priority (all FIFO)

---

## 18. Context System (`openpixie_context`)

Builds system prompt from: SOUL.md + memory description + topic info + scheduled mode rules + self section (modules, exports, file tree) + settings + skills summary + tool schemas.

`trim_messages/2` removes oldest messages when exceeding `max_context_tokens` (default 128K).

#### Gaps & Improvement Opportunities
- No semantic context trimming (removes by recency, not relevance)
- No context window budgeting per section
- Self section (module exports) can be large and wastes tokens
- No caching of unchanged system prompt sections
- No way to inject temporary context (e.g., search results) efficiently

---

## 19. Configuration (`openpixie_config`)

Stored in `.pixie/config.json`. Key settings: `ollama_host`, `ollama_model`, `http_port` (8080), `workspace`, `permission_mode`, `max_context_tokens` (128K), `llm_timeout_ms` (36M), `circuit_breaker_failures` (5), `circuit_breaker_cooldown_ms` (30s), `idle_timeout_minutes` (30), `idle_evict_minutes` (1440), `reflection_hour` (22).

Environment overrides: `OLLAMA_HOST`, `OLLAMA_MODEL`, `OPENPIXIE_WORKSPACE`, `OPENPIXIE_PORT`, `OPENPIXIE_DIR`.

#### Gaps & Improvement Opportunities
- No config validation on write
- No config change notification to affected subsystems
- No config profiles (dev vs production)
- No config documentation generation

---

## 20. Auth System (`openpixie_auth`)

API key (SHA-256 hash in ETS). Session tokens: 32-byte hex, 24-hour TTL. WebSocket auth via `Bearer` header, `?token=` query, or `openpixie_session` cookie. Same-origin cookie for browsers.

#### Gaps & Improvement Opportunities
- No multi-user support (single API key)
- No RBAC or user roles
- No token refresh mechanism
- No IP-based restrictions
- No OAuth/external auth integration
- Session cleanup is periodic, not on-demand

---

## 21. LLM Semaphore (`openpixie_semaphore`)

Limits concurrent LLM calls (default 1). FIFO queue. Configurable via `max_llm_concurrency`.

#### Gaps & Improvement Opportunities
- No priority queuing
- No fairness guarantees beyond FIFO
- No timeout for queued requests
- No semaphore metrics (queue length, wait time)

---

## 22. Push Notification System (`openpixie_push`)

`notify(TopicId, Content)` sends message to existing topic. `prompt(TopicId, PromptContent)` spawns new standalone topic with autonomous agent, reports results back to originating topic.

#### Gaps & Improvement Opportunities
- No cross-instance push
- No push delivery guarantees (no ack/retry)
- No message queuing for offline topics
- `prompt` has no timeout; could run indefinitely

---

## 23. Frontend (Dashboard)

Single-page app served from `priv/dashboard/`. SPA routes: `/login`, `/dashboard`, `/chat`, `/chat/:topic_id`, `/settings`, `/guardian`, `/files`, `/skill2tool`. Features: real-time chat streaming, topic sidebar, tool confirmation dialogs, permission mode switcher, guardian dashboard, file browser, skill-to-tool converter.

#### Gaps & Improvement Opportunities
- No dark mode / theme support
- No keyboard shortcuts
- No search within conversations
- No file upload UI
- No mobile-responsive layout
- No offline/PWA support
- Guardian dashboard is read-only; no interactive controls

---

## Cross-Cutting Improvement Themes

These are systemic issues that span multiple subsystems:

1. **No structured error taxonomy** — errors are ad-hoc binaries; no error codes or categories for programmatic handling
2. **No health check beyond `/health`** — no deep liveness checks for subsystems (memory, guardian, cron, etc.)
3. **No observability pipeline** — logs go to console only; no structured logging, no log aggregation
4. **No test framework** — no unit, integration, or property-based tests; self-modification has no automated verification
5. **No graceful degradation** — subsystems fail independently without fallbacks
6. **Limited inter-subsystem communication** — topics, memory, skills, and tools are loosely coupled; no event bus
7. **No versioned API** — single `/v1`; no migration path for API changes
8. **Security surface** — single API key, no RBAC, command injection risks, no audit trail

---

*Last updated: 2026-05-20 by manual creation. Guardian should update this document when self-improvement changes capabilities.*

| `load_skill` | `openpixie_tools_skills` | skills |
| `code_graph` | `unknown` | unknown |
| `reload_module` | `openpixie_tools_self` | self-modification |
| `apply_soul_proposal` | `openpixie_tools_self` | self-modification |
| `verify_file` | `openpixie_tools_file` | file |
| `list_models` | `openpixie_tools_self` | self-modification |
| `schedule_message` | `unknown` | unknown |
| `list_snapshots` | `openpixie_tools_meta` | metacognitive |
| `git_diff` | `openpixie_tools_git` | git |
| `git_push` | `openpixie_tools_git` | git |
| `git_add` | `openpixie_tools_git` | git |
| `get_system_status` | `unknown` | unknown |
| `sync_export` | `openpixie_tools_sync` | self-modification |
| `show_model` | `openpixie_tools_self` | self-modification |
| `file_exists` | `openpixie_tools_file` | file |
| `grep_files` | `openpixie_tools_search` | search |
| `get_performance_trend` | `openpixie_tools_meta` | metacognitive |
| `git_pull` | `openpixie_tools_git` | git |
| `schedule_prompt` | `unknown` | unknown |
| `git_commit` | `openpixie_tools_git` | git |
| `compile_and_reload` | `openpixie_tools_self` | self-modification |
| `save_snapshot` | `openpixie_tools_meta` | metacognitive |
| `git_stash` | `openpixie_tools_git` | git |
| `list_skills` | `openpixie_tools_skills` | skills |
| `git_branch` | `openpixie_tools_git` | git |
| `self_improve` | `unknown` | unknown |
| `get_improvements` | `openpixie_tools_meta` | metacognitive |
| `git_log` | `openpixie_tools_git` | git |
| `push_message` | `unknown` | unknown |
| `load_snapshot` | `openpixie_tools_meta` | metacognitive |
| `propose_soul_edit` | `openpixie_tools_self` | self-modification |
| `write_file` | `openpixie_tools_file` | file |
| `get_soul_proposal` | `openpixie_tools_self` | self-modification |
| `run_command` | `openpixie_tools_command` | command |
| `recent_memories` | `openpixie_tools_memory` | memory |
| `list_files` | `openpixie_tools_file` | file |
| `find_files` | `openpixie_tools_search` | search |
| `get_self_modules` | `openpixie_tools_self` | self-modification |
| `analyze_self` | `openpixie_tools_self` | self-modification |
| `cancel_schedule` | `unknown` | unknown |
| `edit_file` | `openpixie_tools_file` | file |
| `unregister_tool` | `openpixie_tools_self` | self-modification |
| `sync_import` | `openpixie_tools_sync` | self-modification |
| `ask_user` | `openpixie_tools_ask` | interaction |
| `search_memories` | `openpixie_tools_memory` | memory |
| `git_status` | `openpixie_tools_git` | git |
| `create_directory` | `openpixie_tools_file` | file |
| `reject_soul_proposal` | `openpixie_tools_self` | self-modification |
| `read_file` | `openpixie_tools_file` | file |
| `git_remote` | `openpixie_tools_git` | git |
| `list_schedules` | `unknown` | unknown |
| `register_tool` | `openpixie_tools_self` | self-modification |