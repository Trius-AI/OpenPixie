-module(openpixie_reflection).
-export([reflect/0, read_improvements/0, record_improvement/3, record_improvement/4]).

reflect() ->
    {ok, Conversations} = gather_conversations(),
    {ok, Metrics} = gather_metrics(),
    {ok, Improvements} = read_improvements(),
    {ok, SoulContent} = openpixie_soul:read(),
    SnapshotLabel = <<"pre_reflection">>,
    {ok, _} = openpixie_archive:save_snapshot(SnapshotLabel, #{
        type => <<"pre_reflection">>,
        conversations_count => length(Conversations)
    }),
    Prompt = build_reflection_prompt(Conversations, Metrics, Improvements, SoulContent),
    Model = openpixie_config:ollama_model(),
    Messages = [
        #{role => system, content => reflection_system_prompt()},
        #{role => user, content => Prompt}
    ],
    case openpixie_ollama:chat(Model, Messages) of
        {ok, #{message := #{content := Content}}} ->
            parse_and_apply_reflection(Content);
        {error, Reason} ->
            openpixie_log:error("Reflection failed: ~p", [Reason]),
            {error, Reason}
    end.

reflection_system_prompt() ->
    <<"You are a self-review system for an AI assistant called Pixie. "
      "Your job is to review the assistant's recent behavior and identify actionable changes. "
      "Only propose changes when there is a clear, specific problem. If things are working well, say so. "
      "Output your analysis in a structured format.\n\n"
      "Output your reflection as JSON with these fields:\n"
      "- \"analysis\": Brief analysis of recent behavior patterns\n"
      "- \"strengths\": What's working well\n"
      "- \"issues\": Specific problems observed (can be empty if none)\n"
      "- \"soul_proposal\": If the personality (SOUL.md) should change, provide the full new SOUL.md content. If no change needed, set to null.\n"
      "- \"code_proposals\": List of code changes. Each item has: {\"file\": \"path\", \"description\": \"what to change\"}. Can be empty.\n"
      "- \"memory_entry\": A typed memory entry with fields: {\"type\": \"insight|observation|hypothesis|plan\", \"content\": \"the entry\", \"confidence\": 0.0-1.0}\n"
      "- \"improvement\": If a specific issue was found: {\"problem\": \"...\", \"root_cause\": \"...\", \"solution\": \"...\", \"outcome\": \"pending\"}. If no issue found, set to null.">>.

build_reflection_prompt(Conversations, Metrics, Improvements, SoulContent) ->
    ConvSummary = summarize_conversations(Conversations),
    MetricsStr = format_metrics(Metrics),
    ImprStr = format_improvements(Improvements),
    iolist_to_binary([
        <<"# Self-Reflection Request\n\n">>,
        <<"## Current SOUL.md (Personality Definition)\n">>,
       <<(SoulContent)/binary>>, <<"\n\n">>,
        <<"## Recent Conversations (Summarized)\n">>,
        ConvSummary, <<"\n\n">>,
        <<"## Performance Trends\n">>,
        MetricsStr, <<"\n\n">>,
        <<"## Past Improvement Attempts\n">>,
        ImprStr, <<"\n\n">>,
        <<"Based on the above, review what's working well and whether any specific issues need addressing. "
          "Only propose changes when there is a clear, concrete problem. If things are working well, "
          "say so and set soul_proposal and improvement to null. "
          "Provide a complete new SOUL.md only if the personality genuinely needs refinement. "
          "If code changes are needed, specify which files and what to change. "
          "Record any insights as typed memory entries.\n\n"
          "IMPORTANT: Output valid JSON only.">>
    ]).

summarize_conversations([]) -> <<"No conversations since last reflection.">>;
summarize_conversations(Convs) ->
    iolist_to_binary([begin
        Id = maps:get(<<"id">>, C, maps:get(id, C, <<"unknown">>)),
        MsgCount = maps:get(message_count, C, 0),
        <<"- Session ", Id/binary, ": ", (integer_to_binary(MsgCount))/binary, " messages\n">>
    end || C <- Convs]).

format_metrics({ok, #{trend := Trend, recent_avg := RecentAvg}}) ->
    io_lib:format("Trend: ~.2f, Recent avg: ~.2f", [Trend, RecentAvg]);
format_metrics(_) ->
    <<"No performance metrics available.">>.

format_improvements([]) -> <<"No past improvement attempts.">>;
format_improvements(Imprs) ->
    iolist_to_binary([begin
        Problem = maps:get(<<"problem">>, I, maps:get(problem, I, <<"">>)),
        Outcome = maps:get(<<"outcome">>, I, maps:get(outcome, I, <<"unknown">>)),
        <<"- Problem: ", Problem/binary, " | Status: ", Outcome/binary, "\n">>
    end || I <- Imprs]).

parse_and_apply_reflection(Content) ->
    try
        Decoded = jsx:decode(extract_json(Content), [return_maps]),
        Analysis = maps:get(<<"analysis">>, Decoded, <<"">>),
        MemoryEntry = maps:get(<<"memory_entry">>, Decoded, null),
        SoulProposal = maps:get(<<"soul_proposal">>, Decoded, null),
        Improvement = maps:get(<<"improvement">>, Decoded, null),
        case is_map(MemoryEntry) of
            true ->
                openpixie_memory:save_typed_memory(
                    maps:get(<<"type">>, MemoryEntry, <<"observation">>),
                    maps:get(<<"content">>, MemoryEntry, <<"">>),
                    maps:get(<<"confidence">>, MemoryEntry, 0.5)
                );
            _ -> ok
        end,
        case is_binary(SoulProposal) of
            true ->
                {ok, _} = openpixie_soul:propose_edit(SoulProposal),
                openpixie_log:info("Reflection proposed SOUL.md changes (pending approval)", []);
            _ -> ok
        end,
        case is_map(Improvement) of
            true ->
                record_improvement(
                    maps:get(<<"problem">>, Improvement, <<"">>),
                    maps:get(<<"root_cause">>, Improvement, <<"">>),
                    maps:get(<<"solution">>, Improvement, <<"">>)
                );
            _ -> ok
        end,
        {ok, #{analysis => Analysis, soul_proposed => is_binary(SoulProposal),
               memory_saved => is_map(MemoryEntry)}}
    catch
        _:Reason ->
            openpixie_log:warn("Failed to parse reflection output: ~p", [Reason]),
            {ok, save_as_raw_memory(Content)}
    end.

save_as_raw_memory(Content) ->
    openpixie_memory:save_typed_memory(<<"observation">>, Content, 0.3),
    Content.

extract_json(Content) ->
    case binary:match(Content, <<"{">>) of
        {Start, _} ->
            case find_json_end(Content, Start) of
                {ok, End} -> binary:part(Content, Start, End - Start + 1);
                error -> Content
            end;
        nomatch -> Content
    end.

find_json_end(Content, Start) ->
    find_json_end(Content, Start, 0).

find_json_end(Content, Pos, Depth) when Pos >= byte_size(Content) -> error;
find_json_end(Content, Pos, Depth) ->
    case binary:at(Content, Pos) of
        ${ -> find_json_end(Content, Pos + 1, Depth + 1);
        $} when Depth =:= 1 -> {ok, Pos};
        $} -> find_json_end(Content, Pos + 1, Depth - 1);
        $" ->
            case find_end_quote(Content, Pos + 1) of
                {ok, EndPos} -> find_json_end(Content, EndPos + 1, Depth);
                error -> error
            end;
        _ -> find_json_end(Content, Pos + 1, Depth)
    end.

find_end_quote(Content, Pos) when Pos >= byte_size(Content) -> error;
find_end_quote(Content, Pos) ->
    case binary:at(Content, Pos) of
        $" -> {ok, Pos};
        $\\ -> find_end_quote(Content, Pos + 2);
        _ -> find_end_quote(Content, Pos + 1)
    end.

gather_conversations() ->
    TopicsDir = openpixie_config:topics_dir(),
    case file:list_dir(TopicsDir) of
        {ok, Topics} ->
            Convs = lists:filtermap(fun(T) ->
                JournalPath = filename:join(TopicsDir, T ++ "/conversation.jsonl"),
                ContextPath = filename:join(TopicsDir, T ++ "/context.json"),
                case {file:read_file(JournalPath), file:read_file(ContextPath)} of
                    {{ok, _}, {ok, CtxContent}} ->
                        try
                            Ctx = jsx:decode(CtxContent, [return_maps]),
                            {true, Ctx#{
                                journal_path => list_to_binary(JournalPath),
                                message_count => count_messages(JournalPath),
                                title => maps:get(<<"title">>, Ctx, <<"Untitled">>),
                                channel_id => maps:get(<<"channel_id">>, Ctx, <<"general">>)
                            }}
                        catch _:_ -> false
                        end;
                    _ -> false
                end
            end, Topics),
            {ok, Convs};
        {error, _} -> {ok, []}
    end.

count_messages(JournalPath) ->
    case file:read_file(JournalPath) of
        {ok, Content} ->
            length(binary:matches(Content, <<"\n">>)) + 1;
        _ -> 0
    end.

gather_metrics() ->
    TrendResult = openpixie_metrics:get_trend(<<"reflection_score">>),
    TrendResult.

record_improvement(Problem, RootCause, Solution) ->
    record_improvement(Problem, RootCause, Solution, <<"pending">>).

record_improvement(Problem, RootCause, Solution, Outcome) ->
    Path = openpixie_config:improvements_path(),
    Entry = #{
        <<"problem">> => Problem,
        <<"root_cause">> => RootCause,
        <<"solution">> => Solution,
        <<"outcome">> => Outcome,
        <<"timestamp">> => erlang:system_time(millisecond)
    },
    ok = filelib:ensure_dir(Path),
    Line = <<(iolist_to_binary(jsx:encode(Entry)))/binary, "\n">>,
    ok = file:write_file(Path, Line, [append]),
    ok.

read_improvements() ->
    Path = openpixie_config:improvements_path(),
    case file:read_file(Path) of
        {ok, Content} ->
            case catch jsx:decode(Content, [return_maps]) of
                List when is_list(List) -> {ok, List};
                _ ->
                    Lines = binary:split(Content, <<"\n">>, [global]),
                    Parsed = lists:filtermap(fun(Line) ->
                        case Line of
                            <<>> -> false;
                            _ ->
                                try jsx:decode(Line, [return_maps]) of
                                    Map when is_map(Map) -> {true, Map};
                                    _ -> false
                                catch _:_ -> false
                                end
                        end
                    end, Lines),
                    {ok, Parsed}
            end;
        _ -> {ok, []}
    end.