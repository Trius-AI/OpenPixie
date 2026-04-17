+ the project is an LLM-driven autonomous AI assistant.
+ the entire assistant shall be written in Erlang for its ability to stay resilient and be able to modify itself at runtime.
+ the assistant should use ollama as its LLM provider, whose documentation can be found at https://docs.ollama.com/llms.txt
+ the AI assistant shall provide the following thing:
  + a dashboard for configuration and directly talking to the assistant.
  + an HTTP API (auth required)
  + a websocket API (auth required)
+ when the server is first run it should lead user through a setup wizard so that the user can set up the assistant without much hassle.
+ this AI assistant should have the following:
  + SOUL.md - definition of self.
  + ability to create its own cron job (used for memory management)
  + a memory system - at least 1 MEMORY.md storing "major" memories and per session memory file.
    + at the end of the day (whenever that "end of the day" is supposed to be) the assistant is to summarize all the conversations it has had during the day and store whatever it deemed important to remember in a dedicated file (called "day memory" for now).
	+ at the end of the month all the day memory files are condensed into one "month memory" file.
	+ at the end of the year all the month memory files are condensed into one "year memory" file.
	+ the memory part in the system prompt should be something like this:
	
	  ```
	  ## Memories
	  You have accumulated memories. These memories can be retrieved in the following location:
	  + `MEMORY.md` - (description of MEMORY.md)
	  + Major memories of last years can be found through `years/INDEX.md`
	  + Major memories of this year can be found through `year/{current_year}/INDEX.md`
	  + Recent important memories can be found through `year/{current_year}/month/{month}/INDEX.md`
	  ```
	  
	  the content of SOUL.md should be added to system prompt but the memories files would only be mentioned (i.e. its actual content not included in the system prompt)
  + a skill system (like the one in ~/workspace/__Trius/tarha-new/)
  + both SOUL.md and memory files should be stored as files.
  + (we will write a basic SOUL.md template; the user can edit it to suit their need during setup wizard (and also later in the dashboard))
  + the assistant should be configured to reflect on the conversation it had daily and try to modify its own behaviour through editing the files mentioned above and/or the source code and then hot-reload
+ this AI assistant should be given the following:
  + a directory to act as its workspace
  + basic coding ability (so that it could modify itself)
    + (like the one in ~/workspace/__Trius/tarha-new/)
  + git-related ability (and optionally a github user account)
    + (like the one in ~/workspace/__Trius/tarha-new/)
+ auth system:
  + single master API key (cryptographic random, generated during setup wizard, stored hashed in `.pixie/config.json`).
  + all HTTP and WebSocket endpoints require `Authorization: Bearer <key>`.
  + dashboard login uses the same key (entered once, stored in browser session storage).
  + v1 is single-user. multi-user is a v2 concern.
  + optionally support multiple keys later (e.g. read-only key for automation vs. full-access key).
+ sandboxing / security:
  + three permission tiers:
    + `trust` — full access to workspace, commands, self-modification.
    + `sandbox` — read workspace, write only to a staging dir; commands run in restricted shell (`rbash` or `bwrap --ro-bind`); no self-modification.
    + `plan` — read-only everything, no commands, no writes.
  + the assistant's workspace directory is the chroot boundary — all file tools reject paths outside it.
  + `run_command` should use `erlang:open_port/2` with a timeout instead of `os:cmd/1` (which blocks forever).
  + self-modification tools (`reload_module`, `deploy_module`) require explicit user confirmation via dashboard/WebSocket before executing.
+ context window management:
  + before each LLM call, compute a token budget: system prompt + skills + conversation history + tool results must fit within the model's context window minus `max_tokens` reserve for response.
  + prioritized eviction order (first to be dropped/truncated):
    1. oldest tool results (already summarized in conversation).
    2. oldest conversation turns.
    3. on-demand skill content (already consumed).
  + always keep: system prompt, SOUL.md, skills summary, last N turns, most recent tool result.
  + when context is too large, summarize the first half of the conversation using the LLM itself and replace old turns with one `assistant` summary message.
+ session lifecycle:
  + each session is a directory: `sessions/{id}/` containing:
    + `conversation.jsonl` — append-only log of all messages.
    + `context.json` — session metadata (model, started_at, token_count, status).
    + `memory.md` — per-session memory (the LLM can write here via `write_file`).
  + session states: `active` → `idle` → `archived`.
    + `active`: currently has an open WebSocket or recent API activity.
    + `idle`: no activity for N minutes (configurable, default 30).
    + `archived`: end-of-day cron job moves idle sessions to `archive/`.
  + resuming a session: reload `conversation.jsonl`, rebuild context (with summarization if too long).
  + the per-session `memory.md` is what the day-condensation cron job reads and merges into day memory.
+ memory system — condensation mechanics:
  + the cron job:
    1. collect all session `memory.md` files for the day.
    2. concatenate them + the current `MEMORY.md` as input.
    3. call the LLM with a condensation prompt: "Given these day memories, extract and merge the most important information into MEMORY.md. Preserve all critical facts. Drop transient details."
    4. write the new `MEMORY.md` atomically (write to `.tmp`, then `mv`).
    5. if the LLM call fails, retry up to 3 times with exponential backoff. if all fail, log the error and skip — don't lose existing memory.
    6. month condensation: same pattern, but input is all day memories for that month. year condensation: all month memories for that year.
  + the condensation prompt should explicitly instruct the LLM to preserve facts that reference specific entities (people, projects, preferences) and drop conversational filler.
+ memory system — search / retrieval:
  + add a tool: `search_memories(query)` — does keyword matching across all memory files, returns file paths and matching excerpts.
  + optionally add `recent_memories(n)` tool that returns the last N day-memory file paths so the assistant can quickly load recent context.
  + the system prompt already tells the assistant where memory files live. `search_memories` + `read_file` gives it full retrieval capability.
  + for v2, consider embedding-based search.
+ SOUL.md ownership:
  + initial SOUL.md comes from template + customization during setup wizard (user fills in name, personality traits, communication style).
  + the assistant can propose edits to SOUL.md, but they are staged, not applied immediately. the user sees the proposed edit in the dashboard and approves/rejects.
  + this prevents the assistant from silently rewriting its own personality. the daily reflection can produce a SOUL.md proposal, but the human stays in the loop.
  + SOUL.md edits should be committed to git so there's history.
+ persistence / storage:
  + all durable state is files — no database. this keeps the self-modifying story coherent (the assistant reads/writes its own config and memory as files).
  + runtime state (active sessions, skill cache, token counts) lives in ETS tables. ETS is process-owned and survives as long as the owning process.
  + config from setup wizard → `.pixie/config.json`.
  + on boot, read all files into ETS. on graceful shutdown, ETS → files. on crash, ETS is lost but files are the source of truth.
+ deployment:
  + build with rebar3 release (`rebar3 as prod tar`). produces a self-contained tarball.
  + provide a Dockerfile that builds the release and runs it as the `init` process.
  + for bare-metal: systemd unit file that runs the release.
  + the setup wizard handles first-run config; no separate install step needed.
+ LLM failure handling:
  + wrap all Ollama calls in a circuit breaker pattern:
    + `closed` → normal operation.
    + `open` → after N consecutive failures, reject calls immediately for a cooldown period.
    + `half-open` → after cooldown, try one call; if it succeeds → `closed`, if it fails → `open` again.
  + ingress messages (from HTTP/WebSocket) go into a `gen_server` queue. if the circuit breaker is open, return 503 with `Retry-After` header. if closed, dequeue and process.
  + timeouts: use `erlang:open_port/2` or `hackney` with a configurable timeout (default 120s) so calls don't block forever.
+ concurrency / throttling:
  + maintain a global semaphore (`gen_server` counting active LLM calls) with configurable max (default: 1 for single-GPU, or the Ollama `num_parallel` setting).
  + sessions wait in queue if the semaphore is full. return a "thinking..." status to the WebSocket client.
  + this prevents OOM crashes on the GPU.
+ tool / function calling framework:
  + adapt tarha-new's central dispatch pattern (`tools:execute/2` → sub-module delegation) with improvements:
    + schema validation for all tools (not just 6).
    + input sanitization — shell-escape all string args passed to `os:cmd`.
    + timeout enforcement — use `open_port` instead of `os:cmd` so timeouts actually work.
    + self-modification guard — `reload_module` / `deploy_module` require explicit user approval.
    + plugin/MCP integration via catch-all pattern (like tarha-new) for v1.
+ logging & observability:
  + use lager (de facto Erlang logging library) with structured JSON output.
  + log levels: tool execution at `info`, LLM calls at `debug`, errors at `error`.
  + add a `GET /health` endpoint (no auth) that returns `{status: ok, ollama: up/down, uptime: N}`.
  + dashboard should have a live log viewer (WebSocket stream of recent `info`+ level logs).
+ testing strategy:
  + EUnit for unit tests on each tool module, skill parser, auth, etc.
  + PropEr for property-based tests on the memory condensation pipeline (generate random conversation logs, verify condensation doesn't lose facts).
  + integration tests: spin up Ollama (or a mock), send a conversation through the WebSocket, verify tool calls and responses.
  + test commands: `rebar3 eunit` and `rebar3 proper`.
+ backup / restore:
  + the workspace directory is a git repo (initialized during setup wizard).
  + the daily reflection cron job commits all memory files after condensation.
  + SOUL.md changes are committed.
  + this gives full history of all memories and personality changes, free `git log` / `git diff` for auditing, and easy restore via `git checkout HEAD~1 -- MEMORY.md`.
  + remote backup: push to a private GitHub repo (the assistant already has git tools).
+ setup wizard output — `.pixie/` config directory:
  + `.pixie/config.json` — API key hash, Ollama URL, model name, workspace paths.
  + `.pixie/skills/` — user-installed skills (overrides builtins).
  + `.pixie/sessions/` — active + archived sessions.
  + `.pixie/memories/` — `MEMORY.md`, `years/`, `year/`, etc.
  + `.pixie/SOUL.md` — symlink to workspace root `SOUL.md`.
  + this keeps all user-specific state in one place, separate from the OTP release.
