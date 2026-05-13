-module(openpixie_http_chat).
-export([init/2]).

init(Req, State) ->
    case authenticate(Req) of
        {ok, _} ->
            handle(Req, State);
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

authenticate(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Key/binary>> -> openpixie_auth:authenticate(Key);
        _ ->
            Qs = cowboy_req:parse_qs(Req),
            case proplists:get_value(<<"key">>, Qs) of
                undefined -> {error, no_auth};
                Key -> openpixie_auth:authenticate(Key)
            end
    end.

handle(Req, State) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            {ok, Body, Req2} = cowboy_req:read_body(Req),
            Msg = jsx:decode(Body, [return_maps]),
            Content = maps:get(<<"content">>, Msg, <<"">>),
            TopicId = maps:get(<<"topic_id">>, Msg, undefined),
            {ok, TopicPid} = resolve_topic(TopicId),
            {ok, PreHistory} = openpixie_topic:get_history(TopicPid),
            PreCount = length(PreHistory),
            UserMsg = #{role => user, content => Content},
            {ok, _History} = openpixie_topic:send_message(TopicPid, UserMsg),
            Result = run_agent_turn(TopicPid, 0),
            {ok, PostHistory} = openpixie_topic:get_history(TopicPid),
            NewMsgs = case length(PostHistory) > PreCount + 1 of
                true -> lists:nthtail(PreCount + 1, PostHistory);
                false -> []
            end,
            ToolSteps = format_tool_steps(NewMsgs),
            RespBody = case Result of
                #{type := response, message := RespMsg} ->
                    jsx:encode(#{type => response, message => RespMsg,
                                  topic_id => get_topic_id(TopicPid), tool_steps => ToolSteps});
                #{type := error} = Err ->
                    jsx:encode(Err#{topic_id => get_topic_id(TopicPid), tool_steps => ToolSteps})
            end,
            Req3 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, RespBody, Req2),
            {ok, Req3, State};
        _ ->
            Req2 = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req),
            {ok, Req2, State}
    end.

format_tool_steps(Messages) ->
    lists:filtermap(fun(M) ->
        case maps:get(role, M, undefined) of
            tool ->
                Name = maps:get(name, M, <<"unknown">>),
                NameBin = if is_atom(Name) -> atom_to_binary(Name, utf8); is_binary(Name) -> Name; true -> iolist_to_binary(io_lib:format("~p", [Name])) end,
                Content = maps:get(content, M, <<"">>),
                {true, #{tool => NameBin, result => Content}};
            assistant ->
                case maps:get(<<"tool_calls">>, M, undefined) of
                    undefined -> false;
                    [] -> false;
                    TCs ->
                        Steps = lists:filtermap(fun(TC) ->
                            case TC of
                                #{<<"function">> := #{<<"name">> := TCName, <<"arguments">> := TCArgs}} ->
                                    {true, #{tool => TCName, args => TCArgs}};
                                _ -> false
                            end
                        end, TCs),
                        case Steps of
                            [] -> false;
                            _ -> {true, #{tool_calls => Steps}}
                        end
                end;
            _ -> false
        end
    end, Messages).

run_agent_turn(TopicPid, _Depth) ->
    agent_loop(TopicPid, 0).

agent_loop(_TopicPid, Iteration) when Iteration >= 200 ->
    #{type => error, error => max_iterations, message => <<"The agent reached the maximum number of steps.">>};
agent_loop(TopicPid, Iteration) ->
    {ok, History} = openpixie_topic:get_history(TopicPid),
    SystemPrompt = openpixie_context:build_system_prompt(),
    Model = openpixie_config:ollama_model(),
    Tools = openpixie_tools:tool_schema(),
    MaxTokens = openpixie_config:max_context_tokens(),
    TrimmedHistory = openpixie_context:trim_messages(History, MaxTokens),
    Messages = [#{role => system, content => SystemPrompt} | TrimmedHistory],
    {ok, acquired} = openpixie_semaphore:acquire(),
    Result = try
        openpixie_ollama:chat_with_tools(Model, Messages, Tools)
    after
        openpixie_semaphore:release()
    end,
    case Result of
        {ok, #{<<"message">> := RespMsg}} ->
            ToolCalls = maps:get(<<"tool_calls">>, RespMsg, []),
            case ToolCalls of
                [] ->
                    {ok, _} = openpixie_topic:send_message(TopicPid, RespMsg),
                    Content = maps:get(<<"content">>, RespMsg, <<"">>),
                    #{type => response, message => #{content => Content}};
                _ ->
                    ToolResults = execute_tool_calls(ToolCalls),
                    {ok, _} = openpixie_topic:send_message(TopicPid, RespMsg),
                    ApprovedResults = lists:map(fun(TR) ->
                        case TR of
                            {requires_confirmation, TName, TArgs, _TInfo} ->
                                ApprovedResult = openpixie_tools:execute(TName, TArgs, #{confirmation => approved}),
                                SafeResult = json_safe(ApprovedResult),
                                Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                                #{role => tool, content => Encoded, name => TName, args => TArgs};
                            _ -> TR
                        end
                    end, ToolResults),
                    lists:foreach(fun(TR) ->
                        {ok, _} = openpixie_topic:send_message(TopicPid, TR)
                    end, ApprovedResults),
                    agent_loop(TopicPid, Iteration + 1)
            end;
        {error, circuit_open} ->
            #{type => error, error => circuit_open, message => <<"The AI service is temporarily unavailable.">>};
        {error, Reason} ->
            Msg = case Reason of
                timeout -> <<"The AI service took too long to respond.">>;
                econnrefused -> <<"Cannot connect to the AI service. Is Ollama running?">>;
                nxdomain -> <<"Cannot resolve the AI service hostname.">>;
                {nxdomain, _} -> <<"Cannot resolve the AI service hostname.">>;
                _ -> iolist_to_binary(io_lib:format("~p", [Reason]))
            end,
            #{type => error, error => Reason, message => Msg}
    end.

execute_tool_calls(ToolCalls) ->
    lists:map(fun(#{<<"function">> := #{<<"name">> := Name, <<"arguments">> := RawArgs}} = Call) ->
        CallId = maps:get(<<"id">>, Call, undefined),
        Args = case RawArgs of
            Map when is_map(Map) -> Map;
            Bin when is_binary(Bin) ->
                case jsx:is_json(Bin) of
                    true -> jsx:decode(Bin, [return_maps]);
                    false -> #{<<"command">> => Bin}
                end
        end,
        Result = openpixie_tools:execute(Name, Args),
        case maps:get(error, Result, undefined) of
            requires_confirmation ->
                {requires_confirmation, Name, Args, Result};
            _ ->
                SafeResult = json_safe(Result),
                ToolMsg = #{role => tool, content => iolist_to_binary(jsx:encode(SafeResult)), name => Name, args => Args},
                ToolMsg2 = case CallId of
                    undefined -> ToolMsg;
                    Id -> ToolMsg#{tool_call_id => Id}
                end,
                ToolMsg2
        end
    end, ToolCalls).

json_safe(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        SafeK = json_safe_key(K),
        Acc#{SafeK => json_safe(V)}
    end, #{}, Map);
json_safe(List) when is_list(List) ->
    [json_safe(E) || E <- List];
json_safe(Bin) when is_binary(Bin) -> Bin;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Int) when is_integer(Int) -> Int;
json_safe(Float) when is_float(Float) -> Float;
json_safe(Tuple) when is_tuple(Tuple) -> json_safe(tuple_to_list(Tuple));
json_safe(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

json_safe_key(K) when is_binary(K) -> K;
json_safe_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_safe_key(K) -> iolist_to_binary(io_lib:format("~p", [K])).

resolve_topic(undefined) ->
    {ok, _TopicId, TopicPid} = openpixie_topic_sup:start_topic(),
    {ok, TopicPid};
resolve_topic(TopicId) ->
    case openpixie_topic:resume(TopicId) of
        {ok, Pid} -> {ok, Pid};
        {error, not_found} ->
            {ok, _NewId, TopicPid} = openpixie_topic_sup:start_topic(),
            {ok, TopicPid}
    end.

get_topic_id(TopicPid) ->
    openpixie_topic:get_id(TopicPid).