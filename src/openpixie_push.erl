-module(openpixie_push).
-export([notify/2, notify/3, notify/4, prompt/2, prompt/3]).

notify(TopicId, Content) ->
    notify(TopicId, Content, <<"assistant">>, undefined).

notify(TopicId, Content, Role) ->
    notify(TopicId, Content, Role, undefined).

notify(TopicId, Content, Role, Name) when is_binary(TopicId), is_binary(Content) ->
    case ensure_topic_and_get_pid(TopicId) of
        {ok, Pid} when is_pid(Pid) ->
            Msg0 = #{role => Role, content => Content},
            Msg1 = case Name of
                undefined -> Msg0;
                N when is_binary(N) -> Msg0#{name => N}
            end,
            {ok, _} = openpixie_topic:send_message(Pid, Msg1),
            BroadcastMsg = Msg1#{
                type => message,
                topic_id => TopicId,
                data => Msg1
            },
            openpixie_topic:broadcast(Pid, BroadcastMsg),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% Ensure topic exists and get its PID. If topic doesn't exist in ETS but exists on disk,
%% restore it and start the process. This is needed for scheduled jobs that report to
%% inactive topics.
ensure_topic_and_get_pid(TopicId) ->
    case openpixie_topic_store:lookup_pid(TopicId) of
        {ok, Pid} when is_pid(Pid) ->
            {ok, Pid};
        {error, not_found} ->
            %% Topic not in ETS, check if it exists on disk and restore
            TopicsDir = openpixie_config:topics_dir(),
            TopicDir = filename:join(TopicsDir, binary_to_list(TopicId)),
            case filelib:is_dir(TopicDir) of
                true ->
                    %% Topic exists on disk, manually restore to ETS
                    CtxPath = filename:join(TopicDir, "context.json"),
                    case file:read_file(CtxPath) of
                        {ok, CtxBin} ->
                            try jsx:decode(CtxBin, [return_maps]) of
                                Ctx ->
                                    Id = maps:get(<<"id">>, Ctx, TopicId),
                                    ChannelId = maps:get(<<"channel_id">>, Ctx, <<"general">>),
                                    Title = maps:get(<<"title">>, Ctx, <<"Untitled">>),
                                    ets:insert(openpixie_topics, {Id, undefined, active, ChannelId, Title}),
                                    %% Now try to get PID again (will start the process)
                                    openpixie_topic_store:lookup_pid(TopicId)
                            catch _:_ ->
                                {error, invalid_context}
                            end;
                        _ ->
                            {error, context_not_found}
                    end;
                false ->
                    {error, topic_not_found}
            end
    end.

prompt(TopicId, PromptContent) ->
    prompt(TopicId, PromptContent, undefined).

prompt(TopicId, PromptContent, _Name) when is_binary(TopicId), is_binary(PromptContent) ->
    case openpixie_topic_sup:start_topic() of
        {ok, WorkTopicId, WorkTopicPid} ->
            Ts = erlang:system_time(millisecond),
            ShortTs = integer_to_binary(Ts rem 1000000, 36),
            WorkTitle = <<"Self-improve ", ShortTs/binary>>,
            ok = openpixie_topic:set_title(WorkTopicPid, WorkTitle),
            openpixie_topic_store:update(WorkTopicId, <<"system">>, WorkTitle),
            openpixie_agent:start_standalone(WorkTopicId, PromptContent, TopicId),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.