-module(openpixie_ollama).
-export([
    chat/2,
    chat_with_tools/3,
    stream_chat/3,
    stream_chat_with_tools/4,
    list_models/0,
    show_model/1,
    count_tokens/1,
    count_tokens_estimated/1
]).

-define(ESTIMATED_CHARS_PER_TOKEN, 4).
-define(STREAM_CHUNK_TIMEOUT_MS, 120000).

chat(Model, Messages) ->
    do_chat(Model, Messages, [], #{}).

chat_with_tools(Model, Messages, Tools) ->
    do_chat(Model, Messages, Tools, #{}).

stream_chat(Model, Messages, Callback) ->
    stream_chat_with_tools(Model, Messages, [], Callback).

stream_chat_with_tools(Model, Messages, Tools, Callback) ->
    Host = openpixie_config:ollama_host(),
    Url = Host ++ "/api/chat",
    BodyMap0 = #{
        model => Model,
        messages => Messages,
        stream => true
    },
    BodyMap = case Tools of
        [] -> BodyMap0;
        _ ->
            OllamaTools = [prepare_tool(maps:get(function, T)) || T <- Tools],
            BodyMap0#{tools => OllamaTools}
    end,
    Body = jsx:encode(BodyMap),
    openpixie_log:info("LLM streaming request body length: ~p", [byte_size(Body)]),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    Timeout = openpixie_config:llm_timeout_ms(),
    case hackney:request(post, Url, Headers, Body, [async, {recv_timeout, Timeout}]) of
        {ok, ClientRef} ->
            Result = collect_stream(ClientRef, Callback, #{}, <<"">>, []),
            hackney:close(ClientRef),
            Result;
        {ok, _StatusCode, _RespHeaders, ClientRef} ->
            Result = collect_stream(ClientRef, Callback, #{}, <<"">>, []),
            hackney:close(ClientRef),
            Result;
        {error, Reason} ->
            {error, Reason}
    end.

collect_stream(ClientRef, Callback, MsgAcc, ContentAcc, ToolCallsAcc) ->
    receive
        {hackney_response, ClientRef, {status, _StatusCode}} ->
            collect_stream(ClientRef, Callback, MsgAcc, ContentAcc, ToolCallsAcc);
        {hackney_response, ClientRef, {headers, _Headers}} ->
            collect_stream(ClientRef, Callback, MsgAcc, ContentAcc, ToolCallsAcc);
        {hackney_response, ClientRef, BinChunk} when is_binary(BinChunk) ->
            Lines = binary:split(BinChunk, <<"\n">>, [global]),
            {NewMsgAcc, NewContentAcc, NewToolCallsAcc, IsDone} =
                process_stream_lines(Lines, MsgAcc, ContentAcc, ToolCallsAcc, Callback, false),
            case IsDone of
                true -> {ok, NewMsgAcc, NewContentAcc, NewToolCallsAcc};
                false -> collect_stream(ClientRef, Callback, NewMsgAcc, NewContentAcc, NewToolCallsAcc)
            end;
        {hackney_response, ClientRef, done} ->
            {ok, MsgAcc, ContentAcc, ToolCallsAcc};
        {hackney_response, ClientRef, {error, Reason}} ->
            {error, Reason}
    after ?STREAM_CHUNK_TIMEOUT_MS ->
        hackney:close(ClientRef),
        {error, stream_timeout}
    end.

process_stream_lines([], MsgAcc, ContentAcc, ToolCallsAcc, _Callback, Done) ->
    {MsgAcc, ContentAcc, ToolCallsAcc, Done};
process_stream_lines([<<>> | Rest], MsgAcc, ContentAcc, ToolCallsAcc, Callback, Done) ->
    process_stream_lines(Rest, MsgAcc, ContentAcc, ToolCallsAcc, Callback, Done);
process_stream_lines([Line | Rest], MsgAcc, ContentAcc, ToolCallsAcc, Callback, Done) ->
    case jsx:is_json(Line) of
        true ->
            try
                Chunk = jsx:decode(Line, [return_maps]),
                Msg = maps:get(<<"message">>, Chunk, #{}),
                NewMsgAcc = merge_msg(MsgAcc, Msg),
                ContentPart = maps:get(<<"content">>, Msg, <<"">>),
                NewContentAcc = case ContentPart of
                    <<"">> -> ContentAcc;
                    _ ->
                    case is_function(Callback, 1) of
                        true -> Callback(ContentPart);
                        false -> ok
                    end,
                    <<ContentAcc/binary, ContentPart/binary>>
                end,
                ChunkToolCalls = maps:get(<<"tool_calls">>, Msg, []),
                NewToolCallsAcc = ToolCallsAcc ++ ChunkToolCalls,
                ChunkDone = maps:get(<<"done">>, Chunk, false),
                NewDone = Done orelse (ChunkDone =:= true),
                process_stream_lines(Rest, NewMsgAcc, NewContentAcc, NewToolCallsAcc, Callback, NewDone)
            catch _:_ ->
                process_stream_lines(Rest, MsgAcc, ContentAcc, ToolCallsAcc, Callback, Done)
            end;
        false ->
            process_stream_lines(Rest, MsgAcc, ContentAcc, ToolCallsAcc, Callback, Done)
    end.

merge_msg(undefined, New) -> New;
merge_msg(Old, New) ->
    maps:merge(Old, New).

do_chat(Model, Messages, Tools, Opts) ->
    Host = openpixie_config:ollama_host(),
    Url = Host ++ "/api/chat",
    BodyMap = #{
        model => Model,
        messages => Messages,
        stream => false
    },
    BodyMap2 = case Tools of
        [] -> BodyMap;
        _ ->
            OllamaTools = [prepare_tool(maps:get(function, T)) || T <- Tools],
            BodyMap#{tools => OllamaTools}
    end,
    BodyMap3 = case maps:get(options, Opts, undefined) of
        undefined -> BodyMap2;
        Options -> BodyMap2#{options => Options}
    end,
    Body = jsx:encode(BodyMap3),
    openpixie_log:info("LLM request body length: ~p", [byte_size(Body)]),
    Fun = fun() -> hackney_request(post, Url, Body) end,
    case openpixie_circuit_breaker:call(Fun) of
        {ok, Response} ->
            {ok, Response};
        {error, circuit_open} ->
            {error, circuit_open};
        {error, Reason} ->
            {error, Reason}
    end.

list_models() ->
    Host = openpixie_config:ollama_host(),
    Url = Host ++ "/api/tags",
    Fun = fun() -> hackney_request(get, Url, <<>>) end,
    openpixie_circuit_breaker:call(Fun).

show_model(Model) ->
    Host = openpixie_config:ollama_host(),
    Url = Host ++ "/api/show",
    Body = jsx:encode(#{model => Model}),
    Fun = fun() -> hackney_request(post, Url, Body) end,
    openpixie_circuit_breaker:call(Fun).

count_tokens(Messages) when is_list(Messages) ->
    Total = lists:foldl(fun(Msg, Acc) ->
        Content = maps:get(content, Msg, <<"">>),
        case is_binary(Content) of
            true -> byte_size(Content) + Acc;
            false -> Acc
        end
    end, 0, Messages),
    Total div ?ESTIMATED_CHARS_PER_TOKEN.

count_tokens_estimated(Text) when is_binary(Text) ->
    byte_size(Text) div ?ESTIMATED_CHARS_PER_TOKEN.

prepare_tool(ToolMap) ->
    json_safe(ToolMap).

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
json_safe(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

json_safe_key(K) when is_binary(K) -> K;
json_safe_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_safe_key(K) -> iolist_to_binary(io_lib:format("~p", [K])).

hackney_request(Method, Url, Body) ->
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    Timeout = openpixie_config:llm_timeout_ms(),
    case hackney:request(Method, Url, Headers, Body, [{recv_timeout, Timeout}]) of
        {ok, 200, _RespHeaders, Client} ->
            {ok, RespBody} = hackney:body(Client),
            Decoded = jsx:decode(RespBody, [return_maps]),
            {ok, Decoded};
        {ok, StatusCode, _RespHeaders, Client} ->
            {ok, RespBody} = hackney:body(Client),
            {error, {status, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.