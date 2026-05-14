-module(openpixie_ws).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-define(HEARTBEAT_INTERVAL, 30000).
-define(HEARTBEAT_TIMEOUT, 3600000).
-define(MAX_LLM_RETRIES, 3).
-define(RETRY_BASE_MS, 2000).

init(Req, _State) ->
    case authenticate_ws(Req) of
        {ok, _} ->
            {cowboy_websocket, Req, #{}, #{idle_timeout => 3600000}};
        {error, no_token} ->
            {ok, cowboy_req:reply(401, #{}, <<"Authentication required. Provide an API key via ?token= or Authorization header.">>, Req), #{}};
        {error, invalid_key} ->
            {ok, cowboy_req:reply(401, #{}, <<"Invalid API key.">>, Req), #{}};
        {error, _} ->
            {ok, cowboy_req:reply(401, #{}, <<"Authentication failed.">>, Req), #{}}
    end.

authenticate_ws(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Key/binary>> ->
            openpixie_auth:authenticate(Key);
        _ ->
            Qs = cowboy_req:parse_qs(Req),
            case proplists:get_value(<<"token">>, Qs) of
                undefined ->
                    Cookies = cowboy_req:parse_cookies(Req),
                    case proplists:get_value(<<"openpixie_session">>, Cookies) of
                        undefined ->
                            case is_same_origin(Req) of
                                true -> {ok, same_origin};
                                false -> {error, no_token}
                            end;
                        SessionToken -> openpixie_auth:validate_session(SessionToken)
                    end;
                Key -> openpixie_auth:authenticate(Key)
            end
    end.

is_same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> false;
        Origin ->
            Host = cowboy_req:header(<<"host">>, Req, <<"">>),
            try
                OriginUrl = uri_string:parse(Origin),
                OriginHost = maps:get(host, OriginUrl, <<>>),
                OriginPort = maps:get(port, OriginUrl, undefined),
                HostWithoutPort = host_without_port(Host),
                HostsMatch = OriginHost =:= HostWithoutPort,
                PortsMatch = case {OriginPort, binary:match(Host, <<$:>>)} of
                    {undefined, nomatch} -> true;
                    {undefined, _} -> true;
                    {P, nomatch} -> P =:= 80 orelse P =:= 443;
                    {P, _} -> integer_to_binary(P) =:= port_from_host(Host)
                end,
                HostsMatch andalso PortsMatch
            catch
                _:_ ->
                    binary:match(Origin, Host) =/= nomatch
            end
    end.

host_without_port(Host) ->
    case binary:match(Host, <<$:>>) of
        nomatch -> Host;
        {Pos, _} -> binary:part(Host, 0, Pos)
    end.

port_from_host(Host) ->
    case binary:match(Host, <<$:>>) of
        nomatch -> <<"80">>;
        {Pos, _} ->
            binary:part(Host, Pos + 1, byte_size(Host) - Pos - 1)
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
        <<"reopen_topic">> -> handle_reopen_topic(Msg, State);
        <<"delete_topic">> -> handle_delete_topic(Msg, State);
        <<"tool_confirm">> -> handle_tool_confirm(Msg, State);
        <<"ask_user_response">> -> handle_ask_user_response(Msg, State);
        <<"set_permission_mode">> -> handle_set_permission_mode(Msg, State);
        <<"get_config">> -> handle_get_config(State);
        <<"set_config">> -> handle_set_config(Msg, State);
        <<"frontend_error">> -> handle_frontend_error(Msg, State);
        <<"heartbeat">> -> handle_heartbeat(State);
        <<"interrupt">> -> handle_interrupt(State);
        _ -> {reply, {text, jsx:encode(#{type => error, error => unknown_message_type, message => <<"Unknown message type.">>})}, State}
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

websocket_info({guardian_check, ToolName, Args}, State) ->
    {reply, {text, jsx:encode(#{type => guardian_check, tool => ToolName, args => Args})}, State};

websocket_info({guardian_result, ToolName, Result}, State) ->
    Status = case maps:get(error, Result, undefined) of
        guardian_rejected -> <<"rejected">>;
        _ ->
            case maps:get(success, Result, false) of
                true -> <<"passed">>;
                false -> <<"warned">>
            end
    end,
    Reason = case maps:get(reason, Result, undefined) of
        undefined -> null;
        R when is_binary(R) -> R;
        R -> iolist_to_binary(io_lib:format("~p", [R]))
    end,
    {reply, {text, jsx:encode(#{type => guardian_result, tool => ToolName, status => Status, reason => Reason})}, State};

websocket_info({tool_confirm_request, ToolName, Args, Reason}, State) ->
    case maps:get(heartbeat_timer, State, undefined) of
        undefined -> ok;
        HTRef -> erlang:cancel_timer(HTRef)
    end,
    AgentPid = maps:get(agent_ref, State, undefined),
    {reply, {text, jsx:encode(#{type => tool_confirm_request, tool => ToolName, args => Args, reason => Reason})},
     State#{pending_confirmation => {ToolName, Args, AgentPid}, heartbeat_sent => false, heartbeat_timer => undefined}};

websocket_info({dashboard_refresh_hint}, State) ->
    {reply, {text, jsx:encode(#{type => dashboard_refresh_hint})}, State};

websocket_info({ask_user_request, ToolName, Question, Context}, State) ->
    {reply, {text, jsx:encode(#{type => ask_user_request, tool => ToolName, question => Question, context => Context})}, State};

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

handle_interrupt(State) ->
    case maps:get(agent_ref, State, undefined) of
        undefined -> {ok, State};
        AgentPid when is_pid(AgentPid) ->
            erlang:exit(AgentPid, interrupt),
            {reply, {text, jsx:encode(#{type => interrupted})},
             State#{agent_ref => undefined}}
    end.

handle_frontend_error(Msg, State) ->
    CurrentTopicId = maps:get(current_topic_id, State, undefined),
    Topics = maps:get(topics, State, #{}),
    case CurrentTopicId of
        undefined -> {ok, State};
        _ ->
            TopicPid = maps:get(CurrentTopicId, Topics, undefined),
            ErrMsg = maps:get(<<"message">>, Msg, <<"">>),
            ErrSource = maps:get(<<"source">>, Msg, <<"">>),
            ErrLine = maps:get(<<"lineno">>, Msg, 0),
            ErrCol = maps:get(<<"colno">>, Msg, 0),
            ErrStack = maps:get(<<"stack">>, Msg, <<"">>),
            ErrInfo = iolist_to_binary([<<"Frontend error: ">>, ErrMsg,
                case ErrSource of <<>> -> <<>>; _ -> <<" at ", ErrSource/binary>> end,
                case ErrLine of 0 -> <<>>; _ -> iolist_to_binary(io_lib:format(":~w", [ErrLine])) end,
                case ErrCol of 0 -> <<>>; _ -> iolist_to_binary(io_lib:format(":~w", [ErrCol])) end,
                case ErrStack of <<>> -> <<>>; _ -> <<"\n", ErrStack/binary>> end]),
            Snippet = get_error_snippet(ErrLine),
            FullContent = case Snippet of
                <<>> -> ErrInfo;
                _ -> iolist_to_binary([ErrInfo, <<"\n\nContext around error line:\n">>, Snippet])
            end,
            case TopicPid of
                undefined -> {ok, State};
                _ ->
                    ToolMsg = #{role => tool, content => FullContent, name => <<"frontend_error">>},
                    catch openpixie_topic:send_message(TopicPid, ToolMsg),
                    {ok, State}
            end
    end.

handle_set_permission_mode(Msg, State) ->
    ModeBin = maps:get(<<"mode">>, Msg, <<"ask">>),
    Mode = case ModeBin of
        <<"trust">> -> trust;
        <<"auto_noselfmod">> -> auto_noselfmod;
        <<"ask">> -> ask;
        <<"sandbox">> -> sandbox;
        <<"plan">> -> plan;
        _ -> ask
    end,
    case catch openpixie_permissions:set_mode(Mode) of
        ok ->
            case catch openpixie_config:set_permission_mode(Mode) of
                ok -> ok;
                _ -> ok
            end,
            {reply, {text, jsx:encode(#{type => permission_mode_set, mode => ModeBin})}, State};
        _ ->
            {reply, {text, jsx:encode(#{type => error, error => invalid_permission_mode, message => <<"Invalid permission mode.">>})}, State}
    end.

handle_get_config(State) ->
    Config = #{
        ollama_host => list_to_binary(openpixie_config:ollama_host()),
        ollama_model => openpixie_config:ollama_model(),
        permission_mode => atom_to_binary(openpixie_config:permission_mode(), utf8),
        llm_timeout_ms => openpixie_config:llm_timeout_ms(),
        max_context_tokens => openpixie_config:max_context_tokens(),
        idle_timeout_minutes => openpixie_config:idle_timeout_minutes()
    },
    {reply, {text, jsx:encode(#{type => config, config => Config})}, State}.

handle_set_config(Msg, State) ->
    Updates = maps:get(<<"updates">>, Msg, #{}),
    Result = openpixie_http_config:apply_config(Updates),
    {reply, {text, jsx:encode(#{type => config_updated, result => Result})}, State}.

get_error_snippet(ErrLine) when ErrLine > 0 ->
    DashPath = filename:join([openpixie_config:workspace(), "priv", "dashboard", "index.html"]),
    case file:read_file(DashPath) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n">>, [global]),
            Start = max(1, ErrLine - 2),
            End = min(length(Lines), ErrLine + 2),
            SnippetLines = lists:sublist(Lines, Start, End - Start + 1),
            NumberedLines = lists:zipwith(fun(N, L) ->
                iolist_to_binary(io_lib:format("~w: ~s", [N, L]))
            end, lists:seq(Start, End - 1), SnippetLines),
            iolist_to_binary(lists:join(<<"\n">>, NumberedLines));
        {error, _} -> <<>>
    end;
get_error_snippet(_) -> <<>>.

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
            {reply, {text, jsx:encode(#{type => error, error => no_active_topic, message => humanize_error(no_active_topic)})}, State};
        TopicPid when is_pid(TopicPid) ->
            WasResolved = case catch openpixie_topic:get_state(TopicPid) of
                #{status := resolved} -> true;
                _ -> false
            end,
            ReopenMsg = case WasResolved of
                true -> openpixie_topic:reopen(TopicPid), [{text, jsx:encode(#{type => topic_reopened, topic_id => CurrentTopicId})}];
                false -> []
            end,
            case catch openpixie_topic:send_message(TopicPid, #{role => user, content => Content}) of
                {ok, _History} ->
                     WsPid = self(),
                     AgentRef = spawn(fun() ->
                         put(topic_pid, TopicPid),
                         Response = try run_agent_turn(TopicPid, WsPid, 0)
                            catch
                                exit:interrupt ->
                                    #{type => response, message => #{content => <<"">>}};
                                Class:Reason2:Stacktrace ->
                                    error_logger:error_msg("Agent error ~p:~p Stacktrace: ~p~n", [Class, Reason2, Stacktrace]),
                                    #{type => error, error => agent_crash,
                                      message => iolist_to_binary(
                                          [atom_to_binary(Class, utf8), ": ",
                                           io_lib:format("~p", [Reason2])])}
                            end,
                        WsPid ! {agent_response, Response}
                    end),
                    erlang:monitor(process, AgentRef),
                    {reply, ReopenMsg ++ [{text, jsx:encode(#{type => thinking, topic_id => CurrentTopicId})}],
                     State#{agent_ref => AgentRef}};
                {'EXIT', _} ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_died, message => humanize_error(topic_died)})}, State};
                {error, _} ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_died, message => humanize_error(topic_died)})}, State}
            end
    end.

handle_connect(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    case TopicId of
        undefined ->
            case start_new_topic(<<"general">>, <<"New conversation">>, undefined) of
                {ok, NewTopicId, TopicPid} ->
                    erlang:monitor(process, TopicPid),
                    safe_subscribe(TopicPid),
                    NewTopics = maps:put(NewTopicId, TopicPid, maps:get(topics, State, #{})),
                    case safe_get_history(TopicPid) of
                        {ok, {History, _}} ->
                            Reply = #{type => connected, topic_id => NewTopicId, history => History,
                                       title => <<"New conversation">>, channel_id => <<"general">>,
                                       permission_mode => current_permission_mode()},
                            {reply, {text, jsx:encode(Reply)},
                             State#{current_topic_id => NewTopicId, topics => NewTopics, heartbeat_sent => false}};
                        {error, _} ->
                            Reply = #{type => connected, topic_id => NewTopicId, history => [],
                                       title => <<"New conversation">>, channel_id => <<"general">>,
                                       permission_mode => current_permission_mode()},
                            {reply, {text, jsx:encode(Reply)},
                             State#{current_topic_id => NewTopicId, topics => NewTopics, heartbeat_sent => false}}
                    end;
                {error, Reason} ->
                    {reply, {text, jsx:encode(#{type => error, error => Reason, message => humanize_error(Reason)})}, State}
            end;
        _ ->
            case safe_resume(TopicId) of
                {ok, TopicPid} ->
                    erlang:monitor(process, TopicPid),
                    safe_subscribe(TopicPid),
                    NewTopics = maps:put(TopicId, TopicPid, maps:get(topics, State, #{})),
                    case safe_get_history(TopicPid) of
                        {ok, {History, TopicState}} ->
                            Reply = #{type => connected, topic_id => TopicId, history => History,
                                       title => maps:get(title, TopicState, <<"">>),
                                       channel_id => maps:get(channel_id, TopicState, <<"general">>),
                                       parent_id => maps:get(parent_id, TopicState, undefined),
                                       status => maps:get(status, TopicState, active),
                                       permission_mode => current_permission_mode()},
                            {reply, {text, jsx:encode(Reply)},
                             State#{current_topic_id => TopicId, topics => NewTopics, heartbeat_sent => false}};
                        {error, _} ->
                            {reply, {text, jsx:encode(#{type => error, error => topic_load_failed, message => humanize_error(topic_load_failed)})}, State}
                    end;
                {error, _} ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_not_found, message => humanize_error(topic_not_found)})}, State}
            end
    end.

handle_new_topic(Msg, State) ->
    ChannelId = maps:get(<<"channel_id">>, Msg, <<"general">>),
    Title = maps:get(<<"title">>, Msg, <<"Untitled">>),
    ParentId = maps:get(<<"parent_id">>, Msg, undefined),
    case start_new_topic(ChannelId, Title, ParentId) of
        {ok, TopicId, TopicPid} ->
            erlang:monitor(process, TopicPid),
            safe_subscribe(TopicPid),
            NewTopics = maps:put(TopicId, TopicPid, maps:get(topics, State, #{})),
            Reply = #{type => topic_created, topic_id => TopicId, title => Title,
                      channel_id => ChannelId, parent_id => ParentId},
            {reply, {text, jsx:encode(Reply)},
             State#{current_topic_id => TopicId, topics => NewTopics}};
        {error, Reason} ->
            {reply, {text, jsx:encode(#{type => error, error => Reason, message => humanize_error(Reason)})}, State}
    end.

handle_switch_topic(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    Topics = maps:get(topics, State, #{}),
    CurrentTopicId = maps:get(current_topic_id, State),
    case maps:get(TopicId, Topics, undefined) of
        undefined ->
            case safe_resume(TopicId) of
                {ok, TopicPid} ->
                    erlang:monitor(process, TopicPid),
                    safe_subscribe(TopicPid),
                    NewTopics = maps:put(TopicId, TopicPid, Topics),
                    case safe_get_history(TopicPid) of
                        {ok, {History, TopicState}} ->
                            Reply = #{type => topic_switched, topic_id => TopicId,
                                      history => History,
                                      title => maps:get(title, TopicState, <<"">>),
                                      channel_id => maps:get(channel_id, TopicState, <<"general">>),
                                      status => maps:get(status, TopicState, active)},
                            {reply, {text, jsx:encode(Reply)},
                             State#{current_topic_id => TopicId, topics => NewTopics}};
                        {error, _} ->
                            {reply, {text, jsx:encode(#{type => error, error => topic_load_failed, message => humanize_error(topic_load_failed)})}, State}
                    end;
                {error, _} ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_not_found, message => humanize_error(topic_not_found)})}, State}
            end;
        _TopicPid when CurrentTopicId =:= TopicId ->
            {reply, {text, jsx:encode(#{type => topic_switched, topic_id => TopicId, history => []})}, State};
        TopicPid ->
            case safe_get_history(TopicPid) of
                {ok, {History, TopicState2}} ->
                    Reply2 = #{type => topic_switched, topic_id => TopicId, history => History,
                               status => maps:get(status, TopicState2, active)},
                    {reply, {text, jsx:encode(Reply2)}, State#{current_topic_id => TopicId}};
                {error, _} ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_load_failed, message => humanize_error(topic_load_failed)})}, State}
            end
    end.

safe_subscribe(TopicPid) ->
    case catch openpixie_topic:subscribe(TopicPid, self()) of
        ok ->
            case openpixie_topic:get_pending_confirmation(TopicPid) of
                undefined -> ok;
                {ToolName, Args, Reason} ->
                    self() ! {tool_confirm_request, ToolName, Args, Reason}
            end,
            ok;
        _ -> ok
    end.

safe_resume(TopicId) ->
    case catch openpixie_topic:resume(TopicId) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {error, Reason} -> {error, Reason};
        {'EXIT', _} -> {error, exit};
        _ -> {error, unknown}
    end.

safe_get_history(TopicPid) ->
    case catch openpixie_topic:get_history(TopicPid) of
        {ok, History} ->
            case catch openpixie_topic:get_state(TopicPid) of
                #{title := _, channel_id := _} = TopicState -> {ok, {History, TopicState}};
                _ -> {ok, {History, #{title => <<"">>, channel_id => <<"general">>}}}
            end;
        _ -> {error, failed}
    end.

handle_list_topics(Msg, State) ->
    ChannelId = maps:get(<<"channel_id">>, Msg, undefined),
    RawTopics = case ChannelId of
        undefined -> openpixie_topic_store:list();
        _ -> openpixie_topic_store:list_by_channel(ChannelId)
    end,
    Formatted = lists:map(fun({Id, Pid, Status, ChId, Title}) ->
        Alive = is_pid(Pid) andalso is_process_alive(Pid),
        StatusBin = case is_atom(Status) of true -> atom_to_binary(Status, utf8); false -> Status end,
        #{id => Id, status => StatusBin, channel_id => ChId, title => Title, active => Alive}
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
            {reply, {text, jsx:encode(#{type => error, error => missing_topic_id, message => <<"No topic ID provided.">>})}, State};
        _ ->
            Topics = maps:get(topics, State, #{}),
            case find_topic_pid(TopicId, Topics) of
                undefined ->
                    {reply, {text, jsx:encode(#{type => error, error => topic_not_found, message => humanize_error(topic_not_found)})}, State};
                TopicPid ->
                    ok = openpixie_topic:resolve(TopicPid),
                    {reply, {text, jsx:encode(#{type => topic_resolved, topic_id => TopicId})}, State}
            end
    end.

handle_reopen_topic(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    case TopicId of
        undefined ->
            {reply, {text, jsx:encode(#{type => error, error => missing_topic_id, message => <<"No topic ID provided.">>})}, State};
        _ ->
            Topics = maps:get(topics, State, #{}),
            case find_topic_pid(TopicId, Topics) of
                undefined ->
                    case safe_resume(TopicId) of
                        {ok, TopicPid} ->
                            ok = openpixie_topic:reopen(TopicPid),
                            NewTopics = maps:put(TopicId, TopicPid, Topics),
                            {reply, {text, jsx:encode(#{type => topic_reopened, topic_id => TopicId})},
                             State#{topics => NewTopics}};
                        {error, _} ->
                            {reply, {text, jsx:encode(#{type => error, error => topic_not_found, message => humanize_error(topic_not_found)})}, State}
                    end;
                TopicPid ->
                    ok = openpixie_topic:reopen(TopicPid),
                    {reply, {text, jsx:encode(#{type => topic_reopened, topic_id => TopicId})}, State}
            end
    end.

handle_delete_topic(Msg, State) ->
    TopicId = maps:get(<<"topic_id">>, Msg, undefined),
    case TopicId of
        undefined ->
            {reply, {text, jsx:encode(#{type => error, error => missing_topic_id, message => <<"No topic ID provided.">>})}, State};
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
                {ToolName, _Args, AgentPid} when is_pid(AgentPid) ->
                    AgentPid ! {tool_confirm_reply, approved},
                    CurrentTopicId = maps:get(current_topic_id, State, undefined),
                    Topics = maps:get(topics, State, #{}),
                    TopicPid = maps:get(CurrentTopicId, Topics, undefined),
                    case TopicPid of
                        undefined -> ok;
                        _ -> openpixie_topic:clear_pending_confirmation(TopicPid)
                    end,
                    {reply, {text, jsx:encode(#{type => tool_approved, tool => ToolName})},
                     maps:remove(pending_confirmation, State)};
                undefined ->
                    {reply, {text, jsx:encode(#{type => error, message => <<"No pending confirmation">>})}, State}
            end;
        false ->
            Pending2 = maps:get(pending_confirmation, State, undefined),
            case Pending2 of
                {ToolName, _Args, AgentPid} when is_pid(AgentPid) ->
                    AgentPid ! {tool_confirm_reply, denied},
                    CurrentTopicId = maps:get(current_topic_id, State, undefined),
                    Topics = maps:get(topics, State, #{}),
                    TopicPid = maps:get(CurrentTopicId, Topics, undefined),
                    case TopicPid of
                        undefined -> ok;
                        _ -> openpixie_topic:clear_pending_confirmation(TopicPid)
                    end,
                    {reply, {text, jsx:encode(#{type => tool_rejected, tool => ToolName})},
                     maps:remove(pending_confirmation, State)};
                undefined ->
                    {reply, {text, jsx:encode(#{type => error, message => <<"No pending confirmation">>})}, State}
            end
    end.

handle_ask_user_response(Msg, State) ->
    Response = maps:get(<<"response">>, Msg, maps:get(<<"answer">>, Msg, <<"">>)),
    % Forward the response to the agent process that is waiting
    case maps:get(agent_ref, State, undefined) of
        AgentPid when is_pid(AgentPid) ->
            AgentPid ! {ask_user_reply, Response},
            {reply, {text, jsx:encode(#{type => ask_user_received})}, State};
        undefined ->
            {reply, {text, jsx:encode(#{type => error, message => <<"No active agent">>})}, State}
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

run_agent_turn(TopicPid, WsPid, _Depth) ->
    agent_loop(TopicPid, WsPid, 0, []).

agent_loop(TopicPid, WsPid, Iteration, _LastToolCalls) when Iteration >= 200 ->
    #{type => error, error => max_iterations, message => humanize_error(max_iterations)};
agent_loop(TopicPid, WsPid, Iteration, LastToolCalls) ->
    {ok, History0} = openpixie_topic:get_history(TopicPid),
    History = case detect_tool_loop(LastToolCalls) of
        true ->
            LoopWarn = #{role => user, content => <<
                "You appear to be stuck in a loop calling the same tool repeatedly with similar or empty results. "
                "Stop repeating the same approach. Try a different strategy, use a different tool, or conclude if you have enough information.">>},
            History0 ++ [LoopWarn];
        false ->
            History0
    end,
    SystemPrompt = openpixie_context:build_system_prompt(),
    Model = openpixie_config:ollama_model(),
    Tools = openpixie_tools:tool_schema(),
    MaxTokens = openpixie_config:max_context_tokens(),
    TrimmedHistory = openpixie_context:trim_messages(History, MaxTokens),
    Messages = [#{role => system, content => SystemPrompt} | TrimmedHistory],
    StreamResult = llm_stream_with_retry(Model, Messages, Tools, WsPid, ?MAX_LLM_RETRIES),
    case StreamResult of
        {ok, _RespMsg, FullContent, ToolCallsAcc} when is_list(ToolCallsAcc), length(ToolCallsAcc) > 0 ->
            WsPid ! stream_done,
            NonStreamResult = llm_call_with_retry(fun() ->
                {ok, acquired} = openpixie_semaphore:acquire(),
                try openpixie_ollama:chat_with_tools(Model, Messages, Tools)
                after openpixie_semaphore:release()
                end
            end, ?MAX_LLM_RETRIES, WsPid),
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
                            agent_loop(TopicPid, WsPid, Iteration + 1, NSToolCalls)
                    end;
                {error, Reason} ->
                    agent_error(Reason, WsPid)
            end;
        {ok, _RespMsg, FullContent, _ToolCalls} ->
            WsPid ! stream_done,
            FinalMsg = #{role => assistant, content => FullContent},
            {ok, _} = openpixie_topic:send_message(TopicPid, FinalMsg),
            #{type => response, message => #{content => FullContent}};
        {error, Reason} ->
            agent_error(Reason, WsPid)
    end.

agent_error(Reason, _WsPid) ->
    HumanMsg = humanize_error(Reason),
    #{type => error, error => HumanMsg, raw_error => Reason, message => HumanMsg}.

detect_tool_loop([]) -> false;
detect_tool_loop(ToolCalls) when length(ToolCalls) < 3 -> false;
detect_tool_loop(ToolCalls) ->
    Recent = lists:sublist(ToolCalls, 5),
    Names = [case maps:get(<<"function">>, TC, #{}) of
        #{<<"name">> := N} -> N;
        _ -> undefined
    end || TC <- Recent],
    Defined = [N || N <- Names, N =/= undefined],
    case Defined of
        [] -> false;
        [H | _] ->
            SameCount = length([N || N <- Defined, N =:= H]),
            SameCount >= 3
    end.

humanize_error(circuit_open) -> <<"The AI service is temporarily unavailable. Retrying...">>;
humanize_error(timeout) -> <<"The AI service took too long to respond. Please try again.">>;
humanize_error(econnrefused) -> <<"Cannot connect to the AI service. Is Ollama running?">>;
humanize_error({closed, _}) -> <<"Connection to the AI service was lost.">>;
humanize_error({status, 429, _}) -> <<"The AI service is rate-limiting requests. Please wait a moment.">>;
humanize_error({status, 500, _}) -> <<"The AI service encountered an internal error.">>;
humanize_error({status, 503, _}) -> <<"The AI service is currently unavailable.">>;
humanize_error(max_iterations) -> <<"The agent reached the maximum number of steps. Try continuing the conversation.">>;
humanize_error(agent_crash) -> <<"The agent process crashed unexpectedly.">>;
humanize_error(no_active_topic) -> <<"No active conversation. Please create or select a topic.">>;
humanize_error(topic_died) -> <<"This conversation is no longer active.">>;
humanize_error(topic_not_found) -> <<"Conversation not found. It may have been deleted.">>;
humanize_error(topic_load_failed) -> <<"Could not load this conversation.">>;
humanize_error(nxdomain) -> <<"Cannot resolve the AI service hostname. Check your OLLAMA_HOST setting.">>;
humanize_error({nxdomain, _}) -> <<"Cannot resolve the AI service hostname. Check your OLLAMA_HOST setting.">>;
humanize_error(badarg) -> <<"An internal error occurred. The agent encountered invalid data.">>;
humanize_error(confirmation_denied) -> <<"Tool execution was denied by the user.">>;
humanize_error(confirmation_timeout) -> <<"Tool execution timed out waiting for user approval.">>;
humanize_error({badarg, _}) -> <<"An internal error occurred. The agent encountered invalid data.">>;
humanize_error({status, Code, _}) when is_integer(Code) ->
    iolist_to_binary(["The AI service returned an unexpected error (", integer_to_binary(Code), ")."]);
humanize_error({error, Reason}) -> humanize_error(Reason);
humanize_error(Other) when is_atom(Other) ->
    iolist_to_binary(["Error: ", atom_to_binary(Other, utf8)]);
humanize_error(_Other) ->
    <<"An unexpected error occurred.">>.

llm_stream_with_retry(Model, Messages, Tools, WsPid, RetriesLeft) ->
    {ok, acquired} = openpixie_semaphore:acquire(),
    StreamStartedRef = make_ref(),
    StreamCallback = fun(ContentChunk) ->
        put(StreamStartedRef, true),
        WsPid ! {stream_chunk, ContentChunk}
    end,
    Result = try
        openpixie_ollama:stream_chat_with_tools(Model, Messages, Tools, StreamCallback)
    after
        openpixie_semaphore:release()
    end,
    case is_transient_error(Result) andalso get(StreamStartedRef) =/= true of
        true ->
            maybe_retry_stream(Model, Messages, Tools, WsPid, RetriesLeft, Result);
        false ->
            Result
    end.

maybe_retry_stream(_Model, _Messages, _Tools, _WsPid, RetriesLeft, Result) when RetriesLeft =< 0 ->
    Result;
maybe_retry_stream(Model, Messages, Tools, WsPid, RetriesLeft, {error, Reason}) ->
    openpixie_circuit_breaker:reset(),
    Delay = ?RETRY_BASE_MS * round(math:pow(2, ?MAX_LLM_RETRIES - RetriesLeft)),
    ReasonBin = format_error_reason(Reason),
    WsPid ! {stream_chunk, <<" ⏳ Retrying (", ReasonBin/binary, ")... ">>},
    timer:sleep(Delay),
    llm_stream_with_retry(Model, Messages, Tools, WsPid, RetriesLeft - 1).

is_transient_error({error, circuit_open}) -> true;
is_transient_error({error, timeout}) -> true;
is_transient_error({error, stream_timeout}) -> true;
is_transient_error({error, {status, 429, _}}) -> true;
is_transient_error({error, {status, 503, _}}) -> true;
is_transient_error({error, {status, 500, _}}) -> true;
is_transient_error({error, econnrefused}) -> true;
is_transient_error({error, {closed, _}}) -> true;
is_transient_error(_) -> false.

format_error_reason(circuit_open) -> <<"service overloaded">>;
format_error_reason(timeout) -> <<"request timed out">>;
format_error_reason(econnrefused) -> <<"connection refused">>;
format_error_reason({closed, _}) -> <<"connection lost">>;
format_error_reason({status, 429, _}) -> <<"rate limited">>;
format_error_reason({status, 500, _}) -> <<"server error">>;
format_error_reason({status, 503, _}) -> <<"service unavailable">>;
format_error_reason(nxdomain) -> <<"DNS lookup failed">>;
format_error_reason({nxdomain, _}) -> <<"DNS lookup failed">>;
format_error_reason({status, Code, _}) -> integer_to_binary(Code);
format_error_reason(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

llm_call_with_retry(Fun, RetriesLeft, WsPid) when RetriesLeft =< 0 ->
    case catch Fun() of
        {ok, _} = R -> R;
        {error, _} = E -> E;
        {'EXIT', _} -> {error, process_exit}
    end;
llm_call_with_retry(Fun, RetriesLeft, WsPid) ->
    Result = case catch Fun() of
        {ok, _} = R -> R;
        {error, _} = E -> E;
        {'EXIT', _} -> {error, process_exit}
    end,
    case is_transient_error(Result) of
        true ->
            openpixie_circuit_breaker:reset(),
            Delay = ?RETRY_BASE_MS * round(math:pow(2, ?MAX_LLM_RETRIES - RetriesLeft)),
            ReasonBin = format_error_reason(case Result of {error, Reason} -> Reason; _ -> Result end),
            WsPid ! {stream_chunk, <<" ⏳ Retrying (", ReasonBin/binary, ")... ">>},
            timer:sleep(Delay),
            llm_call_with_retry(Fun, RetriesLeft - 1, WsPid);
        false ->
            Result
    end.

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
        Result = case openpixie_guardian:is_guardian_relevant(Name, Args) of
            true ->
                WsPid ! {guardian_check, Name, Args},
                R1 = openpixie_tools:execute(Name, Args),
                WsPid ! {guardian_result, Name, R1},
                maybe_dashboard_refresh(Name, Args, R1, WsPid),
                R1;
            false ->
                R2 = openpixie_tools:execute(Name, Args),
                maybe_dashboard_refresh(Name, Args, R2, WsPid),
                R2
        end,
        case maps:get(error, Result, undefined) of
            requires_confirmation ->
                Reason = maps:get(reason, Result, unknown),
                TopicPid = get(topic_pid),
                case TopicPid of
                    undefined -> ok;
                    _ -> openpixie_topic:set_pending_confirmation(TopicPid, Name, Args, Reason)
                end,
                WsPid ! {tool_confirm_request, Name, Args, Reason},
                receive
                    {tool_confirm_reply, approved} ->
                        case get(topic_pid) of
                            undefined -> ok;
                            _ -> openpixie_topic:clear_pending_confirmation(get(topic_pid))
                        end,
                        ApprovedResult = openpixie_tools:execute(Name, Args, #{confirmation => approved}),
                        WsPid ! {tool_step, #{tool => Name, args => Args, status => approved}},
                        SafeResult = json_safe(ApprovedResult),
                        Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                        ToolMsg = #{role => tool, content => Encoded, name => Name, args => Args},
                        ToolMsg2 = case CallId of
                            undefined -> ToolMsg;
                            Id -> ToolMsg#{<<"tool-call-id">> => Id}
                        end,
                        {true, ToolMsg2};
                    {tool_confirm_reply, denied} ->
                        case get(topic_pid) of
                            undefined -> ok;
                            _ -> openpixie_topic:clear_pending_confirmation(get(topic_pid))
                        end,
                        WsPid ! {tool_step, #{tool => Name, args => Args, status => denied}},
                        DeniedResult = #{success => false, error => confirmation_denied, tool => Name},
                        SafeResult = json_safe(DeniedResult),
                        Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                        ToolMsg = #{role => tool, content => Encoded, name => Name, args => Args},
                        ToolMsg2 = case CallId of
                            undefined -> ToolMsg;
                            Id -> ToolMsg#{<<"tool-call-id">> => Id}
                        end,
                        {true, ToolMsg2}
                end;
            requires_user_input ->
                Question = maps:get(question, Result, <<"">>),
                Context = maps:get(context, Result, <<"">>),
                WsPid ! {ask_user_request, Name, Question, Context},
                receive
                    {ask_user_reply, Response} ->
                        UserResult = #{success => true, answer => Response},
                        WsPid ! {tool_step, #{tool => Name, args => Args, status => done}},
                        SafeResult = json_safe(UserResult),
                        Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                        ToolMsg = #{role => tool, content => Encoded, name => Name, args => Args},
                        ToolMsg2 = case CallId of
                            undefined -> ToolMsg;
                            Id -> ToolMsg#{<<"tool-call-id">> => Id}
                        end,
                        {true, ToolMsg2}
                end;
            _ ->
                WsPid ! {tool_step, #{tool => Name, args => Args, status => done}},
                SafeResult = json_safe(Result),
                Encoded = iolist_to_binary(jsx:encode(SafeResult)),
                ToolMsg = #{role => tool, content => Encoded, name => Name, args => Args},
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

current_permission_mode() ->
    case openpixie_permissions:get_mode() of
        trust -> <<"trust">>;
        auto_noselfmod -> <<"auto_noselfmod">>;
        sandbox -> <<"sandbox">>;
        plan -> <<"plan">>;
        ask -> <<"ask">>
    end.

maybe_dashboard_refresh(ToolName, Args, Result, WsPid) ->
    case maps:get(success, Result, false) of
        true when ToolName =:= <<"edit_file">>; ToolName =:= <<"write_file">> ->
            Path = maps:get(<<"path">>, Args, <<"">>),
            case is_dashboard_path(Path) of
                true -> WsPid ! {dashboard_refresh_hint};
                false -> ok
            end;
        true when ToolName =:= <<"compile_and_reload">> ->
            File = maps:get(<<"file">>, Args, <<"">>),
            case is_dashboard_path(File) of
                true -> WsPid ! {dashboard_refresh_hint};
                false -> ok
            end;
        _ -> ok
    end.

is_dashboard_path(Path) ->
    Lower = string:lowercase(binary_to_list(Path)),
    lists:suffix("priv/dashboard/index.html", Lower) orelse
    lists:suffix("index.html", Lower) andalso
        string:find(Lower, "dashboard") =/= nomatch.