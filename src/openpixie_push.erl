-module(openpixie_push).
-export([notify/2, notify/3, notify/4, prompt/2, prompt/3]).

notify(TopicId, Content) ->
    notify(TopicId, Content, <<"assistant">>, undefined).

notify(TopicId, Content, Role) ->
    notify(TopicId, Content, Role, undefined).

notify(TopicId, Content, Role, Name) when is_binary(TopicId), is_binary(Content) ->
    case openpixie_topic_store:lookup_pid(TopicId) of
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
        {error, not_found} ->
            {error, topic_not_found}
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