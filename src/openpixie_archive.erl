-module(openpixie_archive).
-behaviour(gen_server).

-export([start_link/0, save_snapshot/2, list_snapshots/0, list_snapshots/1,
         get_snapshot/1, load_snapshot/1, delete_snapshot/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {dir :: string()}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    Dir = openpixie_config:archive_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    {ok, #state{dir = Dir}}.

save_snapshot(Label, Metadata) when is_binary(Label) ->
    Ts = erlang:system_time(millisecond),
    Id = <<Label/binary, "_", (integer_to_binary(Ts, 36))/binary>>,
    Dir = openpixie_config:archive_dir(),
    SnapDir = filename:join(Dir, binary_to_list(Id)),
    ok = filelib:ensure_dir(filename:join(SnapDir, "dummy")),
    {ok, SoulContent} = openpixie_soul:read(),
    ok = file:write_file(filename:join(SnapDir, "SOUL.md"), SoulContent),
    SnapshotMeta = Metadata#{
        <<"id">> => Id,
        <<"label">> => Label,
        <<"timestamp">> => Ts,
        <<"created_at">> => list_to_binary(calendar:system_time_to_rfc3339(Ts, [{offset, "Z"}]))
    },
    ok = file:write_file(filename:join(SnapDir, "metadata.json"), iolist_to_binary(jsx:encode(SnapshotMeta))),
    ok = archive_source_files(SnapDir),
    {ok, #{id => Id, path => list_to_binary(SnapDir)}}.

list_snapshots() ->
    Dir = openpixie_config:archive_dir(),
    case file:list_dir(Dir) of
        {ok, Entries} ->
            Snapshots = lists:filtermap(fun(E) ->
                MetaPath = filename:join(Dir, E ++ "/metadata.json"),
                case file:read_file(MetaPath) of
                    {ok, Content} ->
                        try jsx:decode(Content, [return_maps]) of
                            Meta -> {true, Meta}
                        catch _:_ -> false
                        end;
                    _ -> false
                end
            end, Entries),
            Sorted = lists:keysort(2, [{maps:get(<<"timestamp">>, S, 0), S} || S <- Snapshots]),
            {ok, [S || {_, S} <- Sorted]};
        {error, Reason} -> {error, Reason}
    end.

list_snapshots(Label) when is_binary(Label) ->
    {ok, All} = list_snapshots(),
    Filtered = lists:filter(fun(M) ->
        maps:get(<<"label">>, M, <<"">>) =:= Label
    end, All),
    {ok, Filtered}.

get_snapshot(Id) when is_binary(Id) ->
    Dir = openpixie_config:archive_dir(),
    SnapDir = filename:join(Dir, binary_to_list(Id)),
    MetaPath = filename:join(SnapDir, "metadata.json"),
    case file:read_file(MetaPath) of
        {ok, Content} ->
            try
                Meta = jsx:decode(Content, [return_maps]),
                {ok, Meta}
            catch _:_ -> {error, invalid_metadata}
            end;
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

load_snapshot(Id) when is_binary(Id) ->
    Dir = openpixie_config:archive_dir(),
    SnapDir = filename:join(Dir, binary_to_list(Id)),
    SoulPath = filename:join(SnapDir, "SOUL.md"),
    MetaPath = filename:join(SnapDir, "metadata.json"),
    case {file:read_file(SoulPath), file:read_file(MetaPath)} of
        {{ok, SoulContent}, {ok, MetaContent}} ->
            {ok, #{soul => SoulContent, metadata => jsx:decode(MetaContent, [return_maps]), path => list_to_binary(SnapDir)}};
        _ ->
            {error, not_found}
    end.

delete_snapshot(Id) when is_binary(Id) ->
    Dir = openpixie_config:archive_dir(),
    SnapDir = filename:join(Dir, binary_to_list(Id)),
    case del_dir(SnapDir) of
        ok -> {ok, deleted};
        {error, Reason} -> {error, Reason}
    end.

del_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(fun(E) ->
                Path = filename:join(Dir, E),
                case filelib:is_dir(Path) of
                    true -> del_dir(Path);
                    false -> file:delete(Path)
                end
            end, Entries),
            file:del_dir(Dir);
        {error, Reason} -> {error, Reason}
    end.

archive_source_files(SnapDir) ->
    SrcDir = filename:join(SnapDir, "src"),
    ok = filelib:ensure_dir(filename:join(SrcDir, "dummy")),
    case code:all_loaded() of
        Modules ->
            lists:foreach(fun({M, _}) ->
                case atom_to_binary(M, utf8) of
                    <<"openpixie", _/binary>> ->
                        case code:which(M) of
                            Path when is_list(Path) ->
                                BaseName = filename:basename(Path),
                                file:copy(Path, filename:join(SrcDir, BaseName));
                            _ -> ok
                        end;
                    _ -> ok
                end
            end, Modules),
            ok
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