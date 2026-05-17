-module(openpixie_topic_store).
-behaviour(gen_server).

-export([start_link/0, register/2, lookup/1, lookup_pid/1, lookup_title/1, list/0,
          list_by_channel/1, set_status/2, set_pid/2, reenable/2,
          update/3, archive/1, archive_idle/0, delete/1,
          ensure_pid/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TOPICS_TABLE, openpixie_topics).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ets:new(?TOPICS_TABLE, [named_table, public, set]),
    ok = restore_from_disk(),
    {ok, #{}}.

restore_from_disk() ->
    TopicsDir = openpixie_config:topics_dir(),
    case file:list_dir(TopicsDir) of
        {ok, Entries} ->
            lists:foreach(fun(E) ->
                CtxPath = filename:join([TopicsDir, E, "context.json"]),
                case file:read_file(CtxPath) of
                    {ok, CtxBin} ->
                        try jsx:decode(CtxBin, [return_maps]) of
                            Ctx ->
                                Id = maps:get(<<"id">>, Ctx, list_to_binary(E)),
                                ChannelId = maps:get(<<"channel_id">>, Ctx, <<"general">>),
                                Title = maps:get(<<"title">>, Ctx, <<"Untitled">>),
                                StatusRaw = maps:get(<<"status">>, Ctx, <<"idle">>),
                                Status = case is_binary(StatusRaw) of
                                    true -> catch binary_to_existing_atom(StatusRaw, utf8);
                                    false when is_atom(StatusRaw) -> StatusRaw;
                                    _ -> idle
                                end,
                                StatusAtom = case is_atom(Status) of true -> Status; false -> idle end,
                                ets:insert(?TOPICS_TABLE, {Id, undefined, StatusAtom, ChannelId, Title})
                        catch _:_ -> ok
                        end;
                    _ -> ok
                end
            end, Entries),
            ok;
        {error, _} -> ok
    end.

register(TopicId, Pid) ->
    gen_server:call(?SERVER, {register, TopicId, Pid}).

lookup(TopicId) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, Status, _ChannelId, _Title}] -> {ok, {Pid, Status}};
        [] -> {error, not_found}
    end.

lookup_pid(TopicId) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, _Status, _ChannelId, _Title}] when is_pid(Pid) -> {ok, Pid};
        [{TopicId, undefined, _Status, _ChannelId, _Title}] ->
            gen_server:call(?SERVER, {lookup_or_start, TopicId});
        [] -> {error, not_found}
    end.

lookup_title(TopicId) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, _Pid, _Status, _ChannelId, Title}] -> {ok, Title};
        [] -> {error, not_found}
    end.

list() ->
    ets:tab2list(?TOPICS_TABLE).

list_by_channel(ChannelId) ->
    ets:select(?TOPICS_TABLE, [{{'$1', '$2', '$3', ChannelId, '$4'}, [], [{{'$1', '$2', '$3', '$4'}}]}]).

set_status(TopicId, Status) ->
    gen_server:call(?SERVER, {set_status, TopicId, Status}).

set_pid(TopicId, Pid) ->
    gen_server:call(?SERVER, {set_pid, TopicId, Pid}).

reenable(TopicId, Pid) ->
    gen_server:call(?SERVER, {reenable, TopicId, Pid}).

update(TopicId, ChannelId, Title) ->
    gen_server:call(?SERVER, {update, TopicId, ChannelId, Title}).

ensure_pid(TopicId, ExpectedPid) ->
    gen_server:call(?SERVER, {ensure_pid, TopicId, ExpectedPid}).

archive(TopicId) ->
    gen_server:call(?SERVER, {archive, TopicId}).

archive_idle() ->
    gen_server:call(?SERVER, archive_idle).

delete(TopicId) ->
    ets:delete(?TOPICS_TABLE, TopicId).

do_archive_topic(TopicId) ->
    TopicsDir = openpixie_config:topics_dir(),
    ArchiveDir = filename:join(openpixie_config:archive_dir(), "topics"),
    ok = filelib:ensure_dir(filename:join(ArchiveDir, "dummy")),
    SrcDir = filename:join(TopicsDir, binary_to_list(TopicId)),
    DstDir = filename:join(ArchiveDir, binary_to_list(TopicId)),
    case file:rename(SrcDir, DstDir) of
        ok ->
            case ets:lookup(?TOPICS_TABLE, TopicId) of
                [{TopicId, _Pid, _Status, ChannelId, Title}] ->
                    ets:insert(?TOPICS_TABLE, {TopicId, undefined, archived, ChannelId, Title});
                [] -> ok
            end;
        {error, Reason} ->
            openpixie_log:error("Failed to archive topic ~p: ~p", [TopicId, Reason])
    end.

is_old_resolved(TopicId) ->
    TopicsDir = openpixie_config:topics_dir(),
    CtxPath = filename:join([TopicsDir, binary_to_list(TopicId), "context.json"]),
    case file:read_file(CtxPath) of
        {ok, CtxBin} ->
            try jsx:decode(CtxBin, [return_maps]) of
                Ctx ->
                    LastActivity = maps:get(<<"last_activity">>, Ctx, 0),
                    Now = erlang:system_time(millisecond),
                    (Now - LastActivity) > 7 * 24 * 3600 * 1000
            catch _:_ -> false
            end;
        _ -> false
    end.

handle_call({lookup_or_start, TopicId}, _From, State) ->
    TopicsDir = openpixie_config:topics_dir(),
    TopicDir = filename:join(TopicsDir, binary_to_list(TopicId)),
    Reply = case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, _Status, _ChId, _Title}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false ->
                    case filelib:is_dir(TopicDir) of
                        true -> start_topic_existing(TopicId);
                        false -> ets:delete(?TOPICS_TABLE, TopicId), {error, not_found}
                    end
            end;
        [{TopicId, undefined, _Status, ChId, Title}] ->
            case filelib:is_dir(TopicDir) of
                true -> start_topic_existing(TopicId);
                false -> ets:delete(?TOPICS_TABLE, TopicId), {error, not_found}
            end;
        [] ->
            {error, not_found}
    end,
    {reply, Reply, State};

handle_call({register, TopicId, Pid}, _From, State) ->
    ets:insert(?TOPICS_TABLE, {TopicId, Pid, active, <<"general">>, <<"Untitled">>}),
    {reply, {ok, Pid}, State};

handle_call({set_status, TopicId, Status}, _From, State) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, _OldStatus, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, Status, ChannelId, Title});
        [] -> ok
    end,
    {reply, ok, State};

handle_call({set_pid, TopicId, Pid}, _From, State) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, _OldPid, Status, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, Status, ChannelId, Title});
        [] -> ok
    end,
    {reply, ok, State};

handle_call({reenable, TopicId, Pid}, _From, State) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, _OldPid, _Status, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, active, ChannelId, Title});
        [] -> ok
    end,
    {reply, ok, State};

handle_call({update, TopicId, ChannelId, Title}, _From, State) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, Status, _OldChannelId, _OldTitle}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, Status, ChannelId, Title});
        [] -> ok
    end,
    {reply, ok, State};

handle_call({ensure_pid, TopicId, ExpectedPid}, _From, State) ->
    Reply = case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, ExistingPid, _Status, _ChId, _Title}] when is_pid(ExistingPid) ->
            {ok, ExistingPid};
        [{TopicId, undefined, _Status, ChId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, ExpectedPid, active, ChId, Title}),
            {ok, ExpectedPid};
        [] ->
            {error, not_found}
    end,
    {reply, Reply, State};

handle_call({archive, TopicId}, _From, State) ->
    Reply = case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, _Status, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, archived, ChannelId, Title}),
            ok;
        [] ->
            {error, not_found}
    end,
    {reply, Reply, State};

handle_call(archive_idle, _From, State) ->
    All = ets:tab2list(?TOPICS_TABLE),
    lists:foreach(fun({TopicId, Pid, Status, _ChannelId, _Title}) ->
        case Status of
            idle when Pid =:= undefined ->
                do_archive_topic(TopicId);
            resolved ->
                case is_old_resolved(TopicId) of
                    true -> do_archive_topic(TopicId);
                    false -> ok
                end;
            _ -> ok
        end
    end, All),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

start_topic_existing(TopicId) ->
    case openpixie_topic_sup:start_topic(TopicId) of
        {ok, TopicId, NewPid} ->
            case ets:lookup(?TOPICS_TABLE, TopicId) of
                [{TopicId, ExistingPid, _, ChId, Title}] when is_pid(ExistingPid), ExistingPid =/= NewPid ->
                    catch openpixie_topic:stop_topic(NewPid),
                    {ok, ExistingPid};
                [{TopicId, _, _, ChId, Title}] ->
                    ets:insert(?TOPICS_TABLE, {TopicId, NewPid, active, ChId, Title}),
                    {ok, NewPid};
                [] ->
                    {error, not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.