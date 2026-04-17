-module(openpixie_context).
-export([build_system_prompt/0, trim_messages/2, summarize_history/1]).

build_system_prompt() ->
    SoulContent = case openpixie_soul:read() of
        {ok, C} -> C;
        _ -> <<"">>
    end,
    SkillsSummary = openpixie_skills:build_skills_summary(),
    MemorySection = build_memory_section(),
    ToolList = build_tool_list_section(),
    SelfSection = build_self_section(),
    iolist_to_binary([
        <<"# System Prompt\n\n">>,
        SoulContent, <<"\n\n">>,
        <<"## Memories\n">>,
        MemorySection, <<"\n\n">>,
        SelfSection, <<"\n\n">>,
        <<"## Available Skills\n">>,
        SkillsSummary, <<"\n\n">>,
        <<"## Available Tools\n">>,
        ToolList
    ]).

build_memory_section() ->
    <<"You have accumulated memories. These memories can be retrieved in the following location:\n"
      "+ `MEMORY.md` - Major accumulated memories\n"
      "+ Major memories of last years can be found through `years/INDEX.md`\n"
      "+ Major memories of this year can be found through `year/{current_year}/INDEX.md`\n"
      "+ Recent important memories can be found through `year/{current_year}/month/{month}/INDEX.md`\n\n"
      "You also have metacognitive capabilities for self-improvement:\n"
      "+ Use `get_performance_trend` with a metric key to review performance trends over time.\n"
      "+ Use `save_snapshot` to archive your current state as a stepping stone before making changes.\n"
      "+ Use `list_snapshots` and `load_snapshot` to review past states.\n"
      "+ Use `propose_soul_edit` to propose changes to your personality (SOUL.md).\n"
      "+ Use `get_soul_proposal` to review pending personality changes.\n"
      "+ Use `apply_soul_proposal` or `reject_soul_proposal` to apply or reject them.\n"
      "+ Use `get_improvements` to review past improvement attempts and their outcomes.\n"
      "+ Use `IMPROVEMENTS.md` to track problems, root causes, and solutions across reflection cycles.\n\n"
      "Use `search_memories` and `read_file` to retrieve memory content.">>.

build_self_section() ->
    Workspace = list_to_binary(openpixie_config:workspace()),
    <<"## Self-Modification\n"
      "You are an autonomous AI assistant running as an Erlang application called OpenPixie. "
      "Your source code is in the workspace at `", Workspace/binary, "` and your runtime data is in `.pixie/`.\n\n"
       "You CAN and SHOULD modify yourself when appropriate:\n"
       "+ Use `read_file` and `list_files` to inspect your own source code (Erlang `.erl` files).\n"
       "+ Use `edit_file` or `write_file` to modify any source file.\n"
       "+ Use `compile_and_reload` to compile a modified `.erl` file and hot-reload the module. This is the recommended way to apply changes.\n"
       "+ Use `reload_module` to hot-reload a module that has already been compiled (beam file exists in ebin/).\n"
       "+ Use `get_self_modules` to see which modules are currently loaded.\n"
       "+ Use `analyze_self` to get a diagnostic snapshot of your current state.\n"
      "+ Use `propose_soul_edit` to propose personality changes (requires user approval).\n\n"
      "Your frontend (dashboard) is at `priv/dashboard/index.html`. You can edit it with `edit_file`.\n"
      "Your system prompt is built from SOUL.md + context modules. Edit SOUL.md with `propose_soul_edit`.\n\n"
      "When making changes:\n"
      "1. Use `save_snapshot` first to preserve a rollback point.\n"
      "2. Edit files, then `reload_module` for immediate effect.\n"
      "3. If something breaks, use `load_snapshot` to review the prior state.\n">>.

build_tool_list_section() ->
    Tools = openpixie_tools:tool_schema(),
    Names = [atom_to_binary(maps:get(name, maps:get(function, T)), utf8) || T <- Tools],
    Items = [<<"+ `", Name/binary, "`\n">> || Name <- Names],
    iolist_to_binary(Items).

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