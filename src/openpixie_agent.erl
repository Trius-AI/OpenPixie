-module(openpixie_agent).
-export([start/2, start_standalone/1, start_standalone/2, start_standalone/3]).

-define(STANDALONE_TIMEOUT_MS, 2700000). % 45 minutes max for standalone agents

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
    start_standalone(TopicId, PromptContent, undefined).

start_standalone(TopicId, PromptContent, ReportTopicId) when is_binary(TopicId) ->
    case openpixie_topic_store:lookup_pid(TopicId) of
        {ok, Pid} when is_pid(Pid) ->
            do_start_standalone(Pid, TopicId, PromptContent, ReportTopicId);
        {error, not_found} ->
            {error, topic_not_found}
    end.

do_start_standalone(TopicPid, TopicId, PromptContent, ReportTopicId) ->
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
    TimeoutMs = ?STANDALONE_TIMEOUT_MS,
    {AgentPid, AgentMonitor} = spawn_monitor(fun() ->
        put(topic_pid, TopicPid),
        put(triggered_by, schedule),
        put(self_improve_used, false),
        put(standalone_proxy, ProxyPid),
        put(start_time, erlang:system_time(millisecond)),
        try
            openpixie_ws:run_agent_turn(TopicPid, ProxyPid, 0)
        catch
            Class:Reason:Stacktrace ->
                error_logger:error_msg("Standalone agent error ~p:~p Stacktrace: ~p~n",
                    [Class, Reason, Stacktrace]),
                {error, {Class, Reason}}
        after
            ProxyPid ! stop
        end
    end),
    %% Supervisor process: monitors the agent and ensures report is sent
    spawn(fun() ->
        receive
            {'DOWN', AgentMonitor, process, AgentPid, Result} ->
                ProxyPid ! stop,
                SelfImproveUsed = case get_agent_process_dict(AgentPid) of
                    #{self_improve_used := Val} -> Val;
                    _ -> false
                end,
                ReportResult = case Result of
                    normal -> report_success(TopicId, SelfImproveUsed);
                    {error, Err} -> report_error(TopicId, Err, SelfImproveUsed);
                    Other -> report_error(TopicId, Other, SelfImproveUsed)
                end,
                send_report(ReportTopicId, TopicId, ReportResult)
        after
            TimeoutMs ->
                error_logger:warning_msg("Standalone agent timeout after ~p ms, killing process~n", [TimeoutMs]),
                erlang:exit(AgentPid, timeout),
                ProxyPid ! stop,
                send_report(ReportTopicId, TopicId, {timeout, TimeoutMs})
        end
    end),
    ok.

%% @private Extract values from a terminated process's dictionary
get_agent_process_dict(Pid) ->
    case process_info(Pid, dictionary) of
        {dictionary, Dict} -> maps:from_list(Dict);
        _ -> #{}
    end.

%% @private Generate success report
report_success(TopicId, SelfImproveUsed) ->
    {success, SelfImproveUsed, TopicId}.

%% @private Generate error report
report_error(TopicId, Error, SelfImproveUsed) ->
    {error, Error, SelfImproveUsed, TopicId}.

%% @private Send the report to the report topic
send_report(undefined, _WorkTopicId, _Result) -> ok;
send_report(ReportTopicId, WorkTopicId, {success, SelfImproveUsed, _}) ->
    Msg = case SelfImproveUsed of
        true -> <<"\u2705 Self-improvement completed (topic: ", WorkTopicId/binary, ")">>;
        _ -> <<"\u26a0 Self-improvement run finished with no changes applied (topic: ", WorkTopicId/binary, ")">>
    end,
    case openpixie_push:notify(ReportTopicId, Msg, <<"system">>, <<"self_improve">>) of
        ok -> ok;
        {error, Reason} ->
            error_logger:warning_msg("Failed to send success report to ~p: ~p~n", [ReportTopicId, Reason])
    end;
send_report(ReportTopicId, WorkTopicId, {error, Error, SelfImproveUsed, _}) ->
    ErrorDesc = format_error_desc(Error),
    ChangeDesc = case SelfImproveUsed of
        true -> <<"made changes">>;
        _ -> <<"no changes">>
    end,
    Msg = <<"\u274c Self-improvement failed (topic: ", WorkTopicId/binary, ", ", ChangeDesc/binary, "): ", ErrorDesc/binary>>,
    case openpixie_push:notify(ReportTopicId, Msg, <<"system">>, <<"self_improve">>) of
        ok -> ok;
        {error, Reason} ->
            error_logger:warning_msg("Failed to send error report to ~p: ~p~n", [ReportTopicId, Reason])
    end;
send_report(ReportTopicId, WorkTopicId, {timeout, TimeoutMs}) ->
    Msg = <<"\u23f3 Self-improvement timed out after ", (integer_to_binary(TimeoutMs div 1000))/binary, " seconds (topic: ", WorkTopicId/binary, ")">>,
    case openpixie_push:notify(ReportTopicId, Msg, <<"system">>, <<"self_improve">>) of
        ok -> ok;
        {error, Reason} ->
            error_logger:warning_msg("Failed to send timeout report to ~p: ~p~n", [ReportTopicId, Reason])
    end.

%% @private Format error description for reporting
format_error_desc({Class, Reason}) ->
    BinClass = atom_to_binary(Class, utf8),
    BinReason = case Reason of
        _ when is_binary(Reason) -> Reason;
        _ when is_atom(Reason) -> atom_to_binary(Reason, utf8);
        _ -> iolist_to_binary(io_lib:format("~p", [Reason]))
    end,
    <<BinClass/binary, ": ", BinReason/binary>>;
format_error_desc(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_error_desc(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

report_result(_WorkTopicId, undefined, _) -> ok;
report_result(WorkTopicId, ReportTopicId, true) ->
    openpixie_push:notify(ReportTopicId,
        <<"\u2705 Self-improvement completed (topic: ", WorkTopicId/binary, ")">>,
        <<"system">>, <<"self_improve">>);
report_result(WorkTopicId, ReportTopicId, _) ->
    openpixie_push:notify(ReportTopicId,
        <<"\u26a0 Self-improvement run finished with no changes applied (topic: ", WorkTopicId/binary, ")">>,
        <<"system">>, <<"self_improve">>).

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
        {tool_step, #{tool := T, args := A, status := S}} ->
            openpixie_topic:broadcast(TopicPid, #{
                type => tool_step,
                topic_id => TopicId,
                tool => T,
                args => A,
                status => S
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