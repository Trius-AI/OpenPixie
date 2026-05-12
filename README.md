# OpenPixie

> + Agents as operating systems
> + Tools as kernel system calls
> + Skills as applications
> + Chat sessions as processes

## What It Is

OpenPixie is an LLM-driven autonomous AI assistant built in Erlang/OTP. It can read and modify its own source code, hot-reload modules at runtime, edit its personality definition, and manage its own memory — all while staying running.

### "Read and modify its own source code"?

Try asking it simple prompts like "increase the size of the 'OpenPixie' text on the side bar" and "please change the color palette of the frontend to black & white" and see what it gets you.

## Features

- **Self-modification** — Edit source code, compile, and hot-reload without restart
- **Watchdog** — Validates self-modifications against documented contracts, auto-updates internal docs
- **Memory system** — Hierarchical daily/monthly/yearly condensation
- **SOUL.md** — Editable personality definition with human-in-the-loop approval
- **Skills** — Extensible skill system with YAML frontmatter
- **Daily reflection** — Self-reflection cron job that can propose personality improvements
- **Dashboard** — Single-page web UI with real-time streaming
- **REST + WebSocket APIs** — Full programmatic access
- **Permission system** — Three modes: auto-approve all, auto-approve non-self-mod, manual review
- **Circuit breaker** — Resilient LLM call handling with retry and backoff
- **Git integration** — All self-modifications tracked in git for rollback

## Quick Start

### Docker (recommended)

```bash
# Build
docker build -t openpixie:0.1.0 .

# Run
docker run -d --name openpixie \
  -p 8080:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v openpixie-data:/data \
  openpixie:0.1.0

# Get your API key
docker exec openpixie cat /data/pixie/API_KEY
```

Open http://localhost:8080 and enter the API key when prompted.

Ollama must be running on the host (or another accessible host). Set `OLLAMA_HOST` if it's not on the default `http://localhost:11434`:

```bash
docker run -d --name openpixie \
  -p 8080:8080 \
  -e OLLAMA_HOST=http://your-ollama:11434 \
  -e OLLAMA_MODEL=your-model \
  --add-host=host.docker.internal:host-gateway \
  -v openpixie-data:/data \
  openpixie:0.1.0
```

### From Source

Requirements: Erlang/OTP 28, rebar3, Ollama

```bash
rebar3 compile
rebar3 shell
```

On first run, a setup wizard generates an API key and writes the config.

## Architecture

```
openpixie_sup (root supervisor)
├── openpixie_auth          — API key authentication
├── openpixie_permissions   — Tool permission checking
├── openpixie_circuit_breaker — LLM call resilience
├── openpixie_semaphore     — LLM concurrency limiter
├── openpixie_skills        — Skill scanning & loading
├── openpixie_memory        — Long-term memory storage
├── openpixie_channel       — Named conversation channels
├── openpixie_topic_store   — Topic registry (ETS), persistence
├── openpixie_cron          — Scheduled tasks (reflection, condensation, archival)
├── openpixie_metrics       — Time-series metrics
├── openpixie_archive       — SOUL.md + source code snapshots
├── openpixie_kirino        — Self-modification watchdog
├── openpixie_topic_sup     — Dynamic topic supervisor
│   └── openpixie_topic*    — Individual conversation processes
└── openpixie_http          — Cowboy HTTP + WebSocket server
```


## Tools (41 total)

OpenPixie exposes 41 tools to the LLM across 8 categories:

| Category | Tools |
|----------|-------|
| **File** | `read_file`, `write_file`, `edit_file`, `create_directory`, `list_files`, `file_exists`, `verify_file` |
| **Git** | `git_status`, `git_diff`, `git_log`, `git_add`, `git_commit`, `git_branch`, `git_stash`, `git_pull`, `git_push`, `git_remote` |
| **Command** | `run_command` |
| **Search** | `grep_files`, `find_files` |
| **Memory** | `search_memories`, `recent_memories` |
| **Skills** | `list_skills`, `load_skill` |
| **Self-modification** | `compile_and_reload`, `reload_module`, `get_self_modules`, `analyze_self`, `list_models`, `show_model`, `propose_soul_edit`, `get_soul_proposal`, `apply_soul_proposal`, `reject_soul_proposal` |
| **Metacognitive** | `get_performance_trend`, `get_improvements`, `save_snapshot`, `list_snapshots`, `load_snapshot` |

## Kirino — Self-Modification Watchdog

Kirino is the safety layer for self-modification. When the agent attempts to modify its own source code or personality, Kirino:

1. **Detects** the self-modification tool call
2. **Validates** the modification against documented contracts in `docs/INTERNAL.md`
3. **Updates** the documentation if the modification extends any documented behavior

If a modification would break a documented contract (e.g., removing a required callback from a gen_server), Kirino rejects it. If the modification adds new functionality, Kirino auto-updates the internal documentation.

See [`docs/KIRINO.md`](docs/KIRINO.md) for the full design.

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENPIXIE_DIR` | `/data/pixie` | Runtime state directory |
| `OPENPIXIE_WORKSPACE` | `/data/workspace` | Self-modifiable source directory |
| `OPENPIXIE_PORT` | `8080` | HTTP listener port |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API URL |
| `OLLAMA_MODEL` | `glm-5:cloud` | Default LLM model |

Key config defaults:

| Key | Default | Description |
|-----|---------|-------------|
| `permission_mode` | `ask` | Tool permission mode |
| `max_llm_concurrency` | `1` | Max simultaneous LLM calls |
| `max_context_tokens` | `128000` | Context window limit |
| `idle_timeout_minutes` | `30` | Topic idle → idle status |
| `idle_evict_minutes` | `1440` | Topic idle → stop (24h) |
| `reflection_hour` | `22` | Daily reflection time |

## Data Layout

```
/data/pixie/              — Runtime state
├── config.json           — Configuration
├── API_KEY                — Generated API key
├── SOUL.md                — Personality definition
├── kirino_state.json      — Kirino watchdog state
├── memories/              — Hierarchical memory
├── topics/                — Conversation journals
├── archive/               — Archived topics + snapshots
└── skills/                — User-defined skills

/data/workspace/           — Self-modifiable source
├── .git/                  — Full change history
├── src/                   — Erlang source
├── priv/                  — Dashboard + built-in skills
├── docs/                  — Internal documentation
└── ebin/                  — Compiled BEAM (hot-reload)
```

## Permission Modes

| Mode | Readonly | Write | Self-modification |
|------|----------|-------|-------------------|
| **Auto-approve all** (`trust`) | Allow | Allow | Allow |
| **Auto-approve non-self-mod** (`auto_noselfmod`) | Allow | Allow | Ask |
| **Manual review** (`ask`) | Allow | Ask | Ask |
| **Sandbox** (`sandbox`) | Allow | Ask | Deny |
| **Plan** (`plan`) | Allow | Deny | Deny |

Switchable in real-time from the dashboard header or via WebSocket `set_permission_mode` message.

## Documentation

- [`docs/INTERNAL.md`](docs/INTERNAL.md) — Complete internal reference: all protocols, APIs, data structures, and behavioral contracts
- [`docs/KIRINO.md`](docs/KIRINO.md) — Kirino watchdog design document

## License

Apache-2.0
