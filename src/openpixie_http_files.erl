-module(openpixie_http_files).
-export([init/2]).

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} ->
            Method = cowboy_req:method(Req),
            handle(Method, Req, State);
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle(<<"GET">>, Req, State) ->
    Qs = cowboy_req:parse_qs(Req),
    Path = proplists:get_value(<<"path">>, Qs, <<"/">>),
    Action = proplists:get_value(<<"action">>, Qs, <<"browse">>),
    case Action of
        <<"browse">> -> handle_browse(Req, State, Path);
        <<"view">> -> handle_view(Req, State, Path);
        <<"download">> -> handle_download(Req, State, Path);
        _ -> reply_json(Req, State, 400, #{error => <<"unknown action">>})
    end;
handle(<<"POST">>, Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 10485760, period => 15000}),
    case jsx:is_json(Body) of
        true ->
            Msg = jsx:decode(Body, [return_maps]),
            Action = maps:get(<<"action">>, Msg, undefined),
            handle_action(Action, Req2, State, Msg);
        false ->
            reply_json(Req2, State, 400, #{error => <<"invalid json">>})
    end;
handle(_, Req, State) ->
    reply_json(Req, State, 405, #{error => method_not_allowed}).

handle_action(<<"create">>, Req, State, Msg) ->
    Path = maps:get(<<"path">>, Msg, <<"/">>),
    Content = maps:get(<<"content">>, Msg, <<>>),
    case resolve_path(Path) of
        {ok, FullPath} ->
            Dir = filename:dirname(FullPath),
            case filelib:ensure_dir(Dir ++ "/") of
                ok ->
                    case file:write_file(FullPath, Content) of
                        ok -> reply_json(Req, State, 200, #{success => true, path => list_to_binary(FullPath)});
                        {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
                    end;
                {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
            end;
        {error, Reason} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(Reason)})
    end;
handle_action(<<"mkdir">>, Req, State, Msg) ->
    Path = maps:get(<<"path">>, Msg, <<"/">>),
    case resolve_path(Path) of
        {ok, FullPath} ->
            case file:make_dir(FullPath) of
                ok -> reply_json(Req, State, 200, #{success => true, path => list_to_binary(FullPath)});
                {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
            end;
        {error, Reason} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(Reason)})
    end;
handle_action(<<"delete">>, Req, State, Msg) ->
    Path = maps:get(<<"path">>, Msg, <<"/">>),
    case resolve_path(Path) of
        {ok, FullPath} ->
            case filelib:is_dir(FullPath) of
                true ->
                    case del_dir(FullPath) of
                        ok -> reply_json(Req, State, 200, #{success => true});
                        {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
                    end;
                false ->
                    case file:delete(FullPath) of
                        ok -> reply_json(Req, State, 200, #{success => true});
                        {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
                    end
            end;
        {error, Reason} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(Reason)})
    end;
handle_action(<<"rename">>, Req, State, Msg) ->
    OldPath = maps:get(<<"old_path">>, Msg, undefined),
    NewPath = maps:get(<<"new_path">>, Msg, undefined),
    case {resolve_path(OldPath), resolve_path(NewPath)} of
        {{ok, FullOld}, {ok, FullNew}} ->
            NewDir = filename:dirname(FullNew),
            case filelib:ensure_dir(NewDir ++ "/") of
                ok ->
                    case file:rename(FullOld, FullNew) of
                        ok -> reply_json(Req, State, 200, #{success => true, path => list_to_binary(FullNew)});
                        {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
                    end;
                {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
            end;
        {{error, R}, _} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(R)});
        {_, {error, R}} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(R)})
    end;
handle_action(<<"upload">>, Req, State, Msg) ->
    Path = maps:get(<<"path">>, Msg, <<"/">>),
    Content = maps:get(<<"content">>, Msg, <<>>),
    Encoding = maps:get(<<"encoding">>, Msg, <<"utf8">>),
    case resolve_path(Path) of
        {ok, FullPath} ->
            Dir = filename:dirname(FullPath),
            case filelib:ensure_dir(Dir ++ "/") of
                ok ->
                    BinContent = case Encoding of
                        <<"base64">> -> base64:decode(Content);
                        _ -> Content
                    end,
                    case file:write_file(FullPath, BinContent) of
                        ok -> reply_json(Req, State, 200, #{success => true, path => list_to_binary(FullPath), size => byte_size(BinContent)});
                        {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
                    end;
                {error, Reason} -> reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
            end;
        {error, Reason} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(Reason)})
    end;
handle_action(_, Req, State, _Msg) ->
    reply_json(Req, State, 400, #{error => <<"unknown action">>}).

handle_browse(Req, State, RelPath) ->
    case resolve_path(RelPath) of
        {ok, FullPath} ->
            case filelib:is_dir(FullPath) of
                true ->
                    Entries = list_dir(FullPath),
                    reply_json(Req, State, 200, #{
                        success => true,
                        path => list_to_binary(rel_path(FullPath)),
                        entries => Entries
                    });
                false ->
                    reply_json(Req, State, 200, #{
                        success => true,
                        path => list_to_binary(rel_path(FullPath)),
                        is_file => true,
                        size => filelib:file_size(FullPath),
                        mtime => file_mtime(FullPath)
                    })
            end;
        {error, Reason} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(Reason)})
    end.

handle_view(Req, State, RelPath) ->
    case resolve_path(RelPath) of
        {ok, FullPath} ->
            MaxSize = 512 * 1024,
            case filelib:is_file(FullPath) of
                true ->
                    FileSize = filelib:file_size(FullPath),
                    case FileSize =< MaxSize of
                        true ->
                            case file:read_file(FullPath) of
                                {ok, Bin} ->
                                    IsBinary = is_binary_content(Bin),
                                    reply_json(Req, State, 200, #{
                                        success => true,
                                        path => list_to_binary(rel_path(FullPath)),
                                        content => Bin,
                                        binary => IsBinary,
                                        size => byte_size(Bin)
                                    });
                                {error, Reason} ->
                                    reply_json(Req, State, 500, #{success => false, error => list_to_binary(file:format_error(Reason))})
                            end;
                        false ->
                            reply_json(Req, State, 200, #{
                                success => true,
                                path => list_to_binary(rel_path(FullPath)),
                                size => FileSize,
                                too_large => true
                            })
                    end;
                false ->
                    reply_json(Req, State, 404, #{success => false, error => <<"not found">>})
            end;
        {error, Reason} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(Reason)})
    end.

handle_download(Req, State, RelPath) ->
    case resolve_path(RelPath) of
        {ok, FullPath} ->
            case file:read_file(FullPath) of
                {ok, Bin} ->
                    Filename = list_to_binary(filename:basename(FullPath)),
                    ContentType = guess_content_type(Filename),
                    Req2 = cowboy_req:reply(200, #{
                        <<"content-type">> => ContentType,
                        <<"content-disposition">> => <<"attachment; filename=\"", Filename/binary, "\"">>
                    }, Bin, Req),
                    {ok, Req2, State};
                {error, _} ->
                    reply_json(Req, State, 404, #{error => <<"not found">>})
            end;
        {error, Reason} -> reply_json(Req, State, 400, #{success => false, error => list_to_binary(Reason)})
    end.

resolve_path(RelPath) when is_binary(RelPath) ->
    resolve_path(binary_to_list(RelPath));
resolve_path(RelPath) when is_list(RelPath) ->
    Ws = openpixie_config:workspace(),
    Clean = normalize_path(RelPath),
    FullPath = filename:join(Ws, Clean),
    Safe = filename:absname(FullPath),
    WsAbs = filename:absname(Ws),
    case string:prefix(Safe, WsAbs) of
        nomatch -> {error, "path outside workspace"};
        _ -> {ok, Safe}
    end.

normalize_path(Path) ->
    Parts = string:tokens(Path, "/"),
    norm_parts(Parts, []).

norm_parts([], Acc) -> string:join(lists:reverse(Acc), "/");
norm_parts(["."|T], Acc) -> norm_parts(T, Acc);
norm_parts([".."|T], []) -> norm_parts(T, []);
norm_parts([".."|T], [_|Acc]) -> norm_parts(T, Acc);
norm_parts([H|T], Acc) -> norm_parts(T, [H|Acc]).

rel_path(FullPath) ->
    Ws = filename:absname(openpixie_config:workspace()),
    Safe = filename:absname(FullPath),
    case string:prefix(Safe, Ws) of
        nomatch -> FullPath;
        [] -> "/";
        "/" ++ Rel -> "/" ++ Rel;
        Rel when is_list(Rel) -> "/" ++ Rel;
        _ -> FullPath
    end.

list_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:sort(fun compare_entries/2, lists:filtermap(fun(Name) ->
                FullPath = filename:join(Dir, Name),
                case filelib:is_dir(FullPath) of
                    true -> {true, #{
                        name => list_to_binary(Name),
                        path => list_to_binary(rel_path(FullPath)),
                        type => <<"directory">>,
                        mtime => file_mtime(FullPath)
                    }};
                    false ->
                        case filelib:is_file(FullPath) of
                            true -> {true, #{
                                name => list_to_binary(Name),
                                path => list_to_binary(rel_path(FullPath)),
                                type => <<"file">>,
                                size => filelib:file_size(FullPath),
                                mtime => file_mtime(FullPath)
                            }};
                            false -> false
                        end
                end
            end, Names));
        {error, _} -> []
    end.

compare_entries(A, B) ->
    AType = maps:get(type, A, <<"file">>),
    BType = maps:get(type, B, <<"file">>),
    case {AType, BType} of
        {<<"directory">>, <<"file">>} -> true;
        {<<"file">>, <<"directory">>} -> false;
        _ -> maps:get(name, A) =< maps:get(name, B)
    end.

del_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(fun(Name) ->
                FullPath = filename:join(Dir, Name),
                case filelib:is_dir(FullPath) of
                    true -> del_dir(FullPath);
                    false -> file:delete(FullPath)
                end
            end, Names),
            file:del_dir(Dir);
        {error, Reason} -> {error, Reason}
    end.

file_mtime(FullPath) ->
    case file:read_file_info(FullPath) of
        {ok, Info} ->
            Mtime = element(7, Info),
            {{Y, Mo, D}, {H, Mi, S}} = Mtime,
            iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [Y, Mo, D, H, Mi, S]));
        _ -> <<"unknown">>
    end.

is_binary_content(Bin) when byte_size(Bin) > 0 ->
    NullCount = count_null_bytes(Bin, 0),
    NullCount > byte_size(Bin) div 4;
is_binary_content(_) -> false.

count_null_bytes(<<>>, Acc) -> Acc;
count_null_bytes(<<0, Rest/binary>>, Acc) -> count_null_bytes(Rest, Acc + 1);
count_null_bytes(<<_, Rest/binary>>, Acc) -> count_null_bytes(Rest, Acc).

guess_content_type(Filename) ->
    case filename:extension(Filename) of
        <<".html">> -> <<"text/html">>;
        <<".css">> -> <<"text/css">>;
        <<".js">> -> <<"application/javascript">>;
        <<".json">> -> <<"application/json">>;
        <<".erl">> -> <<"text/plain">>;
        <<".md">> -> <<"text/markdown">>;
        <<".txt">> -> <<"text/plain">>;
        <<".png">> -> <<"image/png">>;
        <<".jpg">> -> <<"image/jpeg">>;
        <<".jpeg">> -> <<"image/jpeg">>;
        <<".gif">> -> <<"image/gif">>;
        <<".svg">> -> <<"image/svg+xml">>;
        <<".pdf">> -> <<"application/pdf">>;
        <<".zip">> -> <<"application/zip">>;
        _ -> <<"application/octet-stream">>
    end.

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.