# OpenPixie Development Log

## What happened (and what was wrong)

The initial deployment had cascading crashes. Every "fix" revealed another bug underneath. Here's the complete list of issues found and fixed:

### Critical Bugs Found & Fixed

1. **`openpixie_permissions` missing `ask` mode handler** — Default permission mode is `ask`, but only `trust`, `plan`, and `sandbox` had handlers. The catch-all returned `{error, unknown_request}`, which didn't match any clause in `openpixie_tools:execute/3`, causing a `CaseClauseError` crash on EVERY tool call. This was the #1 cause of "agent crash" in production.

2. **`openpixie_ws` and spawned agent processes: `lager:*` undefined at runtime** — Direct `lager:error/2`, `lager:info/2`, `lager:debug/1` calls crashed in production because lager's parse transforms don't apply in anonymous spawned functions, and the prod release couldn't resolve them. Replaced all direct lager calls with `error_logger:*_msg` (always available in OTP) and `openpixie_log` (with try/catch fallback).

3. **`openpixie_http_chat.erl` had no tool loop** — Single-shot LLM call only. Tool calls from the model were returned as raw JSON to the client. Added full depth-limited tool loop with `json_safe`, matching the WS handler pattern.

4. **`openpixie_tools_search.erl`: `maps:get(path, Pattern, Ws)`** — `grep_files/1` and `find_files/1` used `Pattern` (a binary) as a map key lookup. Both functions were completely broken.

5. **`openpixie_metrics.erl`: `get_recent/2` used `lists:keysort(4, Entries)` on maps** — Maps aren't tuples, this crashes. Fixed to sort by `maps:get(timestamp, ...)`.

6. **`openpixie_tools_schema.erl`: Missing `coerce_types` clauses** — `list_files`, `create_directory`, `file_exists`, `find_files`, `grep_files`, `git_commit`, `search_memories`, `load_skill` all fell through to the identity catchall. If the LLM sent atom keys instead of binary keys, these tools would crash.

7. **`openpixie_permissions.erl`: `list_checkpoints` instead of `list_snapshots`** — Mismatched tool name.

8. **`openpixie_ws.erl` heartbeat:** Multiple bugs — `heartbeat_timeout` message handler used `{stop, heartbeat_timeout, State}` which Cowboy interprets as `{stop, NewHandlerState}`, then `terminate/3` crashes with `{badmap, heartbeat_timeout}`. Fixed to use `[{shutdown_reason, heartbeat_timeout}, close], State`. Stale `heartbeat_timeout` timer not cancelled on client reply — fixed by tracking `heartbeat_timer` ref.

9. **Tool call pattern match: `<<"arguments">>` at top level** — The tool call map from Ollama has `arguments` inside `<<"function">>` sub-map, not at top level. Pattern `#{<<"name">> := Name, <<"arguments">> := Args}` would never match.

10. **`jsx:encode` crashes on atoms and string lists** — Tool results contain atoms (`true`, `file_read_error`) and `file:list_dir/1` returns string lists. Added recursive `json_safe/1` sanitizer.

11. **`binary:part` on iolist** — `jsx:encode` returns iolist, not binary. Fixed by wrapping in `iolist_to_binary`.

12. **Agent spawn process not monitored** — Crash left client stuck in "thinking" forever. Fixed with `erlang:monitor` and `{agent_down, ...}` handler.

13. **Tool rejection sent no reply** — Agent hung forever waiting for result. Fixed with `{tool_result, denied}` + `tool_rejected` reply.

14. **Cron interval jobs shared single `last_run` ETS key** — All interval jobs shared one timestamp.

15. **`openpixie_channel:init/1` deadlock** — Called `gen_server:call(?SERVER, ...)` during its own init.

16. **`openpixie_topic_store:register/2` returned `{ok, Pid}` not `ok`** — Pattern match crashed.

17. **`openpixie_topic_store:reenable/2` returned `true` not `ok`** — Pattern match crashed.

18. **`openpixie_topic_sup:start_topic/1` return value** — Changed from `{ok, TopicId}` to `{ok, TopicId, Pid}`.

19. **`openpixie_topic:get_state/1` returns plain map, not `{ok, Map}`** — Pattern match crashed.

20. **`check_required` compared atom keys against binary-keyed args** — Fixed binary key fallback.

21. **Dead `sessions_dir` code** — Removed from config, app, and docker-entrypoint.

### Streaming Implementation (Current)

Added Ollama streaming support:

- **`openpixie_ollama.erl`**: New `stream_chat_with_tools/4` function that enables `stream: true`, uses hackney's `{async, true}` mode, parses NDJSON chunks in real-time, and calls a callback for each content token
- **`openpixie_ws.erl`**: `run_agent_turn/3` now uses `stream_chat_with_tools` with a callback that sends `{stream_chunk, ContentChunk}` messages to the WS process. A new `websocket_info({stream_chunk, ...})` handler forwards chunks as `{type: "chunk", content: "..."}` to the browser
- **Dashboard**: Added `streamingEl` variable that accumulates chunks into a single `.msg.assistant` div. `response` message finalizes the streaming element. New `case 'chunk'` handler appends text in real-time
- Tool calls still work: when tool_calls are present, streaming content is accumulated, the assistant message + tool results are stored, and the agent recurses

### Architecture

- Zulip-style: Channel → Topic → Messages
- Topic lifecycle: created → active → idle → archived; active → resolved
- Idle topic processes evicted to disk, reloadable on demand
- Self-modification: LLM can read/edit source code, hot-reload modules, propose SOUL.md edits
- Metacognitive loop: metrics tracking, archive snapshots, daily reflection → IMPROVEMENTS.md
- WebSocket bidirectional heartbeat (30s interval, 45s timeout)
- Streaming token-by-token LLM output to browser
- Permission modes: trust (allow all), sandbox (no self-mod), ask (default: allow readonly, ask for writes)