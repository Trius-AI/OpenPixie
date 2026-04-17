-module(openpixie_tools_file).
-export([schema/0, read_file/1, write_file/1, edit_file/1, create_directory/1, list_files/1, file_exists/1]).

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
            ok = filelib:ensure_dir(FullPath),
            case file:write_file(FullPath, Content) of
                ok -> #{success => true, path => Path};
                {error, Reason} -> #{success => false, error => file_write_error, reason => Reason}
            end;
        false ->
            #{success => false, error => path_outside_workspace}
    end.

edit_file(#{path := Path, old_string := Old, new_string := New}) ->
    FullPath = workspace_path(Path),
    case validate_in_workspace(FullPath) of
        true ->
            case file:read_file(FullPath) of
                {ok, Content} ->
                    case binary:match(Content, Old) of
                        nomatch ->
                            #{success => false, error => old_string_not_found};
                        _ ->
                            NewContent = binary:replace(Content, Old, New),
                            case file:write_file(FullPath, NewContent) of
                                ok -> #{success => true, path => Path};
                                {error, Reason} -> #{success => false, error => file_write_error, reason => Reason}
                            end
                    end;
                {error, Reason} ->
                    #{success => false, error => file_read_error, reason => Reason}
            end;
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

workspace_path(RelPath) ->
    Ws = openpixie_config:workspace(),
    filename:join(Ws, binary_to_list(RelPath)).

validate_in_workspace(FullPath) ->
    Ws = openpixie_config:workspace(),
    AbsWs = filename:absname(Ws),
    AbsPath = filename:absname(FullPath),
    lists:prefix(AbsWs, AbsPath).