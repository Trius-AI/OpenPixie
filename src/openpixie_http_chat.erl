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
        _ -> {error, no_auth}
    end.

handle(Req, State) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            {ok, Body, Req2} = cowboy_req:read_body(Req),
            Msg = jsx:decode(Body, [return_maps]),
            Content = maps:get(<<"content">>, Msg, <<"">>),
            TopicId = maps:get(<<"topic_id">>, Msg, undefined),
            {ok, TopicPid} = resolve_topic(TopicId),
            UserMsg = #{role => user, content => Content},
            {ok, _History} = openpixie_topic:send_message(TopicPid, UserMsg),
            Result = run_agent_turn(TopicPid, 0),
            RespBody = case Result of
                #{type := response, message := RespMsg} ->
                    jsx:encode(#{type => response, message => RespMsg, topic_id => get_topic_id(TopicPid)});
                #{type := error} = Err ->
                    jsx:encode(Err#{topic_id => get_topic_id(TopicPid)})
            end,
            Req3 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, RespBody, Req2),
            {ok, Req3, State};
        _ ->
            Req2 = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req),
            {ok, Req2, State}
    end.

run_agent_turn(TopicPid, Depth) when Depth < 10 ->
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
                    AllowedResults = lists:filter(fun(TR) ->
                        case TR of
                            {requires_confirmation, _TName, _TArgs, _TInfo} -> false;
                            _ -> true
                        end
                    end, ToolResults),
                    lists:foreach(fun(TR) ->
                        {ok, _} = openpixie_topic:send_message(TopicPid, TR)
                    end, AllowedResults),
                    run_agent_turn(TopicPid, Depth + 1)
            end;
        {error, circuit_open} ->
            #{type => error, error => circuit_open, message => <<"LLM service temporarily unavailable">>};
        {error, Reason} ->
            #{type => error, error => Reason}
    end;

run_agent_turn(_TopicPid, _Depth) ->
    #{type => error, error => max_tool_depth}.

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
                ToolMsg = #{role => tool, content => iolist_to_binary(jsx:encode(SafeResult)), name => Name},
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