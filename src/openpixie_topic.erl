-module(openpixie_topic).
-behaviour(gen_server).

-export([start_link/1, send_message/2, get_history/1, get_state/1, get_id/1,
         subscribe/2, unsubscribe/2, resolve/1, fork/3, broadcast/2,
         resume/1, stop_topic/1, idle_check/1, set_fork/4, delete_topic/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(IDLE_CHECK_INTERVAL, 60000).

-record(state, {
    id :: binary(),
    channel_id = <<"general">> :: binary(),
    parent_id = undefined :: binary() | undefined,
    title = <<"Untitled">> :: binary(),
    messages = [] :: list(),
    model :: binary(),
    created_at :: integer(),
    last_activity :: integer(),
    status = active :: active | idle | resolved | archived,
    subscribers = [] :: list(pid()),
    token_count = 0 :: integer(),
    topic_dir :: string()
}).

start_link(TopicId) ->
    gen_server:start_link(?MODULE, [TopicId], []).

init([TopicId]) ->
    Dir = openpixie_config:topics_dir(),
    TopicDir = filename:join(Dir, binary_to_list(TopicId)),
    ok = filelib:ensure_dir(filename:join(TopicDir, "dummy")),
    Model = openpixie_config:ollama_model(),
    Now = erlang:system_time(millisecond),
    CtxPath = filename:join(TopicDir, "context.json"),
    BaseState = #state{id = TopicId, model = Model, created_at = Now,
                       last_activity = Now, topic_dir = TopicDir},
    State = case file:read_file(CtxPath) of
        {ok, CtxBin} ->
            try jsx:decode(CtxBin, [return_maps]) of
                Ctx ->
                    BaseState#state{
                        channel_id = maps:get(<<"channel_id">>, Ctx, <<"general">>),
                        parent_id = maps:get(<<"parent_id">>, Ctx, undefined),
                        title = maps:get(<<"title">>, Ctx, <<"Untitled">>),
                        created_at = maps:get(<<"created_at">>, Ctx, Now),
                        last_activity = maps:get(<<"last_activity">>, Ctx, Now),
                        token_count = maps:get(<<"token_count">>, Ctx, 0)
                    }
            catch _:_ -> BaseState
            end;
        {error, enoent} -> BaseState
    end,
    Messages = load_journal(TopicDir),
    timer:send_interval(?IDLE_CHECK_INTERVAL, idle_check),
    openpixie_topic_store:reenable(TopicId, self()),
    {ok, State#state{messages = Messages, status = active}}.

send_message(TopicPid, Message) ->
    gen_server:call(TopicPid, {send_message, Message}, 300000).

get_history(TopicPid) ->
    gen_server:call(TopicPid, get_history).

get_state(TopicPid) ->
    gen_server:call(TopicPid, get_state).

get_id(TopicPid) ->
    gen_server:call(TopicPid, get_id).

subscribe(TopicPid, WsPid) ->
    gen_server:call(TopicPid, {subscribe, WsPid}).

unsubscribe(TopicPid, WsPid) ->
    gen_server:cast(TopicPid, {unsubscribe, WsPid}).

resolve(TopicPid) ->
    gen_server:call(TopicPid, resolve).

fork(TopicPid, Title, ChannelId) ->
    gen_server:call(TopicPid, {fork, Title, ChannelId}).

broadcast(TopicPid, Data) ->
    gen_server:cast(TopicPid, {broadcast, Data}).

stop_topic(TopicPid) ->
    gen_server:call(TopicPid, stop).

delete_topic(TopicId) ->
    case openpixie_topic_store:lookup_pid(TopicId) of
        {ok, Pid} when is_pid(Pid) ->
            gen_server:call(Pid, delete);
        _ ->
            do_delete_topic(TopicId)
    end.

idle_check(TopicPid) ->
    gen_server:cast(TopicPid, idle_check).

set_fork(ChildPid, Title, ChannelId, ParentId) ->
    gen_server:call(ChildPid, {set_fork, Title, ChannelId, ParentId}).

resume(TopicId) ->
    case openpixie_topic_store:lookup(TopicId) of
        {ok, {Pid, _Status}} when is_pid(Pid) ->
            {ok, Pid};
        {ok, {undefined, _Status}} ->
            {ok, _TopicId, Pid} = openpixie_topic_sup:start_topic(TopicId),
            {ok, Pid};
        {error, not_found} ->
            {error, not_found}
    end.

handle_call({send_message, Message}, _From, State) ->
    NewMessages = State#state.messages ++ [Message],
    Now = erlang:system_time(millisecond),
    NewState = State#state{messages = NewMessages, last_activity = Now, status = active},
    append_to_journal(NewState, Message),
    TokenCount = openpixie_ollama:count_tokens(NewMessages),
    NewState2 = NewState#state{token_count = TokenCount},
    save_context(NewState2),
    {reply, {ok, NewMessages}, NewState2};

handle_call(get_history, _From, State) ->
    {reply, {ok, State#state.messages}, State};

handle_call(get_state, _From, State) ->
    {reply, #{
        id => State#state.id,
        channel_id => State#state.channel_id,
        parent_id => State#state.parent_id,
        title => State#state.title,
        model => State#state.model,
        status => State#state.status,
        token_count => State#state.token_count,
        last_activity => State#state.last_activity,
        subscriber_count => length(State#state.subscribers)
    }, State};

handle_call(get_id, _From, State) ->
    {reply, State#state.id, State};

handle_call({subscribe, WsPid}, _From, State) ->
    case lists:member(WsPid, State#state.subscribers) of
        true -> {reply, ok, State};
        false ->
            erlang:monitor(process, WsPid),
            NewSubs = [WsPid | State#state.subscribers],
            {reply, ok, State#state{subscribers = NewSubs, status = active}}
    end;

handle_call(resolve, _From, State) ->
    NewState = State#state{status = resolved},
    save_context(NewState),
    openpixie_topic_store:set_status(State#state.id, resolved),
    {reply, ok, NewState};

handle_call({fork, Title, ChannelId}, _From, State) ->
    {ok, ChildId} = openpixie_topic_sup:start_topic(),
    {ok, ChildPid} = openpixie_topic_store:lookup_pid(ChildId),
    ok = set_fork(ChildPid, Title, ChannelId, State#state.id),
    {reply, {ok, ChildId}, State};

handle_call({set_fork, Title, ChannelId, ParentId}, _From, State) ->
    NewState = State#state{title = Title, channel_id = ChannelId, parent_id = ParentId},
    save_context(NewState),
    openpixie_topic_store:update(State#state.id, ChannelId, Title),
    {reply, ok, NewState};

handle_call(stop, _From, State) ->
    save_context(State),
    openpixie_topic_store:set_pid(State#state.id, undefined),
    openpixie_topic_store:set_status(State#state.id, idle),
    {stop, normal, ok, State};

handle_call(delete, _From, State) ->
    TopicId = State#state.id,
    lists:foreach(fun(Pid) -> catch erlang:demonitor(Pid) end, State#state.subscribers),
    do_delete_topic(TopicId),
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({unsubscribe, WsPid}, State) ->
    NewSubs = lists:delete(WsPid, State#state.subscribers),
    {noreply, State#state{subscribers = NewSubs}};

handle_cast({broadcast, Data}, State) ->
    broadcast_to_subscribers(State#state.subscribers, Data),
    {noreply, State};

handle_cast(idle_check, State) ->
    {noreply, maybe_evict(State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(idle_check, State) ->
    {noreply, maybe_evict(State)};

handle_info({'DOWN', _Ref, process, WsPid, _Reason}, State) ->
    NewSubs = lists:delete(WsPid, State#state.subscribers),
    {noreply, State#state{subscribers = NewSubs}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    save_context(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

maybe_evict(State) ->
    Now = erlang:system_time(millisecond),
    IdleMs = Now - State#state.last_activity,
    EvictMs = openpixie_config:idle_evict_minutes() * 60000,
    case State#state.subscribers of
        [] when IdleMs > EvictMs ->
            save_context(State),
            openpixie_topic_store:set_pid(State#state.id, undefined),
            openpixie_topic_store:set_status(State#state.id, idle),
            erlang:send(self(), stop),
            State;
        [] ->
            IdleTimeoutMs = openpixie_config:idle_timeout_minutes() * 60000,
            case IdleMs > IdleTimeoutMs of
                true -> State#state{status = idle};
                false -> State
            end;
        _ ->
            State#state{status = active}
    end.

append_to_journal(State, Message) ->
    JournalPath = filename:join(State#state.topic_dir, "conversation.jsonl"),
    Encoded = iolist_to_binary(jsx:encode(Message)),
    Line = <<Encoded/binary, "\n">>,
    file:write_file(JournalPath, Line, [append]).

save_context(State) ->
    ContextPath = filename:join(State#state.topic_dir, "context.json"),
    Context = #{
        id => State#state.id,
        channel_id => State#state.channel_id,
        parent_id => State#state.parent_id,
        title => State#state.title,
        model => State#state.model,
        created_at => State#state.created_at,
        last_activity => State#state.last_activity,
        status => atom_to_binary(State#state.status, utf8),
        token_count => State#state.token_count
    },
    file:write_file(ContextPath, iolist_to_binary(jsx:encode(Context))).

load_journal(TopicDir) ->
    JournalPath = filename:join(TopicDir, "conversation.jsonl"),
    case file:read_file(JournalPath) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            lists:filtermap(fun(Line) ->
                case Line of
                    <<>> -> false;
                    _ ->
                        try jsx:decode(Line, [return_maps]) of
                            Msg -> {true, Msg}
                        catch _:_ -> false
                        end
                end
            end, Lines);
        {error, _} -> []
    end.

broadcast_to_subscribers([], _Data) -> ok;
broadcast_to_subscribers(Subscribers, Data) ->
    lists:foreach(fun(Pid) ->
        Pid ! {topic_message, Data}
    end, Subscribers).

do_delete_topic(TopicId) ->
    openpixie_topic_store:delete(TopicId),
    Dir = filename:join(openpixie_config:topics_dir(), binary_to_list(TopicId)),
    del_dir(Dir).

del_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(fun(E) ->
                Path = filename:join(Dir, E),
                case filelib:is_dir(Path) of true -> del_dir(Path); false -> file:delete(Path) end
            end, Entries),
            file:del_dir(Dir);
        {error, _} -> ok
    end.