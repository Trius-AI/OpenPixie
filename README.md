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
- **Watchdog (Guardian)** — Validates self-modifications against documented contracts, auto-updates internal docs
- **Memory system** — Hierarchical daily/monthly/yearly condensation
- **SOUL.md** — Editable personality definition with human-in-the-loop approval
- **Skills** — Extensible skill system with YAML frontmatter (CRUD via Settings UI)
- **Daily reflection** — Self-reflection cron job that can propose personality improvements
- **Dashboard** — Single-page web UI with real-time streaming, file manager, and settings
- **REST + WebSocket APIs** — Full programmatic access
- **Permission system** — Five modes: trust, auto_noselfmod, ask, sandbox, plan
- **Circuit breaker** — Resilient LLM call handling with retry and backoff
- **Git integration** — All self-modifications tracked in git; configurable SSH remote for push/pull
- **Session auth** — Cookie-based session authentication with 24h expiry
- **Retry messages** — Retry any user message to regenerate the response

## Quick Start

### Docker (recommended)

```bash
# Build
docker build -t openpixie:0.100 .

# Run
docker run -d --name openpixie \
  -p 8080:8080 \
  -e OLLAMA_HOST=http://172.17.0.1:11434 \
  -v openpixie-data:/data \
  -v openpixie-workspace:/workspace \
  openpixie:0.100

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
  -v openpixie-data:/data \
  -v openpixie-workspace:/workspace \
  openpixie:0.100
```

On Linux, use the Docker gateway IP instead of `host.docker.internal`:
```bash
-e OLLAMA_HOST=http://172.17.0.1:11434
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
├── openpixie_auth          — Session-based cookie authentication
├── openpixie_permissions   — Tool permission checking
├── openpixie_circuit_breaker — LLM call resilience
├── openpixie_semaphore     — LLM concurrency limiter
├── openpixie_skills        — Skill scanning, loading, CRUD
├── openpixie_memory        — Long-term memory storage
├── openpixie_channel       — Named conversation channels
├── openpixie_topic_store   — Topic registry (ETS), persistence
├── openpixie_cron          — Scheduled tasks (reflection, condensation, archival)
├── openpixie_metrics       — Time-series metrics
├── openpixie_archive       — SOUL.md + source code snapshots
├── openpixie_guardian      — Self-modification watchdog
├── openpixie_topic_sup     — Dynamic topic supervisor
│   └── openpixie_topic*    — Individual conversation processes
└── openpixie_http          — Cowboy HTTP + WebSocket server
```

## Settings UI

The dashboard includes a Settings page with tabs for:

| Tab | What it manages |
|-----|-----------------|
| **Configuration** | Structured form for Ollama host, model, permissions, timeout, etc. Plus raw `config.json` editor |
| **SOUL.md** | Edit the personality definition directly |
| **Skills** | Create, edit, delete, and rescan skills (SKILL.md files) |
| **Tools** | View all available tools grouped by category with permission badges |
| **Git Remote** | Configure SSH key, known hosts, remote URL, and branch for `git push`/`git pull` |
| **API Key** | View, copy, and regenerate the API key |

## Tools (44 total)

OpenPixie exposes 44 tools to the LLM across 10 categories:

| Category | Tools |
|----------|-------|
| **File** | `read_file`, `write_file`, `edit_file`, `create_directory`, `list_files`, `file_exists`, `verify_file` |
| **Git** | `git_status`, `git_diff`, `git_log`, `git_add`, `git_commit`, `git_branch`, `git_stash`, `git_pull`, `git_push`, `git_remote` |
| **Command** | `run_command` |
| **Search** | `grep_files`, `find_files` |
| **Memory** | `search_memories`, `recent_memories` |
| **Skills** | `list_skills`, `load_skill` |
| **Interaction** | `ask_user` |
| **Self-modification** | `compile_and_reload`, `reload_module`, `get_self_modules`, `analyze_self`, `list_models`, `show_model`, `propose_soul_edit`, `get_soul_proposal`, `apply_soul_proposal`, `reject_soul_proposal`, `register_tool`, `unregister_tool` |
| **Metacognitive** | `get_performance_trend`, `get_improvements`, `save_snapshot`, `list_snapshots`, `load_snapshot` |
| **Sync** | `sync_export`, `sync_import` |

## Guardian — Self-Modification Watchdog

Guardian (formerly Kirino) is the safety layer for self-modification. When the agent attempts to modify its own source code or personality, Guardian:

1. **Detects** the self-modification tool call
2. **Validates** the modification against documented contracts in `docs/INTERNAL.md`
3. **Updates** the documentation if the modification extends any documented behavior

If a modification would break a documented contract (e.g., removing a required callback from a gen_server), Guardian rejects it. If the modification adds new functionality, Guardian auto-updates the internal documentation.

See [`docs/GUARDIAN.md`](docs/GUARDIAN.md) for the full design.

## Git Remote & SSH

The agent can push/pull from a remote Git repository. Configure via the **Git Remote** tab in Settings:

1. **Git Remote URL** — e.g., `git@github.com:user/repo.git`
2. **Branch Name** — defaults to `develop`
3. **SSH Private Key** — your ED25519 key, auto-installed to `~/.ssh/id_ed25519`
4. **SSH Known Hosts** — pre-populated with GitHub/GitLab keys

All Git operations (`git_push`, `git_pull`, sync) automatically use the configured SSH key. The Docker image includes `openssh-client`.

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
| `max_context_tokens` | `32768` | Context window limit |
| `idle_timeout_minutes` | `30` | Topic idle → idle status |
| `idle_evict_minutes` | `1440` | Topic idle → stop (24h) |
| `llm_timeout_ms` | `600000` | LLM response timeout (10 min) |

## Data Layout

```
/data/pixie/              — Runtime state
├── config.json           — Configuration
├── API_KEY               — Generated API key
├── SOUL.md               — Personality definition
├── guardian_state.json    — Guardian watchdog state
├── ssh_key                — SSH private key (ED25519)
├── known_hosts            — SSH known hosts
├── git_remote             — Git remote URL
├── git_branch             — Git branch name
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

Switchable in real-time from the dashboard header or via the Settings UI.

## API Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/login` | Create session (returns cookie) |
| DELETE | `/api/v1/login` | Destroy session |
| GET | `/api/v1/config` | Get configuration |
| GET/POST | `/api/v1/chat` | Chat proxy |
| GET | `/api/v1/topics` | List topics |
| GET/POST | `/api/v1/topics/:id` | Get/create topic |
| GET | `/api/v1/models` | List Ollama models |
| GET/POST | `/api/v1/skills` | List/CRUD skills |
| GET | `/api/v1/tools` | List tools with permissions |
| GET | `/api/v1/files` | File manager (browse/view/create/delete/upload/download) |
| GET | `/api/v1/sync` | Export/import code sync patches |
| GET/PUT | `/api/v1/pixie-data/soul` | Read/write SOUL.md |
| GET/PUT | `/api/v1/pixie-data/config` | Read/write config.json |
| GET/PUT | `/api/v1/pixie-data/api_key` | Read/regenerate API key |
| GET/PUT | `/api/v1/pixie-data/ssh_key` | Read/write SSH private key |
| GET/PUT | `/api/v1/pixie-data/known_hosts` | Read/write SSH known hosts |
| GET/PUT | `/api/v1/pixie-data/git_remote` | Read/write Git remote URL |
| GET/PUT | `/api/v1/pixie-data/git_branch` | Read/write Git branch name |
| GET | `/recover` | Recovery console (auth-protected) |
| WS | `/ws` | WebSocket for real-time chat |

## Documentation

- [`docs/INTERNAL.md`](docs/INTERNAL.md) — Complete internal reference: all protocols, APIs, data structures, and behavioral contracts
- [`docs/GUARDIAN.md`](docs/GUARDIAN.md) — Guardian watchdog design document
- [`docs/API.md`](docs/API.md) — REST API reference

## License

Apache-2.0