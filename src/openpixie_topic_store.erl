-module(openpixie_topic_store).
-behaviour(gen_server).

-export([start_link/0, register/2, lookup/1, lookup_pid/1, list/0,
         list_by_channel/1, set_status/2, set_pid/2, reenable/2,
         update/3, archive/1, archive_idle/0, delete/1]).
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
    ets:insert(?TOPICS_TABLE, {TopicId, Pid, active, <<"general">>, <<"Untitled">>}),
    {ok, Pid}.

lookup(TopicId) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, Status, _ChannelId, _Title}] -> {ok, {Pid, Status}};
        [] -> {error, not_found}
    end.

lookup_pid(TopicId) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, _Status, _ChannelId, _Title}] when is_pid(Pid) -> {ok, Pid};
        [{TopicId, undefined, _Status, _ChannelId, _Title}] ->
            case openpixie_topic:resume(TopicId) of
                {ok, NewPid} -> {ok, NewPid};
                {error, _} -> {error, not_found}
            end;
        [] -> {error, not_found}
    end.

list() ->
    ets:tab2list(?TOPICS_TABLE).

list_by_channel(ChannelId) ->
    ets:select(?TOPICS_TABLE, [{{'$1', '$2', '$3', ChannelId, '$4'}, [], [{{'$1', '$2', '$3', '$4'}}]}]).

set_status(TopicId, Status) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, _OldStatus, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, Status, ChannelId, Title});
        [] -> ok
    end.

set_pid(TopicId, Pid) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, _OldPid, Status, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, Status, ChannelId, Title});
        [] -> ok
    end.

reenable(TopicId, Pid) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, _OldPid, _Status, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, active, ChannelId, Title});
        [] -> ok
    end.

update(TopicId, ChannelId, Title) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, Status, _OldChannelId, _OldTitle}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, Status, ChannelId, Title});
        [] -> ok
    end.

archive(TopicId) ->
    case ets:lookup(?TOPICS_TABLE, TopicId) of
        [{TopicId, Pid, _Status, ChannelId, Title}] ->
            ets:insert(?TOPICS_TABLE, {TopicId, Pid, archived, ChannelId, Title}),
            ok;
        [] ->
            {error, not_found}
    end.

archive_idle() ->
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
    end, All).

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

delete(TopicId) ->
    ets:delete(?TOPICS_TABLE, TopicId).

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

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.