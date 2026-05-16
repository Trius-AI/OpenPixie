-module(openpixie_agent).
-export([start/2, start_standalone/1, start_standalone/2]).

start(TopicPid, WsPid) ->
    AgentRef = spawn(fun() ->
        put(topic_pid, TopicPid),
        openpixie_ws:run_agent_turn(TopicPid, WsPid, 0)
    end),
    erlang:monitor(process, AgentRef),
    AgentRef.

start_standalone(TopicId) ->
    start_standalone(TopicId, undefined).

start_standalone(TopicId, PromptContent) ->
    case openpixie_topic_store:lookup_pid(TopicId) of
        {ok, Pid} when is_pid(Pid) ->
            do_start_standalone(Pid, TopicId, PromptContent);
        {error, not_found} ->
            {error, topic_not_found}
    end.

do_start_standalone(TopicPid, TopicId, PromptContent) ->
    case PromptContent of
        undefined -> ok;
        _ ->
            Msg = #{role => user, content => PromptContent},
            {ok, _} = openpixie_topic:send_message(TopicPid, Msg),
            openpixie_topic:broadcast(TopicPid, #{
                type => message,
                topic_id => TopicId,
                data => Msg
            })
    end,
    ProxyPid = spawn_proxy(TopicPid, TopicId),
    spawn(fun() ->
        put(topic_pid, TopicPid),
        put(triggered_by, schedule),
        put(self_improve_used, false),
        put(standalone_proxy, ProxyPid),
        try
            openpixie_ws:run_agent_turn(TopicPid, ProxyPid, 0)
        catch
            Class:Reason:Stacktrace ->
                error_logger:error_msg("Standalone agent error ~p:~p Stacktrace: ~p~n",
                    [Class, Reason, Stacktrace])
        after
            ProxyPid ! stop
        end
    end),
    ok.

spawn_proxy(TopicPid, TopicId) ->
    spawn(fun() -> proxy_loop(TopicPid, TopicId) end).

proxy_loop(TopicPid, TopicId) ->
    receive
        stop -> ok;
        {stream_chunk, Content} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => stream_chunk,
                topic_id => TopicId,
                content => Content
            }),
            proxy_loop(TopicPid, TopicId);
        stream_done ->
            openpixie_topic:broadcast(TopicPid, #{
                type => stream_done,
                topic_id => TopicId
            }),
            proxy_loop(TopicPid, TopicId);
        {text, Data} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => data,
                topic_id => TopicId,
                data => Data
            }),
            proxy_loop(TopicPid, TopicId);
        thinking ->
            openpixie_topic:broadcast(TopicPid, #{
                type => thinking,
                topic_id => TopicId
            }),
            proxy_loop(TopicPid, TopicId);
        {tool_step, Info} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => tool_step,
                topic_id => TopicId,
                data => Info
            }),
            proxy_loop(TopicPid, TopicId);
        {guardian_check, Name, Args} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => guardian_check,
                topic_id => TopicId,
                tool => Name,
                args => Args
            }),
            proxy_loop(TopicPid, TopicId);
        {guardian_result, Name, Result, Status} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => guardian_result,
                topic_id => TopicId,
                tool => Name,
                result => Result,
                status => Status
            }),
            proxy_loop(TopicPid, TopicId);
        {tool_confirm_request, Name, Args, Reason} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => tool_confirm_request,
                topic_id => TopicId,
                tool => Name,
                args => Args,
                reason => Reason
            }),
            proxy_loop(TopicPid, TopicId);
        {ask_user_request, Name, Question, Context} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => ask_user_request,
                topic_id => TopicId,
                tool => Name,
                question => Question,
                context => Context
            }),
            proxy_loop(TopicPid, TopicId);
        {dashboard_refresh_hint} ->
            proxy_loop(TopicPid, TopicId);
        _ ->
            proxy_loop(TopicPid, TopicId)
    end.