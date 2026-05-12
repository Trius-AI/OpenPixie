-module(openpixie_tools_file).
-export([schema/0, read_file/1, write_file/1, edit_file/1, create_directory/1, list_files/1, file_exists/1, verify_file/1]).

-define(LOCK_TABLE, openpixie_file_locks).
-define(LOCK_TIMEOUT, 30000).

ensure_lock_table() ->
    case ets:whereis(?LOCK_TABLE) of
        undefined ->
            ets:new(?LOCK_TABLE, [named_table, public, set]);
        _ -> ok
    end.

acquire_file_lock(FullPath) ->
    ensure_lock_table(),
    acquire_file_lock(FullPath, ?LOCK_TIMEOUT).

acquire_file_lock(_FullPath, 0) ->
    {error, timeout};
acquire_file_lock(FullPath, Remaining) ->
    Owner = self(),
    case ets:insert_new(?LOCK_TABLE, {FullPath, Owner}) of
        true -> ok;
        false ->
            case ets:lookup(?LOCK_TABLE, FullPath) of
                [{FullPath, Owner}] -> ok;
                _ ->
                    timer:sleep(50),
                    acquire_file_lock(FullPath, Remaining - 50)
            end
    end.

release_file_lock(FullPath) ->
    ets:delete(?LOCK_TABLE, FullPath),
    ok.

with_file_lock(FullPath, Fun) ->
    case acquire_file_lock(FullPath) of
        ok ->
            try Fun()
            after release_file_lock(FullPath)
            end;
        {error, timeout} ->
            #{success => false, error => file_lock_timeout}
    end.

schema() ->
    [
        #{
            type => function,
            function => #{
                name => read_file,
                description => <<"Read the contents of a file">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"File path (relative to workspace)">>}
                    },
                    required => [path]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => write_file,
                description => <<"Write content to a file">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"File path">>},
                        content => #{type => string, description => <<"Content to write">>}
                    },
                    required => [path, content]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => edit_file,
                description => <<"Replace an exact string in a file">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"File path">>},
                        old_string => #{type => string, description => <<"String to replace">>},
                        new_string => #{type => string, description => <<"Replacement string">>}
                    },
                    required => [path, old_string, new_string]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => create_directory,
                description => <<"Create a directory">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"Directory path">>}
                    },
                    required => [path]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => list_files,
                description => <<"List files in a directory">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"Directory path">>}
                    },
                    required => [path]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => file_exists,
                description => <<"Check if a file exists">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"File path">>}
                    },
                    required => [path]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => verify_file,
                description => <<"Validate a file's syntax. Checks HTML tag balance, JS bracket balance, or Erlang compilability. Use after editing self-source files to catch corruption before it breaks the system.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"File path">>},
                        type => #{type => string, description => <<"File type hint: html, js, erlang, or auto-detect from extension">>}
                    },
                    required => [path]
                }
            }
        }
    ].

read_file(#{path := Path}) ->
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            case file:read_file(FullPath) of
                {ok, Content} -> #{success => true, content => Content, path => Path};
                {error, Reason} -> #{success => false, error => file_read_error, reason => Reason}
            end;
        false ->
            #{success => false, error => path_outside_workspace}
    end.

write_file(#{path := Path, content := Content}) ->
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            maybe_auto_checkpoint(FullPath),
            with_file_lock(FullPath, fun() ->
                ok = filelib:ensure_dir(FullPath),
                TmpPath = FullPath ++ ".tmp",
                case file:write_file(TmpPath, Content) of
                    ok ->
                        case file:rename(TmpPath, FullPath) of
                            ok -> #{success => true, path => Path};
                            {error, Reason} -> #{success => false, error => file_write_error, reason => Reason}
                        end;
                    {error, Reason} -> #{success => false, error => file_write_error, reason => Reason}
                end
            end);
        false ->
            #{success => false, error => path_outside_workspace}
    end.

edit_file(#{path := Path, old_string := Old, new_string := New}) ->
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            with_file_lock(FullPath, fun() ->
                case file:read_file(FullPath) of
                    {ok, Content} ->
                        case binary:match(Content, Old) of
                            nomatch ->
                                #{success => false, error => old_string_not_found};
                            _ ->
                                TotalMatches = count_occurrences(Content, Old),
                                {NewContent, _Count} = replace_first(Content, Old, New),
                                maybe_auto_checkpoint(FullPath),
                                TmpPath = FullPath ++ ".tmp",
                                case file:write_file(TmpPath, NewContent) of
                                    ok ->
                                        case file:rename(TmpPath, FullPath) of
                                            ok ->
                                                Result = #{success => true, path => Path, total_matches => TotalMatches},
                                                case TotalMatches > 1 of
                                                    true -> Result#{warning => <<"old_string found in multiple locations; only the first occurrence was replaced">>};
                                                    false -> Result
                                                end;
                                            {error, Reason} -> #{success => false, error => file_write_error, reason => Reason}
                                        end;
                                    {error, Reason} ->
                                        #{success => false, error => file_write_error, reason => Reason}
                                end
                        end;
                    {error, Reason} ->
                        #{success => false, error => file_read_error, reason => Reason}
                end
            end);
        false ->
            #{success => false, error => path_outside_workspace}
    end.

create_directory(#{path := Path}) ->
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            case filelib:ensure_dir(filename:join(FullPath, "dummy")) of
                ok -> #{success => true, path => Path};
                {error, Reason} -> #{success => false, error => mkdir_error, reason => Reason}
            end;
        false ->
            #{success => false, error => path_outside_workspace}
    end.

list_files(#{path := Path}) ->
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            case file:list_dir(FullPath) of
                {ok, Entries} ->
                    BinEntries = [list_to_binary(E) || E <- Entries],
                    #{success => true, files => BinEntries, path => Path};
                {error, Reason} -> #{success => false, error => list_dir_error, reason => list_to_binary(io_lib:format("~p", [Reason]))}
            end;
        false ->
            #{success => false, error => path_outside_workspace}
    end.

file_exists(#{path := Path}) ->
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            #{success => true, exists => filelib:is_file(FullPath), path => Path};
        false ->
            #{success => false, error => path_outside_workspace}
    end.

verify_file(#{path := Path} = Args) ->
    TypeHint = maps:get(<<"type">>, Args, <<"auto">>),
    TypeHintBin = if is_binary(TypeHint) -> TypeHint; true -> atom_to_binary(TypeHint, utf8) end,
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            case file:read_file(FullPath) of
                {ok, Content} ->
                    FileType = detect_file_type(Path, TypeHintBin),
                    case FileType of
                        erlang -> verify_erlang(FullPath, Path);
                        html -> verify_html(Content, Path);
                        js -> verify_js(Content, Path);
                        _ -> #{success => true, valid => true, path => Path, type => FileType}
                    end;
                {error, Reason} ->
                    #{success => false, error => file_read_error, reason => list_to_binary(io_lib:format("~p", [Reason]))}
            end;
        false ->
            #{success => false, error => path_outside_workspace}
    end.

detect_file_type(Path, <<"auto">>) ->
    Lower = string:lowercase(binary_to_list(Path)),
    case lists:suffix(".erl", Lower) of true -> erlang; false ->
    case lists:suffix(".html", Lower) orelse lists:suffix(".htm", Lower) of true -> html; false ->
    case lists:suffix(".js", Lower) of true -> js; false -> unknown end end end;
detect_file_type(_Path, TypeHint) ->
    case TypeHint of
        <<"erlang">> -> erlang;
        <<"html">> -> html;
        <<"js">> -> js;
        _ -> unknown
    end.

verify_erlang(FullPath, Path) ->
    EbinDir = filename:join(openpixie_config:workspace(), "ebin"),
    case compile:file(FullPath, [{outdir, EbinDir}, return_errors, no_warn_unused]) of
        {ok, _Module} ->
            #{success => true, valid => true, path => Path, type => erlang};
        {error, Errors, _Warnings} ->
            ErrBin = iolist_to_binary([io_lib:format("~p~n", [E]) || E <- Errors]),
            #{success => true, valid => false, path => Path, type => erlang, errors => ErrBin}
    end.

verify_html(Content, Path) ->
    Checks = [
        check_balanced_tags(Content, [<<"<script">>, <<"</script">>]),
        check_balanced_tags(Content, [<<"<style">>, <<"</style">>]),
        check_balanced(Content, <<"{">>, <<"}">>)
    ],
    Errors = [Msg || {error, Msg} <- Checks],
    case Errors of
        [] -> #{success => true, valid => true, path => Path, type => html};
        _ ->
            ErrText = iolist_to_binary(lists:join(<<"; ">>, Errors)),
            #{success => true, valid => false, path => Path, type => html, errors => ErrText}
    end.

verify_js(Content, Path) ->
    Checks = [
        check_balanced(Content, <<"{">>, <<"}">>),
        check_balanced(Content, <<"[">>, <<"]">>),
        check_balanced(Content, <<"(">>, <<")">>)
    ],
    Errors = [Msg || {error, Msg} <- Checks],
    case Errors of
        [] -> #{success => true, valid => true, path => Path, type => js};
        _ ->
            ErrText = iolist_to_binary(lists:join(<<"; ">>, Errors)),
            #{success => true, valid => false, path => Path, type => js, errors => ErrText}
    end.

check_balanced(Content, Open, Close) ->
    OpenCount = count_binary(Content, Open),
    CloseCount = count_binary(Content, Close),
    case OpenCount =:= CloseCount of
        true -> {ok, OpenCount};
        false ->
            Msg = <<"Unbalanced brackets: ", Open/binary, " count=", (integer_to_binary(OpenCount))/binary,
                    " vs ", Close/binary, " count=", (integer_to_binary(CloseCount))/binary>>,
            {error, Msg}
    end.

check_balanced_tags(Content, [OpenTag, CloseTag]) ->
    OpenCount = count_binary(Content, OpenTag),
    CloseCount = count_binary(Content, CloseTag),
    case OpenCount =:= CloseCount of
        true -> {ok, OpenCount};
        false ->
            Msg = <<"Unbalanced tags: ", OpenTag/binary, "(", (integer_to_binary(OpenCount))/binary,
                    ") vs ", CloseTag/binary, "(", (integer_to_binary(CloseCount))/binary, ")">>,
            {error, Msg}
    end.

count_binary(Content, Pattern) ->
    count_binary(Content, Pattern, 0).
count_binary(Content, Pattern, Acc) ->
    case binary:match(Content, Pattern) of
        nomatch -> Acc;
        {Pos, Len} ->
            Rest = binary:part(Content, Pos + Len, max(0, byte_size(Content) - Pos - Len)),
            count_binary(Rest, Pattern, Acc + 1)
    end.

workspace_path(RelPath) ->
    Ws = openpixie_config:workspace(),
    filename:join(Ws, binary_to_list(RelPath)).

replace_first(Content, Old, New) ->
    case binary:match(Content, Old) of
        nomatch -> {Content, 0};
        {Pos, Len} ->
            Before = binary:part(Content, 0, Pos),
            After = binary:part(Content, Pos + Len, byte_size(Content) - Pos - Len),
            {<<Before/binary, New/binary, After/binary>>, 1}
    end.

count_occurrences(Content, Pattern) ->
    count_occurrences(Content, Pattern, 0).
count_occurrences(Content, Pattern, Acc) ->
    case binary:match(Content, Pattern) of
        nomatch -> Acc;
        {Pos, Len} ->
            Rest = binary:part(Content, Pos + Len, byte_size(Content) - Pos - Len),
            count_occurrences(Rest, Pattern, Acc + 1)
    end.

is_self_source_path(PathBin) ->
    Lower = string:lowercase(binary_to_list(PathBin)),
    lists:suffix(".erl", Lower) orelse
        lists:suffix("index.html", Lower) orelse
        lists:suffix(".js", Lower).

maybe_auto_checkpoint(FullPath) ->
    Ws = openpixie_config:workspace(),
    RelPath = FullPath -- Ws ++ "/",
    PathBin = list_to_binary(RelPath),
    case is_self_source_path(PathBin) of
        true ->
            os:cmd("cd " ++ Ws ++ " && git add -A && git diff --cached --quiet 2>/dev/null || git commit -m 'auto-checkpoint: pre-edit of " ++ RelPath ++ "' --allow-empty 2>/dev/null");
        false -> ok
    end.

validate_in_workspace(FullPath) ->
    Ws = openpixie_config:workspace(),
    AbsWs = filename:absname(Ws),
    AbsPath = filename:absname(FullPath),
    lists:prefix(AbsWs, AbsPath).