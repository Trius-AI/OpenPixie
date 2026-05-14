# Guardian — Self-Modification Watchdog Agent

## Overview

**Guardian** is an internal watchdog that intercepts self-modification tool calls and ensures they are safe and well-documented. It acts as a gatekeeper between the agent's intent to modify the system and the actual execution of that modification.

Guardian is a `gen_server` process registered as `openpixie_guardian`. It is started under `openpixie_sup` with `permanent` restart semantics. Using a gen_server (rather than a purely functional module) provides:

- **In-memory cached snapshot** — avoids reading/parsing `guardian_state.json` from disk on every tool call
- **Crash isolation** — if Guardian crashes, the supervisor restarts it; tool execution is not blocked by Guardian failures (see Failure Semantics below)
- **Observable state** — `handle_call` for `status/0` gives the dashboard and agent a way to query Guardian's view of the system

## Role

Guardian has three responsibilities:

1. **Detect** — Identify that an incoming tool call is a self-modification request targeting system code
2. **Validate** — Verify that the modification preserves the contracts documented in `docs/INTERNAL.md` and won't break the system upon reload
3. **Update** — If the modification extends or changes any documented contract, automatically update `docs/INTERNAL.md`

## Detection

Guardian engages when a tool call targets a self-modification tool AND the target path is system code. The determination uses two checks:

### Check 1: Self-modification tool

The existing `openpixie_permissions:is_self_modification/1` defines this set. Not all tools in that list are equally relevant to Guardian:

| Tool | Guardian engages? | Reason |
|------|-----------------|--------|
| `edit_file` | Yes, if target is system source | Modifies source files |
| `write_file` | Yes, if target is system source | Creates/overwrites source files |
| `compile_and_reload` | Yes | Compiles and hot-reloads a module |
| `reload_module` | Yes | Hot-reloads an existing module |
| `propose_soul_edit` | Yes | Changes the personality definition |
| `apply_soul_proposal` | Yes | Applies a personality change |
| `reject_soul_proposal` | **No** | Deleting a proposal file is not a modification of running code; no contract validation needed |
| `deploy_module` | **No** (phantom) | Listed in `is_self_modification/1` but has no dispatch clause and no implementation — Guardian logs a warning that a phantom entry exists in the permissions list |

### Check 2: Target path heuristic

For `edit_file` and `write_file`, Guardian also checks the **target path**. Only paths matching self-source patterns trigger Guardian:

- `src/*.erl` — Erlang source modules
- `priv/dashboard/index.html` — Frontend dashboard
- `docs/INTERNAL.md` — The documentation itself
- `<pixie_dir>/SOUL.md` — Personality definition
- `<pixie_dir>/skills/*/SKILL.md` — Skill definitions

Writing a random file in the workspace (like a user's Python script or a data file) does NOT trigger Guardian.

**Special case — `write_file` creating a new module**: If `write_file` targets a path like `src/openpixie_*.erl` and the file does not currently exist, Guardian engages in a different mode (see "New Module Creation" below). This is a structural extension of the system, not just a modification.

## Validation Design: Pre-check vs. Post-check

Guardian's validation is split across two phases because of a fundamental constraint: **`pre_check` runs before the tool executes, so it cannot inspect the post-modification state.** It can only validate the *intent* and *current-state consistency*. The actual contract verification of the modified result happens in `post_check`.

### Pre-check (before dispatch)

**Purpose**: Catch problems that can be detected without executing the tool.

1. **Current-state consistency**: Verify the current system state matches what `guardian_state.json` records. If it doesn't (e.g., modules were changed externally), log a warning and rebuild the snapshot.
2. **Target viability**: For `.erl` edits, verify the target module currently exists and is loaded (for `edit_file`) or doesn't exist yet (for `write_file` creating a new module).
3. **Intent validation**: Basic sanity checks on the modification:
   - `edit_file` on an `.erl` file: verify `old_string` isn't trying to remove a documented contract function (e.g., removing `init/1` from a gen_server)
   - `write_file` creating a new `openpixie_*.erl`: warn that new modules typically require supervisor registration, dispatch entries, and schema entries
   - `compile_and_reload`: verify the target `.erl` path matches a loaded or loadable module
4. **Documentation health**: Verify `docs/INTERNAL.md` is readable. If it's missing or corrupted, log a critical warning and enter **permissive mode** (allow all modifications through with warnings, since there's nothing to validate against). This mode persists until the doc is regenerated.

**Pre-check cannot do**: Verify that the modified code compiles, that exports are preserved, or that contracts still hold — those require the modified file to exist on disk.

### Post-check (after successful dispatch)

**Purpose**: Verify the actual result of the modification and update documentation if needed.

`post_check` receives the dispatch `Result` so it can skip all validation on tool failure and only proceed on `#{success := true, ...}`.

For `.erl` file modifications (after `edit_file`, `write_file`, or `compile_and_reload`):

1. **If the file was edited but not yet compiled** (`edit_file`/`write_file` only): Run `verify_file` (Erlang compilation check to temp directory). If compilation fails, return `{warn, compilation_failed}` — the agent should be told to fix or revert.
2. **If the module was compiled and loaded** (`compile_and_reload`): This is the authoritative check point:
   - Call `Module:module_info(exports)` to get the new export list
   - Compare against the pre-modification snapshot
   - Verify contract invariants (see Contract Invariants below)
3. **For dashboard edits**: Run `verify_file` to check HTML/JS balance. Grep for critical JS globals and error handlers.
4. **For SOUL.md changes**: Verify the new content is non-empty and contains readable Markdown.
5. **Diff against snapshot**: Compare current system state against the cached `guardian_state.json`. If any documented structure changed, update `docs/INTERNAL.md` (see Documentation Update Logic below).
6. **Write new snapshot** if any state changed.

### Contract Invariants (checked in post-check)

These are the specific invariants from INTERNAL.md §16 that Guardian enforces:

| Module type | Required exports | Failure severity |
|-------------|-----------------|-----------------|
| `openpixie_ws` | `init/2`, `websocket_init/1`, `websocket_handle/2`, `websocket_info/2`, `terminate/3` | `reject` |
| gen_server modules (registered in supervisor) | `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `terminate/2`, `code_change/3`, `start_link/N` (same arity as supervisor spec) | `reject` |
| Cowboy handler modules | `init/2` | `reject` |
| Tool modules (listed in `openpixie_tools:dispatch/2`) | `schema/0` and at least the dispatch-targeted function | `warn` |
| All `openpixie_*` modules | No removal of previously existing exported functions | `warn` |

**Severity meanings**:
- `reject` — Guardian logs a critical error and suggests immediate `git checkout` revert. The modification already happened (post-check runs after dispatch), but Guardian signals the agent that the system is in a broken state.
- `warn` — Guardian logs a warning. The system is likely still functional but may have degraded capabilities.

### New Module Creation

When `write_file` creates a `src/openpixie_*.erl` file that doesn't currently exist, Guardian's pre-check emits a `{warn, new_module}` with a reminder list:

> "New module detected. After compile_and_reload, you will likely need to: (1) Add the module to `openpixie_sup` if it's a worker/supervisor, (2) Add dispatch entries in `openpixie_tools:dispatch/2` if it exposes tools, (3) Add schema entries in the module's `schema/0`, (4) Add validation in `openpixie_tools_schema`, (5) Add permission rules in `openpixie_permissions` if applicable, (6) Update `docs/INTERNAL.md`."

Post-check for new modules: after `compile_and_reload`, verify the module loaded successfully, then detect and record the new module in the snapshot.

### `reject_soul_proposal` — explicit exclusion

`reject_soul_proposal` is in `is_self_modification/1` but is explicitly excluded from Guardian because it only deletes the `SOUL.md.proposed` file — it doesn't modify running code, doesn't change contracts, and doesn't require documentation updates. Guardian's `is_guardian_relevant/2` function returns `false` for this tool.

### Phantom tool detection

`deploy_module` is listed in `is_self_modification/1` but has no dispatch clause in `openpixie_tools:dispatch/2` and no implementation. Guardian's `init_snapshot/0` checks for such discrepancies and logs them as warnings. If Guardian detects a tool in the permissions list that doesn't exist in the dispatch table (or vice versa), it records that inconsistency.

## Snapshot & State

### Guardian State File

Cached in memory (gen_server state) and persisted to `<pixie_dir>/guardian_state.json`:

```json
{
  "version": 1,
  "timestamp": 1705312200000,
  "modules": {
    "openpixie_ws": ["init/2", "websocket_init/1", "websocket_handle/2", "websocket_info/2", "terminate/3"],
    "openpixie_topic": ["start_link/1", "send_message/2", "get_history/1", "get_state/1", "get_id/1", "subscribe/2", "unsubscribe/2", "resolve/1", "reopen/1", "fork/3", "broadcast/2", "resume/1", "stop_topic/1", "idle_check/1", "set_fork/4", "delete_topic/1"],
    "...": "..."
  },
  "tools": {
    "read_file": {"module": "openpixie_tools_file", "category": "file"},
    "write_file": {"module": "openpixie_tools_file", "category": "file"},
    "...": "..."
  },
  "routes": [
    {"method": "GET", "path": "/health", "handler": "openpixie_http_health"},
    {"method": "POST", "path": "/api/v1/chat", "handler": "openpixie_http_chat"},
    {"method": "GET", "path": "/api/v1/topics", "handler": "openpixie_http_topics"},
    {"method": "POST", "path": "/api/v1/topics", "handler": "openpixie_http_topics"},
    {"method": "DELETE", "path": "/api/v1/topics/:id", "handler": "openpixie_http_topics"},
    {"method": "GET", "path": "/api/v1/models", "handler": "openpixie_http_models"},
    {"method": "GET", "path": "/api/v1/skills", "handler": "openpixie_http_skills"},
    {"method": "WS", "path": "/ws", "handler": "openpixie_ws"},
    {"method": "POST", "path": "/recover", "handler": "openpixie_http_recover"},
    {"method": "STATIC", "path": "/", "handler": "cowboy_static"},
    {"method": "STATIC", "path": "/[...]", "handler": "cowboy_static"}
  ],
  "ws_types_client": ["connect", "chat", "new_topic", "switch_topic", "list_topics", "resolve_topic", "reopen_topic", "delete_topic", "tool_confirm", "frontend_error", "heartbeat", "interrupt"],
  "ws_types_server": ["connected", "response", "chunk", "thinking", "stream_done", "tool_step", "tool_confirm_request", "tool_approved", "tool_rejected", "topic_created", "topic_switched", "topics_list", "topic_resolved", "topic_reopened", "topic_deleted", "topic_ended", "session_ended", "heartbeat", "interrupted", "error"],
  "config_keys": ["pixie_dir", "config_path", "ollama_host", "ollama_model", "set_ollama_host", "set_ollama_model", "http_port", "workspace", "set_workspace", "idle_timeout_minutes", "permission_mode", "set_permission_mode", "max_llm_concurrency", "circuit_breaker_failures", "circuit_breaker_cooldown_ms", "llm_timeout_ms", "max_context_tokens", "soul_path", "memories_dir", "topics_dir", "channels_dir", "skills_dir", "archive_dir", "improvements_path", "reflection_hour", "heartbeat_interval_ms", "idle_evict_minutes", "load_config", "save_config"],
  "permission_self_mod": ["reload_module", "deploy_module", "compile_and_reload", "edit_file", "write_file", "propose_soul_edit", "apply_soul_proposal", "reject_soul_proposal"],
  "permission_readonly": ["read_file", "list_files", "file_exists", "grep_files", "find_files", "git_status", "git_log", "git_diff", "list_models", "show_model", "list_skills", "load_skill", "search_memories", "recent_memories", "get_self_modules", "analyze_self", "get_soul_proposal", "list_snapshots", "health", "get_performance_trend", "get_improvements"]
}
```

### Snapshot Collection Strategy

Some snapshot fields require runtime introspection; others require source parsing. Here is how each is collected:

| Field | Collection Method |
|-------|-------------------|
| `modules` | `[M:module_info(exports) || {M,_} <- code:all_loaded(), is_openpixie_module(M)]` — full export list from each loaded module |
| `tools` | Read `openpixie_tools:dispatch/2` function clauses. Collected by calling `openpixie_tools:tool_schema/0` and extracting `name` from each entry, then cross-referencing the dispatch table. Since the dispatch table is a set of pattern-matched function clauses with no runtime enumeration, Guardian maintains a **hardcoded baseline** of known tool names in its module and detects new ones by comparing `tool_schema/0` output against the snapshot |
| `routes` | Hardcoded baseline in Guardian (extracted from `openpixie_http:init/1` source at development time). At runtime, Guardian can verify these routes exist by checking that cowboy's listener is running, but detecting *new* routes requires source-code comparison. When `openpixie_http` is recompiled, Guardian's post-check scans for the `ApiRoutes` list in the source |
| `ws_types_client` | Hardcoded baseline in Guardian. The WS message types are pattern-matched in `websocket_handle/2` with no runtime enumeration. When `openpixie_ws` is recompiled, Guardian's post-check scans the source for `<<"type_name">>` patterns in `websocket_handle/2` |
| `ws_types_server` | Hardcoded baseline plus source scan. Server message types are sent via `jsx:encode(#{type => ...})` throughout `openpixie_ws.erl`. When the module is recompiled, Guardian scans for `type =>` patterns |
| `config_keys` | Extracted from `openpixie_config` module info: all exported functions of arity 0 that look like accessors (not setters) |
| `permission_self_mod`, `permission_readonly` | Source scan of `openpixie_permissions` module when recompiled |

**Hardcoded baselines** are maintained in `openpixie_guardian` as constant data. They represent the "known state at Guardian development time" and are automatically superseded by `guardian_state.json` after the first snapshot is written. The baselines exist solely so that Guardian has something to compare against on first run.

### Snapshot Lifecycle

1. **App start** (`init/1`): Load `guardian_state.json` from disk if it exists, otherwise call `snapshot_state/0` to build it from scratch. Compare loaded state against current system; log discrepancies.
2. **After each post-check** (if state changed): Write new snapshot to `guardian_state.json` (atomic: write to `.tmp`, rename).
3. **On gen_server crash/restart**: Re-read from disk; the last successfully written snapshot is the recovery point.

## Interface

### Module: `openpixie_guardian`

```erlang
-module(openpixie_guardian).
-behaviour(gen_server).

-export([
    pre_check/2,       % (ToolName, Args) -> ok | {reject, Reason} | {warn, Reason}
    post_check/3,       % (ToolName, Args, Result) -> ok | {update_doc, Changes}
    init_snapshot/0,    % () -> {ok, StateMap}
    snapshot_state/0,   % () -> {ok, StateMap}
    status/0,           % () -> #{snapshot_timestamp => integer(), ...}
    is_guardian_relevant/2 % (ToolName, Args) -> boolean
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
```

#### `pre_check(ToolName, Args)`

Called BEFORE tool dispatch. This is a `gen_server:call` with a 5000ms timeout (non-blocking — if Guardian is slow or stuck, the tool execution proceeds; see Failure Semantics).

Returns:
- `ok` — tool execution may proceed
- `{reject, Reason}` — tool execution must be blocked (only for pre-detectable problems, which are rare — see note below)
- `{warn, Reason}` — tool execution may proceed; reason is logged and forwarded to the agent response

**Note**: Most contract violations can only be detected in post-check (after the file is on disk or the module is loaded). Pre-check `reject` is used sparingly, mainly for:
- Target path is outside workspace or points to a critical system file that shouldn't be touched (e.g., `config/sys.config`)
- The tool is `reject_soul_proposal` (excluded from Guardian, but if called directly with relevant args, no action needed)

#### `post_check(ToolName, Args, Result)`

Called AFTER tool dispatch, with the dispatch `Result` map. Skips all validation if `Result` does not contain `success => true`.

Returns:
- `ok` — no state changes detected, no documentation update needed
- `{update_doc, Changes}` — documentation was updated; `Changes` is a list of `{Section, Action, Detail}` tuples documenting what changed

The `Result` parameter is critical: without it, Guardian cannot distinguish a successful modification from a failed one, and would try to validate/update documentation for tools that didn't actually execute.

#### `is_guardian_relevant(ToolName, Args)`

Determines if a tool call should engage Guardian. Returns `boolean`. Logic:

1. If `ToolName` is `reject_soul_proposal` → `false`
2. If `ToolName` is `deploy_module` → `false` (phantom tool)
3. If `ToolName` is in `edit_file`/`write_file` → apply target path heuristic (check `Args` for `path` key)
4. If `ToolName` is `compile_and_reload`/`reload_module`/`propose_soul_edit`/`apply_soul_proposal` → `true`
5. Otherwise → `false`

#### `init_snapshot/0`

Builds initial snapshot from current system state and writes to `guardian_state.json`. Called at startup. Can also be called manually to regenerate a corrupted snapshot.

#### `snapshot_state/0`

Returns current system state as a map. Used internally and for debugging.

#### `status/0`

Returns Guardian's current view: snapshot timestamp, number of modules tracked, number of tools tracked, any known inconsistencies (phantom tools, missing doc sections), and whether Guardian is in permissive mode (doc missing).

### Gen_server State Record

```erlang
-record(state, {
    snapshot :: map(),           % cached guardian_state.json content
    snapshot_ts :: integer(),    % timestamp of last snapshot write
    permissive :: boolean(),     % true if docs/INTERNAL.md is missing/corrupted
    inconsistencies :: [term()]  % list of known inconsistencies
}).
```

## Integration Points

### In `openpixie_tools:execute/3`

```erlang
execute(ToolName, Args, Opts) ->
    case openpixie_tools_schema:validate(ToolName, Args) of
        {error, Missing} -> #{success => false, error => validation_error, missing => Missing};
        {ok, ValidatedArgs} ->
            case openpixie_permissions:check(ToolName, ValidatedArgs) of
                {allow, _Reason} ->
                    guardian_dispatch(ToolName, ValidatedArgs, Opts);
                {deny, Reason} ->
                    #{success => false, error => permission_denied, reason => Reason};
                {ask, Reason} ->
                    Confirmation = maps:get(confirmation, Opts, auto_deny),
                    case Confirmation of
                        approved ->
                            %% User already approved — run Guardian check, then dispatch
                            guardian_dispatch(ToolName, ValidatedArgs, Opts);
                        auto_deny ->
                            #{success => false, error => requires_confirmation,
                              reason => Reason, tool => ToolName}
                    end;
                {error, _} = Err ->
                    #{success => false, error => permission_error, reason => Err}
            end
    end.

guardian_dispatch(ToolName, ValidatedArgs, Opts) ->
    case openpixie_guardian:is_guardian_relevant(ToolName, ValidatedArgs) of
        true ->
            case openpixie_guardian:pre_check(ToolName, ValidatedArgs) of
                ok ->
                    Result = dispatch(ToolName, ValidatedArgs),
                    openpixie_guardian:post_check(ToolName, ValidatedArgs, Result),
                    Result;
                {reject, Reason} ->
                    #{success => false, error => guardian_rejected, reason => Reason};
                {warn, Reason} ->
                    openpixie_log:warn("Guardian warning: ~p", [Reason]),
                    Result = dispatch(ToolName, ValidatedArgs),
                    openpixie_guardian:post_check(ToolName, ValidatedArgs, Result),
                    Result
            end;
        false ->
            dispatch(ToolName, ValidatedArgs)
    end.
```

Key design decisions:
- **Guardian pre-check runs ONLY after user approval** for `{ask, Reason}` tools. The user's confirmation is requested first; if approved, Guardian validates the intent before dispatch. This avoids a scenario where the user approves a tool, then Guardian rejects it — instead, Guardian's pre-check catches most issues, and its post-check catches the rest.
- **Non-relevant tools skip Guardian entirely** — no gen_server call overhead.
- **`guardian_dispatch/3` is a helper function** that centralizes the Guardian integration logic.

### In `openpixie_ws:execute_tool_calls`

The WS path handles tool confirmations differently: `execute_tool_calls` in `openpixie_ws.erl` sends `tool_confirm_request` to the client, receives `{tool_confirm_reply, approved}`, then re-executes the tool with `#{confirmation => approved}`. This second execution goes through `openpixie_tools:execute/3` with the `Opts` map containing `confirmation => approved`, which hits the `{ask, approved}` branch above — so Guardian is already integrated for the WS path via the same `guardian_dispatch` function.

### In `openpixie_app:start/2`

After `openpixie_sup:start_link()`, call `openpixie_guardian:init_snapshot/0` to bootstrap the watchdog.

### In `openpixie_sup`

Add `openpixie_guardian` as a permanent worker child:

```erlang
#{id => openpixie_guardian,
  start => {openpixie_guardian, start_link, []},
  restart => permanent,
  shutdown => 5000,
  type => worker,
  modules => [openpixie_guardian]}
```

## Documentation Update Logic

### Mechanism

Guardian updates `docs/INTERNAL.md` using the **same `edit_file` tool** the agent uses. Specifically, Guardian calls `openpixie_tools_file:edit_file/1` with precise `old_string`/`new_string` pairs to insert new rows into Markdown tables or append entries to lists.

This approach is consistent with the existing system and avoids the complexity of maintaining a separate structured data file that generates Markdown (which would add a build step and a source-of-truth synchronization problem).

If `edit_file` fails (e.g., the table structure changed and the old_string no longer matches), Guardian logs a warning and records the pending update in its state. A subsequent `post_check` will retry, or the agent can be told to manually update the documentation.

### What gets updated

| Change detected | INTERNAL.md section | Edit action |
|----------------|---------------------|-------------|
| New tool name in dispatch/schema | §6.1 Tool Registry | Append table row: `\| tool_name \| module \| category \|` |
| New `openpixie_*` module loaded | §2 Module Index | Append table row: `\| module \| type \| responsibility \|` |
| New HTTP route in `openpixie_http` | §4.2 Endpoints | Append table row: `\| METHOD \| path \| auth \| description \|` |
| New client WS message type | §3.3 | Append table row |
| New server WS message type | §3.4 | Append table row |
| New config key in `openpixie_config` | §8.4 | Append table row |
| New entry in `is_self_modification/1` | §6.3 | Update the self-modification tools list |
| New entry in `is_readonly/1` | §6.3 | Update the readonly tools list |
| Module exports changed (function added) | §16 contracts | Log warning that contract may need manual doc update |

**Module exports changed (function removed)**: This is a `reject`-severity event in post-check. Guardian does NOT auto-update the documentation for removed exports — instead it flags the issue for the agent to address.

### Change annotation

Each auto-update appends an inline comment within INTERNAL.md at the end of the modified section:

```markdown
<!-- guardian:updated section=6.1 timestamp=2024-01-15T14:30:00 trigger=compile_and_reload -->
```

These comments are informational and do not affect rendering. They help the agent understand that a section was machine-updated.

## Failure Semantics

### Guardian call timeout

All `gen_server:call` requests to Guardian use a 5000ms timeout. If Guardian is unresponsive (crashed, stuck, or overloaded):

- `pre_check` → catches `exit:{timeout,_}` and returns `ok` (allows tool execution to proceed)
- `post_check` → catches `exit:{timeout,_}` and returns `ok` (skips validation/update)

**Principle: Guardian failure does not block tool execution.** It's better to allow a modification through without validation than to deadlock the agent loop.

### Permissive mode

If `docs/INTERNAL.md` is missing or unreadable, Guardian enters **permissive mode**:
- All `pre_check` calls return `ok`
- All `post_check` calls return `ok` (no contract validation, no documentation update)
- `status/0` reports `permissive => true`
- A critical log message is emitted on every Guardian-relevant tool call

This mode ends when the documentation is restored (manually by the agent, or by Guardian's `init_snapshot` on next restart).

### Phantom tools

If `guardian_state.json` records tool names in `permission_self_mod` or `permission_readonly` that don't appear in the tool dispatch table, Guardian logs a warning at startup. This indicates the permissions list and dispatch table are out of sync — a manual cleanup needed. It does NOT block operation.

## Startup Behavior

On application start (in `openpixie_guardian:init/1`):

1. Read `<pixie_dir>/guardian_state.json`
2. If file doesn't exist → call `snapshot_state/0`, write initial snapshot
3. If file exists and parses → load into gen_server state, compare against current system state, log discrepancies
4. If file exists but is corrupted → log error, rebuild from scratch via `snapshot_state/0`
5. Check `docs/INTERNAL.md` readability; set `permissive` flag accordingly
6. Check for phantom tools (permissions vs dispatch discrepancies); store in `inconsistencies`

`init_snapshot/0` (the public API) does the same thing and can be called manually.

## Summary

| Aspect | Detail |
|--------|--------|
| **Internal name** | Guardian |
| **Module** | `openpixie_guardian` (gen_server, registered `openpixie_guardian`) |
| **Trigger** | Self-modification tool calls targeting system source (`edit_file`, `write_file` on self-source paths, `compile_and_reload`, `reload_module`, `propose_soul_edit`, `apply_soul_proposal`) |
| **Explicitly excluded** | `reject_soul_proposal` (no-op for Guardian), `deploy_module` (phantom) |
| **Pre-check** | Validates intent and current-state consistency; cannot verify post-modification contracts; rarely rejects |
| **Post-check** | Receives dispatch `Result`; validates contracts on success; detects documentation drift; auto-updates INTERNAL.md |
| **State** | `guardian_state.json` in pixie dir; cached in gen_server memory |
| **Integration** | `guardian_dispatch/3` helper in `openpixie_tools:execute/3`, after permissions + confirmation, before/after dispatch |
| **Failure mode** | Guardian timeout/errors → allow tool execution (non-blocking); `reject` on post-check → flag broken state, suggest revert |
| **Permissive mode** | When INTERNAL.md missing/corrupted → allow all with warnings |
| **Documentation updates** | Via `edit_file` on INTERNAL.md; annotated with `<!-- guardian:updated -->` comments |
| **Supervisor** | Permanent worker under `openpixie_sup` |
| **New module handling** | Pre-check warns about required registrations; post-check records new module in snapshot |
