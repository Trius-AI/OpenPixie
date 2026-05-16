-module(openpixie_context).
-export([build_system_prompt/0, build_system_prompt/1, trim_messages/2, summarize_history/1]).

build_system_prompt() ->
    build_system_prompt(undefined).

build_system_prompt(TopicId) ->
    SoulContent = case openpixie_soul:read() of
        {ok, C} -> C;
        _ -> <<"">>
    end,
    SkillsSummary = openpixie_skills:build_skills_summary(),
    MemorySection = build_memory_section(),
    SelfSection = build_self_section(),
    SettingsSection = build_settings_section(),
    FileTree = build_file_tree_section(),
    ModuleExports = build_module_exports_section(),
    ToolSchemas = build_tool_schemas_section(),
    TopicSection = build_topic_section(TopicId),
    ScheduledSection = case get(triggered_by) of
        schedule -> build_scheduled_section();
        _ -> <<"">>
    end,
    iolist_to_binary([
        <<"# System Prompt\n\n">>,
        SoulContent, <<"\n\n">>,
        <<"## Memories\n">>,
        MemorySection, <<"\n\n">>,
        TopicSection, <<"\n\n">>,
        ScheduledSection, <<"\n\n">>,
        SelfSection, <<"\n\n">>,
        SettingsSection, <<"\n\n">>,
        FileTree, <<"\n\n">>,
        ModuleExports, <<"\n\n">>,
        <<"## Available Skills\n">>,
        SkillsSummary, <<"\n\n">>,
        ToolSchemas
    ]).

build_topic_section(undefined) -> <<"## Current Conversation\n\nNo active conversation.">>;
build_topic_section(TopicId) when is_binary(TopicId) ->
    <<"## Current Conversation\n\n"
      "You are currently in conversation topic `", TopicId/binary, "`. "
      "Use this topic ID when calling `push_message` or `schedule_message` to send messages to this conversation.">>.

build_scheduled_section() ->
    <<"## Scheduled Mode\n\n"
      "You are running in scheduled mode (triggered automatically, not by a user).\n"
      "- You can use read-only tools and notification tools (`push_message`, `schedule_message`) freely.\n"
      "- To modify code or configuration, you MUST use the `self_improve` tool. "
      "Direct self-modification tools (`edit_file`, `write_file`, `compile_and_reload`) are not available.\n"
      "- You can make only ONE self-improvement per run. Choose carefully.\n"
      "- `ask_user` is not available — no human is present to answer questions.\n"
      "- `schedule_prompt` is not available — you cannot schedule more agent runs.\n"
      "- If you identify an issue but are unsure about making a change, use `push_message` to notify the user.">>.

build_memory_section() ->
    <<"You have accumulated memories. These memories can be retrieved in the following location:\n"
      "+ `MEMORY.md` - Major accumulated memories\n"
      "+ Major memories of last years can be found through `years/INDEX.md`\n"
      "+ Major memories of this year can be found through `year/{current_year}/INDEX.md`\n"
      "+ Recent important memories can be found through `year/{current_year}/month/{month}/INDEX.md`\n\n"
      "You also have tools for self-review and change management:\n"
      "+ Use `get_performance_trend` with a metric key to review performance trends over time.\n"
      "+ Use `save_snapshot` to archive your current state before making changes.\n"
      "+ Use `list_snapshots` and `load_snapshot` to review past states.\n"
      "+ Use `propose_soul_edit` to propose changes to your personality (SOUL.md).\n"
      "+ Use `get_soul_proposal` to review pending personality changes.\n"
      "+ Use `apply_soul_proposal` or `reject_soul_proposal` to apply or reject them.\n"
      "+ Use `get_improvements` to review past change attempts and their outcomes.\n"
      "+ Use `IMPROVEMENTS.md` to track problems, root causes, and solutions across reflection cycles.\n\n"
      "Use `search_memories` and `read_file` to retrieve memory content.">>.

build_self_section() ->
    Workspace = list_to_binary(openpixie_config:workspace()),
    <<"## Self-Modification\n"
      "You are an autonomous AI assistant running as an Erlang application called OpenPixie. "
      "Your source code is in the workspace at `", Workspace/binary, "` and your runtime data is in `.pixie/`.\n\n"
       "You can modify yourself when the user asks you to, or when you identify a concrete problem to solve:\n"
       "+ Use `read_file` and `list_files` to inspect your own source code (Erlang `.erl` files).\n"
       "+ Use `edit_file` or `write_file` to modify any source file.\n"
       "+ Use `compile_and_reload` to compile a modified `.erl` file and hot-reload the module. This is the recommended way to apply changes.\n"
       "+ Use `reload_module` to hot-reload a module that has already been compiled (beam file exists in ebin/).\n"
       "+ Use `get_self_modules` to see which modules are currently loaded.\n"
       "+ Use `analyze_self` to get a diagnostic snapshot of your current state.\n"
      "+ Use `propose_soul_edit` to propose personality changes (requires user approval).\n\n"
      "Your frontend (dashboard) is at `priv/dashboard/index.html`. You can edit it with `edit_file`.\n"
      "Your system prompt is built from SOUL.md + context modules. Edit SOUL.md with `propose_soul_edit`.\n\n"
      "**CRITICAL: Before modifying any file, always `read_file` first to see the current content.** "
      "Never assume or hallucinate file contents, variable names, function signatures, or HTML structure. "
      "The file tree and module exports below tell you what exists, but you must read the actual source to know what's inside.\n\n"
      "## Git Workflow for Self-Modification\n\n"
      "Your workspace is a git repository. Use git to solidify your changes into patches:\n\n"
      "1. Before making any change: `git_status` and `git_diff` to check current state.\n"
      "2. After editing source files: `compile_and_reload` to apply the change at runtime.\n"
      "3. Verify the change works as expected (read output, check behavior).\n"
      "4. If the change is good: `git_add` to stage, then `git_commit` with a descriptive message. This creates a persistent patch.\n"
      "5. If the change is bad: revert by reading the git diff, undoing edits, and recompiling.\n"
      "6. Use `git_log` to review your patch history.\n"
      "7. Use `save_snapshot` before risky changes for an additional safety net.\n\n"
      "IMPORTANT: `compile_and_reload` makes a change live immediately but it is lost on restart unless committed to git. "
      "Always commit working changes to git so they persist across restarts.\n\n"
      "When making changes:\n"
      "1. Use `save_snapshot` first to preserve a rollback point.\n"
      "2. Edit files, then `compile_and_reload` for immediate effect.\n"
      "3. Verify the change works.\n"
      "4. `git_add` + `git_commit` to persist the patch.\n"
      "5. If something breaks, use `load_snapshot` to review the prior state.\n\n"
      "## Frontend Self-Modification Rules\n\n"
      "When editing `priv/dashboard/index.html`:\n"
      "+ ALWAYS `read_file` the FULL file before making any edit. Never edit based on memory.\n"
      "+ Use `edit_file` with the SMALLEST possible `old_string` — include just enough context to be unique.\n"
      "+ The `edit_file` tool replaces only the FIRST occurrence of `old_string`. If it appears multiple times, you will get a `warning` with the total count.\n"
      "+ After EVERY edit to the frontend, call `verify_file` with the path to check for syntax errors.\n"
      "+ If `verify_file` reports errors, DO NOT make more edits. Use `git checkout -- priv/dashboard/index.html` to revert and try again.\n"
      "+ NEVER use `write_file` to rewrite the entire frontend. Always use `edit_file` for targeted changes.\n"
      "+ Common corruption patterns to avoid:\n"
      "  - Unclosed `<script>` tags (always pair `<script>` with `</script>`)\n"
      "  - Missing closing tags for `<div>`, `<style>`, `<template>`\n"
      "  - JavaScript string literals broken across lines without proper escaping\n"
      "  - Deleting a line that contains both an opening and closing tag\n\n"
      "## Backend Self-Modification Rules\n\n"
      "When modifying Erlang source files:\n"
      "+ `compile_and_reload` will auto-revert the source file if compilation fails. Read the error message, fix the code, and retry.\n"
      "+ Self-source file edits automatically create a git checkpoint before the edit is applied. If an edit breaks something, you can always `git checkout` to revert.\n"
       "+ After a successful `compile_and_reload`, verify the module is working by calling the relevant function or checking logs.\n\n"
       "## Internal Documentation (Guardian Contract)\n\n"
       "Your internal documentation is at `docs/INTERNAL.md`. This file is the canonical reference for all protocols, APIs, data structures, and behavioral contracts.\n"
       "When you modify the system in any way that changes a documented contract, you MUST also update `docs/INTERNAL.md` to reflect the change.\n"
        "This ensures that future self-modifications can be validated against accurate documentation.\n">>.

build_settings_section() ->
    PixieDir = openpixie_config:pixie_dir(),
    PermMode = atom_to_binary(openpixie_permissions:get_mode(), utf8),
    Model = openpixie_config:ollama_model(),
    OllamaHost = list_to_binary(openpixie_config:ollama_host()),
    GitRemote = case file:read_file(filename:join(PixieDir, "git_remote")) of
        {ok, B} -> trim_bin(B);
        _ -> <<"not set">>
    end,
    GitBranch = case file:read_file(filename:join(PixieDir, "git_branch")) of
        {ok, B2} -> trim_bin(B2);
        _ -> <<"develop">>
    end,
    GitName = case file:read_file(filename:join(PixieDir, "git_name")) of
        {ok, B3} -> trim_bin(B3);
        _ -> <<"OpenPixie">>
    end,
    GitEmail = case file:read_file(filename:join(PixieDir, "git_email")) of
        {ok, B4} -> trim_bin(B4);
        _ -> <<"pixie@openpixie">>
    end,
    SshKeyStatus = case filelib:is_file(filename:join(PixieDir, "ssh_key")) of
        true -> <<"configured">>;
        false -> <<"not set">>
    end,
    [<<"## Current Settings\n\n"
       "These are your current runtime settings. You can view and change them from the Settings page in the dashboard.\n\n"
       "+ **Permission mode**: ">>, PermMode, <<"\n"
       "+ **Ollama model**: ">>, Model, <<"\n"
       "+ **Ollama host**: ">>, OllamaHost, <<"\n"
       "+ **Git remote**: ">>, GitRemote, <<"\n"
       "+ **Git branch**: ">>, GitBranch, <<"\n"
       "+ **Git name**: ">>, GitName, <<"\n"
       "+ **Git email**: ">>, GitEmail, <<"\n"
       "+ **SSH key**: ">>, SshKeyStatus, <<"\n\n"
       "Use `git_push` and `git_pull` to sync with the remote. "
       "If SSH key is configured, git commands will use it automatically.">>].

trim_bin(<<>>) -> <<>>;
trim_bin(Bin) ->
    case binary:last(Bin) of
        $\n -> trim_bin(binary:part(Bin, 0, byte_size(Bin) - 1));
        $\r -> trim_bin(binary:part(Bin, 0, byte_size(Bin) - 1));
        $\s -> trim_bin(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

build_file_tree_section() ->
    Ws = openpixie_config:workspace(),
    Dirs = ["src", "priv", "docs"],
    Lines = lists:foldl(fun(Dir, Acc) ->
        AbsDir = filename:join(Ws, Dir),
        case filelib:is_dir(AbsDir) of
            true ->
                Files = filelib:wildcard("**/*", AbsDir),
                Filtered = [F || F <- Files, filelib:is_file(filename:join(AbsDir, F))],
                case Filtered of
                    [] -> Acc;
                    _ ->
                        Header = [Dir ++ "/"],
                        Entries = ["  " ++ F || F <- Filtered],
                        Acc ++ Header ++ Entries
                end;
            false -> Acc
        end
    end, [], Dirs),
    case Lines of
        [] -> <<"">>;
        _ -> iolist_to_binary([<<"## Codebase File Tree\n">> | [[L, "\n"] || L <- Lines]])
    end.

build_module_exports_section() ->
    Modules = lists:sort([M || {M, _} <- code:all_loaded(), is_openpixie_module(M)]),
    case Modules of
        [] -> <<"">>;
        _ ->
            Lines = lists:map(fun(M) ->
                Exports = try M:module_info(exports) catch _:_ -> [] end,
                ExportStrs = [atom_to_list(F) ++ "/" ++ integer_to_list(A) || {F, A} <- Exports, F =/= module_info],
                ModuleStr = atom_to_list(M),
                ExportsStr = string:join(ExportStrs, ", "),
                ModuleStr ++ ": " ++ ExportsStr
            end, Modules),
            iolist_to_binary([<<"## Module Exports\n">> | [[L, "\n"] || L <- Lines]])
    end.

is_openpixie_module(M) when is_atom(M) ->
    Name = atom_to_binary(M, utf8),
    binary:part(Name, 0, min(10, byte_size(Name))) =:= <<"openpixie_">>;
is_openpixie_module(_) -> false.

build_tool_schemas_section() ->
    Tools = openpixie_tools:tool_schema(),
    Items = lists:map(fun(#{function := #{name := Name, description := Desc, parameters := Params}}) ->
        NameBin = if is_atom(Name) -> atom_to_binary(Name, utf8); is_binary(Name) -> Name end,
        DescBin = if is_binary(Desc) -> Desc; true -> iolist_to_binary(io_lib:format("~p", [Desc])) end,
        ParamLines = format_params(Params),
        [<<"+ `", NameBin/binary, "` — ", DescBin/binary, "\n">>, ParamLines]
    end, Tools),
    iolist_to_binary([<<"## Available Tools\n">> | Items]).

format_params(#{properties := Props, required := Required}) ->
    RequiredSet = sets:from_list([if is_atom(K) -> atom_to_binary(K, utf8); is_binary(K) -> K end || K <- Required]),
    maps:fold(fun(Key, ValSpec, Acc) ->
        KeyBin = if is_atom(Key) -> atom_to_binary(Key, utf8); is_binary(Key) -> Key end,
        TypeBin = case maps:get(type, ValSpec, any) of
            T when is_atom(T) -> atom_to_binary(T, utf8);
            T -> iolist_to_binary(io_lib:format("~p", [T]))
        end,
        DescBin = case maps:get(description, ValSpec, <<"">>) of
            D when is_binary(D) -> D;
            D -> iolist_to_binary(io_lib:format("~p", [D]))
        end,
        ReqMark = case sets:is_element(KeyBin, RequiredSet) of true -> <<" (required)">>; false -> <<" (optional)">> end,
        [[<<"    - `", KeyBin/binary, "` (", TypeBin/binary, ")", ReqMark/binary, ": ", DescBin/binary, "\n">>] | Acc]
    end, [], Props);
format_params(_) -> <<>>.

trim_messages(Messages, MaxTokens) ->
    Cleaned = strip_large_tool_results(Messages),
    CurrentTokens = openpixie_ollama:count_tokens(Cleaned),
    case CurrentTokens =< MaxTokens of
        true -> Cleaned;
        false ->
            EvictOrder = tool_results_first(Cleaned),
            trim_to_fit(EvictOrder, MaxTokens)
    end.

strip_large_tool_results(Messages) ->
    MaxToolResultSize = 4000,
    lists:map(fun(M) ->
        case maps:get(role, M, undefined) of
            tool ->
                case maps:get(content, M, <<"">>) of
                    Content when is_binary(Content), byte_size(Content) > MaxToolResultSize ->
                        Truncated = binary:part(Content, 0, MaxToolResultSize),
                        M#{content => <<Truncated/binary, "\n...[truncated]">>};
                    _ -> M
                end;
            _ -> M
        end
    end, Messages).

tool_results_first(Messages) ->
    {ToolResults, Others} = lists:partition(fun(M) ->
        maps:get(role, M, undefined) =:= tool
    end, Messages),
    ToolResults ++ Others.

trim_to_fit(Messages, MaxTokens) ->
    SystemMsgs = lists:filter(fun(M) -> maps:get(role, M, undefined) =:= system end, Messages),
    Rest = lists:filter(fun(M) -> maps:get(role, M, undefined) =/= system end, Messages),
    case trim_by_count(Rest, MaxTokens - openpixie_ollama:count_tokens(SystemMsgs), 2, 20) of
        {ok, Kept} -> SystemMsgs ++ Kept;
        {needs_summary, Kept} ->
            Dropped = Rest -- Kept,
            {ok, Summary} = summarize_history(Dropped),
            SystemMsgs ++ [#{role => assistant, content => Summary}] ++ Kept
    end.

trim_by_count(Rest, Budget, MinKeep, MaxKeep) ->
    LastN = lists:nthtail(max(0, length(Rest) - MaxKeep), Rest),
    case openpixie_ollama:count_tokens(LastN) =< Budget of
        true ->
            case length(LastN) =< MinKeep of
                true -> {ok, LastN};
                false ->
                    MinMsgs = lists:nthtail(max(0, length(Rest) - MinKeep), Rest),
                    case openpixie_ollama:count_tokens(MinMsgs) =< Budget of
                        true -> {needs_summary, MinMsgs};
                        false -> {needs_summary, []}
                    end
            end;
        false ->
            HalfKeep = max(MinKeep, MaxKeep div 2),
            case HalfKeep < MaxKeep of
                true -> trim_by_count(Rest, Budget, MinKeep, HalfKeep);
                false -> {needs_summary, []}
            end
    end.

summarize_history(Messages) ->
    Model = openpixie_config:ollama_model(),
    HistoryText = iolist_to_binary([format_message(M) || M <- Messages]),
    Prompt = <<"Summarize the following conversation for continuation. Keep all important facts and decisions:\n\n", HistoryText/binary>>,
    ChatMessages = [
        #{role => system, content => <<"You are a conversation summarizer. Be concise but preserve all important facts, decisions, and context.">>},
        #{role => user, content => Prompt}
    ],
    case openpixie_ollama:chat(Model, ChatMessages) of
        {ok, #{message := #{content := Content}}} -> {ok, Content};
        {error, _} -> {ok, <<"">>}
    end.

format_message(#{role := Role, content := Content}) when is_atom(Role), is_binary(Content) ->
    <<(atom_to_binary(Role, utf8))/binary, ": ", Content/binary, "\n">>;
format_message(_) ->
    <<"">>.