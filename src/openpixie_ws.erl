-module(openpixie_ws).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-define(HEARTBEAT_INTERVAL, 30000).
-define(HEARTBEAT_TIMEOUT, 120000).

init(Req, _State) ->
    case authenticate_ws(Req) of
        {ok, _} ->
            {cowboy_websocket, Req, #{}};
        {error, _Reason} ->
            {ok, cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req), #{}}
    end.

authenticate_ws(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Key/binary>> ->
            openpixie_auth:authenticate(Key);
        _ ->
            Qs = cowboy_req:parse_qs(Req),
            case proplists:get_value(<<"token">>, Qs) of
                undefined -> {error, no_token};
                Key -> openpixie_auth:authenticate(Key)
            end
    end.

websocket_init(State) ->
    {ok, TRef} = timer:send_interval(?HEARTBEAT_INTERVAL, send_heartbeat),
    {ok, State#{current_topic_id => undefined, topics => #{},
                 heartbeat_sent => false, heartbeat_timer => undefined,
                 heartbeat_tref => TRef, agent_ref => undefined}}.

websocket_handle({text, MsgBin}, State) ->
    Msg = jsx:decode(MsgBin, [return_maps]),
    case maps:get(<<"type">>, Msg, undefined) of
        <<"chat">> -> handle_chat(Msg, State);
        <<"connect">> -> handle_connect(Msg, State);
        <<"new_topic">> -> handle_new_topic(Msg, State);
        <<"switch_topic">> -> handle_switch_topic(Msg, State);
        <<"list_topics">> -> handle_list_topics(Msg, State);
        <<"resolve_topic">> -> handle_resolve_topic(Msg, State);
        <<"delete_topic">> -> handle_delete_topic(Msg, State);
        <<"tool_confirm">> -> handle_tool_confirm(Msg, State);
        <<"heartbeat">> -> handle_heartbeat(State);
        _ -> {reply, {text, jsx:encode(#{error => unknown_message_type})}, State}
    end;

websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({topic_message, Data}, State) ->
    {reply, {text, jsx:encode(Data)}, State};

websocket_info({stream_chunk, ContentChunk}, State) ->
    {reply, {text, jsx:encode(#{type => chunk, content => ContentChunk})}, State};

websocket_info(stream_done, State) ->
    {ok, reset_heartbeat(State)};

websocket_info({tool_step, StepInfo}, State) ->
    {reply, {text, jsx:encode(#{type => tool_step, tool => maps:get(tool, StepInfo), args => maps:get(args, StepInfo), status => maps:get(status, StepInfo)})}, State};

websocket_info({tool_confirm_request, ToolName, Args, Reason}, State) ->
    case maps:get(heartbeat_timer, State, undefined) of
        undefined -> ok;
        HTRef -> erlang:cancel_timer(HTRef)
    end,
    AgentPid = maps:get(agent_ref, State, undefined),
    {reply, {text, jsx:encode(#{type => tool_confirm_request, tool => ToolName, args => Args, reason => Reason})},
     State#{pending_confirmation => {ToolName, Args, AgentPid}, heartbeat_sent => false, heartbeat_timer => undefined}};

websocket_info({agent_response, Data}, State) ->
    NewState = State#{agent_ref => undefined},
    send_agent_response(Data, NewState);

websocket_info({agent_down, _Ref, _Pid, Reason}, State) ->
    ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
    ErrMsg = #{type => error, error => agent_crash, message =>
        iolist_to_binary(["Agent process crashed: ", ReasonBin])},
    {reply, {text, jsx:encode(ErrMsg)}, State#{agent_ref => undefined}};

websocket_info(send_heartbeat, State) ->
    case maps:get(heartbeat_sent, State, false) of
        true ->
            {[{shutdown_reason, heartbeat_timeout}, close], State};
        false ->
            TRef = erlang:send_after(?HEARTBEAT_TIMEOUT, self(), heartbeat_timeout),
            {reply, {text, jsx:encode(#{type => heartbeat})},
             State#{heartbeat_sent => true, heartbeat_timer => TRef}}
    end;

websocket_info(heartbeat_timeout, State) ->
    {[{shutdown_reason, heartbeat_timeout}, close], State};

websocket_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    Topics = maps:get(topics, State, #{}),
    ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
    case find_topic_id_by_pid(Pid, Topics) of
        undefined ->
            {reply, {text, jsx:encode(#{type => session_ended, reason => ReasonBin})}, State};
        TopicId ->
            NewTopics = maps:remove(TopicId, Topics),
            NewCurrent = case maps:get(current_topic_id, State) of
                TopicId -> undefined;
                Other -> Other
            end,
            {reply, {text, jsx:encode(#{type => topic_ended, topic_id => TopicId, reason => ReasonBin})},
             State#{topics => NewTopics, current_topic_id => NewCurrent}}
    end;

websocket_info(_Info, State) ->
    {ok, State}.

terminate(Reason, _Req, State) when is_map(State) ->
    case maps:get(heartbeat_tref, State, undefined) of
        undefined -> ok;
        TRef -> timer:cancel(TRef)
    end,
    case maps:get(heartbeat_timer, State, undefined) of
        undefined -> ok;
        HTRef -> erlang:cancel_timer(HTRef)
    end,
    Topics = maps:get(topics, State, #{}),
    maps:fold(fun(_TopicId, TopicPid, _Acc) ->
        catch openpixie_topic:unsubscribe(TopicPid, self())
    end, ok, Topics),
    error_logger:info_msg("WS terminated: ~p~n", [Reason]),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

handle_heartbeat(State) ->
    case maps:get(heartbeat_timer, State, undefined) of
        undefined -> ok;
        TRef -> erlang:cancel_timer(TRef)
    end,
    {ok, reset_heartbeat(State#{heartbeat_sent => false, heartbeat_timer => undefined})}.

reset_heartbeat(State) ->
    case maps:get(heartbeat_timer, State, undefined) of
        undefined -> ok;
        TRef -> erlang:cancel_timer(TRef)
    end,
    State#{heartbeat_sent => false, heartbeat_timer => undefined}.

handle_chat(Msg, State) ->
    Content = maps:get(<<"content">>, Msg, <<"">>),
    Topics = maps:get(topics, State, #{}),
    CurrentTopicId = maps:get(current_topic_id, State),
    case find_topic_pid(CurrentTopicId, Topics) of
        undefined ->
            {reply, {text, jsx:encode(#{type => error, error => no_active_topic})}, State};
        TopicPid ->
            UserMsg = #{role => user, content => Content},
            {ok, _History} = openpixie_topic:send_message(TopicPid, UserMsg),
            WsPid = self(),
            AgentRef = spawn(fun() ->
                Response = try run_agent_turn(TopicPid, WsPid, 0)
                    catch Class:Reason2:Stacktrace ->
                        error_logger:error_msg("Agent error ~p:~p Stacktrace: ~p~n", [Class, Reason2, Stacktrace]),
                        #{type => error, error => agent_crash,
                          message => iolist_to_binary(
                              [atom_to_binary(Class, utf8), ": ",
                               io_lib:format("~p", [Reason2])])}
                end,
                WsPid ! {agent_response, Response}
            end),
            erlang:monitor(process, AgentRef),
            {reply, {text, jsx:encode(#{type => thinking, topic_id => CurrentTopicId})},
             State#{agent_ref => AgentRef}}
    end.

handle_connect(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    case TopicId of
        undefined ->
            case start_new_topic(<<"general">>, <<"New conversation">>, undefined) of
                {ok, NewTopicId, TopicPid} ->
                    erlang:monitor(process, TopicPid),
                    ok = openpixie_topic:subscribe(TopicPid, self()),
                    NewTopics = maps:put(NewTopicId, TopicPid, maps:get(topics, State, #{})),
                    {History, _} = get_topic_history(TopicPid),
                    Reply = #{type => connected, topic_id => NewTopicId, history => History,
                               title => <<"New conversation">>, channel_id => <<"general">>},
                    {reply, {text, jsx:encode(Reply)},
                     State#{current_topic_id => NewTopicId, topics => NewTopics, heartbeat_sent => false}};
                {error, Reason} ->
                    {reply, {text, jsx:encode(#{type => error, error => Reason})}, State}
            end;
        _ ->
            case openpixie_topic:resume(TopicId) of
                {ok, TopicPid} ->
                    erlang:monitor(process, TopicPid),
                    ok = openpixie_topic:subscribe(TopicPid, self()),
                    NewTopics = maps:put(TopicId, TopicPid, maps:get(topics, State, #{})),
                    {History, TopicState} = get_topic_history(TopicPid),
                    Reply2 = #{type => connected, topic_id => TopicId, history => History,
                               title => maps:get(title, TopicState, <<"">>),
                               channel_id => maps:get(channel_id, TopicState, <<"general">>),
                               parent_id => maps:get(parent_id, TopicState, undefined)},
                    {reply, {text, jsx:encode(Reply2)},
                     State#{current_topic_id => TopicId, topics => NewTopics, heartbeat_sent => false}};
                {error, not_found} ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_not_found})}, State}
            end
    end.

handle_new_topic(Msg, State) ->
    ChannelId = maps:get(<<"channel_id">>, Msg, <<"general">>),
    Title = maps:get(<<"title">>, Msg, <<"Untitled">>),
    ParentId = maps:get(<<"parent_id">>, Msg, undefined),
    case start_new_topic(ChannelId, Title, ParentId) of
        {ok, TopicId, TopicPid} ->
            erlang:monitor(process, TopicPid),
            ok = openpixie_topic:subscribe(TopicPid, self()),
            NewTopics = maps:put(TopicId, TopicPid, maps:get(topics, State, #{})),
            Reply = #{type => topic_created, topic_id => TopicId, title => Title,
                      channel_id => ChannelId, parent_id => ParentId},
            {reply, {text, jsx:encode(Reply)},
             State#{current_topic_id => TopicId, topics => NewTopics}};
        {error, Reason} ->
            {reply, {text, jsx:encode(#{type => error, error => Reason})}, State}
    end.

handle_switch_topic(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    Topics = maps:get(topics, State, #{}),
    CurrentTopicId = maps:get(current_topic_id, State),
    case maps:get(TopicId, Topics, undefined) of
        undefined ->
            case openpixie_topic:resume(TopicId) of
                {ok, TopicPid} ->
                    erlang:monitor(process, TopicPid),
                    ok = openpixie_topic:subscribe(TopicPid, self()),
                    NewTopics = maps:put(TopicId, TopicPid, Topics),
                    {History, TopicState} = get_topic_history(TopicPid),
                    Reply = #{type => topic_switched, topic_id => TopicId,
                              history => History,
                              title => maps:get(title, TopicState, <<"">>),
                              channel_id => maps:get(channel_id, TopicState, <<"general">>)},
                    {reply, {text, jsx:encode(Reply)},
                     State#{current_topic_id => TopicId, topics => NewTopics}};
                {error, not_found} ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_not_found})}, State}
            end;
        _TopicPid when CurrentTopicId =:= TopicId ->
            {reply, {text, jsx:encode(#{type => topic_switched, topic_id => TopicId, history => []})}, State};
        TopicPid ->
            {History, _} = get_topic_history(TopicPid),
            Reply2 = #{type => topic_switched, topic_id => TopicId, history => History},
            {reply, {text, jsx:encode(Reply2)}, State#{current_topic_id => TopicId}}
    end.

handle_list_topics(Msg, State) ->
    ChannelId = maps:get(<<"channel_id">>, Msg, undefined),
    RawTopics = case ChannelId of
        undefined -> openpixie_topic_store:list();
        _ -> openpixie_topic_store:list_by_channel(ChannelId)
    end,
    Formatted = lists:map(fun({Id, Pid, Status, ChId, Title}) ->
        Alive = is_pid(Pid) andalso is_process_alive(Pid),
        #{id => Id, status => Status, channel_id => ChId, title => Title, active => Alive}
    end, RawTopics),
    Channels = openpixie_channel:list(),
    ChannelList = lists:map(fun({Name, Data}) ->
        Data#{name => Name}
    end, Channels),
    {reply, {text, jsx:encode(#{type => topics_list, topics => Formatted, channels => ChannelList})}, State}.

handle_resolve_topic(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    case TopicId of
        undefined ->
            {reply, {text, jsx:encode(#{type => error, error => missing_topic_id})}, State};
        _ ->
            Topics = maps:get(topics, State, #{}),
            case find_topic_pid(TopicId, Topics) of
                undefined ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_not_found})}, State};
                TopicPid ->
                    ok = openpixie_topic:resolve(TopicPid),
                    {reply, {text, jsx:encode(#{type => topic_resolved, topic_id => TopicId})}, State}
            end
    end.

handle_delete_topic(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    case TopicId of
        undefined ->
            {reply, {text, jsx:encode(#{type => error, error => missing_topic_id})}, State};
        _ ->
            Topics = maps:get(topics, State, #{}),
            case find_topic_pid(TopicId, Topics) of
                undefined ->
                    ok = openpixie_topic:delete_topic(TopicId),
                    NewTopics = maps:remove(TopicId, Topics),
                    NewCurrent = case maps:get(current_topic_id, State) of
                        TopicId -> undefined;
                        Other -> Other
                    end,
                    {reply, {text, jsx:encode(#{type => topic_deleted, topic_id => TopicId})},
                     State#{topics => NewTopics, current_topic_id => NewCurrent}};
                TopicPid ->
                    catch openpixie_topic:unsubscribe(TopicPid, self()),
                    ok = openpixie_topic:delete_topic(TopicId),
                    NewTopics = maps:remove(TopicId, Topics),
                    NewCurrent = case maps:get(current_topic_id, State) of
                        TopicId -> undefined;
                        Other -> Other
                    end,
                    {reply, {text, jsx:encode(#{type => topic_deleted, topic_id => TopicId})},
                     State#{topics => NewTopics, current_topic_id => NewCurrent}}
            end
    end.

handle_tool_confirm(Msg, State) ->
    case maps:get(<<"approved">>, Msg, false) of
        true ->
            Pending = maps:get(pending_confirmation, State, undefined),
            case Pending of
                undefined ->
                    {reply, {text, jsx:encode(#{type => error, message => <<"No pending confirmation">>})}, State};
                {ToolName, Args, AgentPid} when is_pid(AgentPid) ->
                    AgentPid ! {tool_confirm_reply, approved},
                    {reply, {text, jsx:encode(#{type => tool_approved, tool => ToolName})},
                     maps:remove(pending_confirmation, State)}
            end;
        false ->
            Pending2 = maps:get(pending_confirmation, State, undefined),
            case Pending2 of
                {ToolName, _Args, AgentPid} when is_pid(AgentPid) ->
                    AgentPid ! {tool_confirm_reply, denied},
                    {reply, {text, jsx:encode(#{type => tool_rejected, tool => ToolName})},
                     maps:remove(pending_confirmation, State)};
                undefined ->
                    {reply, {text, jsx:encode(#{type => error, message => <<"No pending confirmation">>})}, State}
            end
    end.

send_agent_response(#{type := response, message := Msg}, State) ->
    {reply, {text, jsx:encode(#{type => response, message => Msg})}, State};
send_agent_response(#{type := error} = Data, State) ->
    {reply, {text, jsx:encode(Data)}, State};
send_agent_response(Data, State) ->
    {reply, {text, jsx:encode(Data)}, State}.

find_topic_pid(CurrentTopicId, Topics) when is_binary(CurrentTopicId) ->
    maps:get(CurrentTopicId, Topics, undefined);
find_topic_pid(_, _) ->
    undefined.

find_topic_id_by_pid(Pid, Topics) ->
    maps:fold(fun(TopicId, TPid, _Acc) when TPid =:= Pid -> TopicId;
                 (_, _, Acc) -> Acc
              end, undefined, Topics).

start_new_topic(ChannelId, Title, ParentId) ->
    case openpixie_topic_sup:start_topic() of
        {ok, TopicId, TopicPid} ->
            case ParentId of
                undefined -> ok;
                _ -> ok = openpixie_topic:set_fork(TopicPid, Title, ChannelId, ParentId)
            end,
            openpixie_topic_store:update(TopicId, ChannelId, Title),
            {ok, TopicId, TopicPid};
        {error, Reason} ->
            {error, Reason}
    end.

get_topic_history(TopicPid) ->
    {ok, History} = openpixie_topic:get_history(TopicPid),
    TopicState = openpixie_topic:get_state(TopicPid),
    {format_history(History), TopicState}.

format_history(Messages) ->
    lists:map(fun(M) ->
        case maps:get(role, M, undefined) of
            user -> #{role => user, content => maps:get(content, M, <<"">>)};
            assistant -> #{role => assistant, content => maps:get(content, M, <<"">>)};
            _ -> M
        end
    end, Messages).

run_agent_turn(TopicPid, WsPid, Depth) when Depth < 10 ->
    {ok, History} = openpixie_topic:get_history(TopicPid),
    SystemPrompt = openpixie_context:build_system_prompt(),
    Model = openpixie_config:ollama_model(),
    Tools = openpixie_tools:tool_schema(),
    MaxTokens = openpixie_config:max_context_tokens(),
    TrimmedHistory = openpixie_context:trim_messages(History, MaxTokens),
    Messages = [#{role => system, content => SystemPrompt} | TrimmedHistory],
    {ok, acquired} = openpixie_semaphore:acquire(),
    StreamCallback = fun(ContentChunk) ->
        WsPid ! {stream_chunk, ContentChunk}
    end,
    StreamResult = try
        openpixie_ollama:stream_chat_with_tools(Model, Messages, Tools, StreamCallback)
    after
        openpixie_semaphore:release()
    end,
    case StreamResult of
        {ok, _RespMsg, FullContent, ToolCallsAcc} when is_list(ToolCallsAcc), length(ToolCallsAcc) > 0 ->
            WsPid ! stream_done,
            {ok, acquired} = openpixie_semaphore:acquire(),
            NonStreamResult = try
                openpixie_ollama:chat_with_tools(Model, Messages, Tools)
            after
                openpixie_semaphore:release()
            end,
            case NonStreamResult of
                {ok, #{<<"message">> := RespMsg}} ->
                    NSContent = maps:get(<<"content">>, RespMsg, <<"">>),
                    case maps:get(<<"tool_calls">>, RespMsg, []) of
                        [] ->
                            {ok, _} = openpixie_topic:send_message(TopicPid, RespMsg),
                            #{type => response, message => #{content => NSContent}};
                        NSToolCalls ->
                            {ok, _} = openpixie_topic:send_message(TopicPid, RespMsg),
                            ToolResults = execute_tool_calls(NSToolCalls, WsPid),
                            lists:foreach(fun(TR) ->
                                {ok, _} = openpixie_topic:send_message(TopicPid, TR)
                            end, ToolResults),
                            run_agent_turn(TopicPid, WsPid, Depth + 1)
                    end;
                {error, circuit_open} ->
                    #{type => error, error => circuit_open, message => <<"LLM service temporarily unavailable">>};
                {error, Reason} ->
                    #{type => error, error => Reason}
            end;
        {ok, _RespMsg, FullContent, _ToolCalls} ->
            WsPid ! stream_done,
            FinalMsg = #{role => assistant, content => FullContent},
            {ok, _} = openpixie_topic:send_message(TopicPid, FinalMsg),
            #{type => response, message => #{content => FullContent}};
        {error, circuit_open} ->
            #{type => error, error => circuit_open, message => <<"LLM service temporarily unavailable">>};
        {error, Reason} ->
            #{type => error, error => Reason}
    end;

run_agent_turn(_TopicPid, _WsPid, _Depth) ->
    #{type => error, error => max_tool_depth}.

execute_tool_calls(ToolCalls, WsPid) ->
    lists:filtermap(fun(#{<<"function">> := #{<<"name">> := Name, <<"arguments">> := RawArgs}} = Call) ->
        CallId = maps:get(<<"id">>, Call, undefined),
        Args = case RawArgs of
            Map when is_map(Map) -> Map;
            Bin when is_binary(Bin) ->
                case jsx:is_json(Bin) of
                    true -> jsx:decode(Bin, [return_maps]);
                    false -> #{<<"command">> => Bin}
                end
        end,
        WsPid ! {tool_step, #{tool => Name, args => Args, status => running}},
        Result = openpixie_tools:execute(Name, Args),
        case maps:get(error, Result, undefined) of
            requires_confirmation ->
                Reason = maps:get(reason, Result, unknown),
                WsPid ! {tool_confirm_request, Name, Args, Reason},
                receive
                    {tool_confirm_reply, approved} ->
                        ApprovedResult = openpixie_tools:execute(Name, Args, #{confirmation => approved}),
                        WsPid ! {tool_step, #{tool => Name, args => Args, status => approved}},
                        SafeResult = json_safe(ApprovedResult),
                        Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                        ToolMsg = #{role => tool, content => Encoded, name => Name},
                        ToolMsg2 = case CallId of
                            undefined -> ToolMsg;
                            Id -> ToolMsg#{<<"tool-call-id">> => Id}
                        end,
                        {true, ToolMsg2};
                    {tool_confirm_reply, denied} ->
                        WsPid ! {tool_step, #{tool => Name, args => Args, status => denied}},
                        DeniedResult = #{success => false, error => confirmation_denied, tool => Name},
                        SafeResult = json_safe(DeniedResult),
                        Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                        ToolMsg = #{role => tool, content => Encoded, name => Name},
                        ToolMsg2 = case CallId of
                            undefined -> ToolMsg;
                            Id -> ToolMsg#{<<"tool-call-id">> => Id}
                        end,
                        {true, ToolMsg2}
                after 120000 ->
                        WsPid ! {tool_step, #{tool => Name, args => Args, status => timeout}},
                        TimeoutResult = #{success => false, error => confirmation_timeout, tool => Name},
                        SafeResult = json_safe(TimeoutResult),
                        Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                        ToolMsg = #{role => tool, content => Encoded, name => Name},
                        {true, ToolMsg}
                end;
            _ ->
                WsPid ! {tool_step, #{tool => Name, args => Args, status => done}},
                SafeResult = json_safe(Result),
                Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                ToolMsg = #{role => tool, content => Encoded, name => Name},
                ToolMsg2 = case CallId of
                    undefined -> ToolMsg;
                    Id -> ToolMsg#{<<"tool-call-id">> => Id}
                end,
                {true, ToolMsg2}
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