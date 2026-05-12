-module(openpixie_tools_self).
-export([schema/0, reload_module/1, get_self_modules/1, analyze_self/1, list_models/1, show_model/1,
         propose_soul_edit/1, get_soul_proposal/1, apply_soul_proposal/1, reject_soul_proposal/1,
         compile_and_reload/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => reload_module,
                description => <<"Hot-reload a BEAM module (requires user confirmation)">>,
                parameters => #{
                    type => object,
                    properties => #{
                        module => #{type => string, description => <<"Module name to reload">>}
                    },
                    required => [module]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => get_self_modules,
                description => <<"List loaded OpenPixie modules">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        },
        #{
            type => function,
            function => #{
                name => analyze_self,
                description => <<"Analyze the running OpenPixie system">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        },
        #{
            type => function,
            function => #{
                name => list_models,
                description => <<"List available Ollama models">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        },
        #{
            type => function,
            function => #{
                name => show_model,
                description => <<"Show details of an Ollama model">>,
                parameters => #{
                    type => object,
                    properties => #{
                        name => #{type => string, description => <<"Model name">>}
                    },
                    required => [name]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => propose_soul_edit,
                description => <<"Propose an edit to SOUL.md (requires user approval to apply)">>,
                parameters => #{
                    type => object,
                    properties => #{
                        content => #{type => string, description => <<"New proposed SOUL.md content">>}
                    },
                    required => [content]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => get_soul_proposal,
                description => <<"Read the current pending SOUL.md proposal">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        },
        #{
            type => function,
            function => #{
                name => apply_soul_proposal,
                description => <<"Apply the pending SOUL.md proposal (requires user confirmation)">>,
                parameters => #{
                    type => object,
                    properties => #{
                        approval => #{type => string, description => <<"Approval data or reason for applying">>}
                    },
                    required => [approval]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => reject_soul_proposal,
                description => <<"Reject the pending SOUL.md proposal">>,
                parameters => #{
                    type => object,
                    properties => #{
                        reason => #{type => string, description => <<"Reason for rejection">>}
                    },
                    required => [reason]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => compile_and_reload,
                description => <<"Compile an Erlang source file and hot-reload the module. Writes the beam to ebin/ next to the source.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        path => #{type => string, description => <<"Path to the .erl source file relative to workspace">>}
                    },
                    required => [path]
                }
            }
        }
    ].

reload_module(Args) when is_map(Args) ->
    ModuleBin = maps:get(<<"module">>, Args, maps:get(module, Args, <<"">>)),
    Module = binary_to_existing_atom(ModuleBin, utf8),
    Ws = openpixie_config:workspace(),
    BeamPath = filename:join([Ws, "ebin", atom_to_list(Module) ++ ".beam"]),
    case code:load_abs(filename:join([Ws, "ebin", atom_to_list(Module)])) of
        {module, Module} ->
            #{success => true, module => ModuleBin, status => reloaded};
        {error, Reason} ->
            case filelib:is_file(BeamPath) of
                true ->
                    #{success => false, error => load_failed, reason => iolist_to_binary(io_lib:format("~p", [Reason]))};
                false ->
                    #{success => false, error => beam_not_found,
                      hint => <<"Compile the module first with compile_and_reload">>,
                      path => list_to_binary(BeamPath)}
            end
    end.

get_self_modules(_) ->
    Modules = code:all_loaded(),
    PixieMods = lists:filter(fun({M, _}) ->
        case atom_to_binary(M, utf8) of
            <<"openpixie", _/binary>> -> true;
            _ -> false
        end
    end, Modules),
    Names = [atom_to_binary(M, utf8) || {M, _} <- PixieMods],
    #{success => true, modules => Names}.

analyze_self(_) ->
    AppInfo = application:get_all_env(openpixie),
    #{success => true, config => AppInfo}.

list_models(_) ->
    case openpixie_ollama:list_models() of
        {ok, #{models := Models}} ->
            Names = [maps:get(name, M) || M <- Models],
            #{success => true, models => Names};
        {ok, Response} ->
            Names = [maps:get(name, M) || M <- maps:get(models, Response, [])],
            #{success => true, models => Names};
        {error, Reason} ->
            #{success => false, error => Reason}
    end.

show_model(Args) when is_map(Args) ->
    Name = maps:get(<<"name">>, Args, maps:get(name, Args, <<"">>)),
    case openpixie_ollama:show_model(Name) of
        {ok, Info} -> #{success => true, info => Info, name => Name};
        {error, Reason} -> #{success => false, error => Reason, name => Name}
    end.

propose_soul_edit(Args) when is_map(Args) ->
    Content = maps:get(<<"content">>, Args, maps:get(content, Args, <<"">>)),
    case openpixie_soul:propose_edit(Content) of
        {ok, Path} -> #{success => true, proposal_path => list_to_binary(Path), status => proposed};
        {error, Reason} -> #{success => false, error => Reason}
    end.

get_soul_proposal(_) ->
    case openpixie_soul:get_proposal() of
        {ok, Content} -> #{success => true, content => Content};
        {error, no_proposal} -> #{success => true, content => <<"">>, status => no_pending_proposal};
        {error, Reason} -> #{success => false, error => Reason}
    end.

apply_soul_proposal(Args) when is_map(Args) ->
    Approval = maps:get(<<"approval">>, Args, maps:get(approval, Args, <<"">>)),
    case openpixie_soul:apply_proposal(Approval) of
        {ok, Path} -> #{success => true, applied => list_to_binary(Path)};
        {error, Reason} -> #{success => false, error => Reason}
    end.

reject_soul_proposal(Args) when is_map(Args) ->
    Reason = maps:get(<<"reason">>, Args, maps:get(reason, Args, <<"rejected">>)),
    ok = openpixie_soul:reject_proposal(Reason),
    #{success => true, status => rejected}.

compile_and_reload(Args) when is_map(Args) ->
    PathBin = maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)),
    Ws = openpixie_config:workspace(),
    SrcPath0 = binary_to_list(PathBin),
    SrcPath = case filelib:is_file(SrcPath0) of
        true -> SrcPath0;
        false -> filename:join(Ws, SrcPath0)
    end,
    case filelib:is_file(SrcPath) of
        false ->
            #{success => false, error => file_not_found, path => PathBin};
        true ->
            EbinDir = filename:join(Ws, "ebin"),
            ok = filelib:ensure_dir(filename:join(EbinDir, "dummy")),
            case compile:file(SrcPath, [{outdir, EbinDir}, return_errors]) of
                {ok, ModuleName} ->
                    load_compiled_module(ModuleName, EbinDir, PathBin);
                {error, Errors, _Warnings} ->
                    ErrBin = iolist_to_binary([io_lib:format("~p~n", [E]) || E <- Errors]),
                    EscapedPath = escape_shell_arg(SrcPath),
                    EscapedWs = escape_shell_arg(Ws),
                    os:cmd("cd " ++ EscapedWs ++ " && git checkout -- " ++ EscapedPath ++ " 2>/dev/null"),
                    #{success => false, error => compilation_failed, errors => ErrBin,
                      auto_reverted => true, path => PathBin,
                      hint => <<"Source file auto-reverted to last committed version. Fix the errors and try again.">>};
                {error, Errors} ->
                    ErrBin = iolist_to_binary([io_lib:format("~p~n", [E]) || E <- Errors]),
                    EscapedPath = escape_shell_arg(SrcPath),
                    EscapedWs = escape_shell_arg(Ws),
                    os:cmd("cd " ++ EscapedWs ++ " && git checkout -- " ++ EscapedPath ++ " 2>/dev/null"),
                    #{success => false, error => compilation_failed, errors => ErrBin,
                      auto_reverted => true, path => PathBin,
                      hint => <<"Source file auto-reverted to last committed version. Fix the errors and try again.">>}
            end
    end.

escape_shell_arg(Arg) ->
    "'" ++ lists:filter(fun($') -> false; (_) -> true end, Arg) ++ "'".

load_compiled_module(ModuleName, EbinDir, PathBin) ->
    case code:load_abs(filename:join(EbinDir, atom_to_list(ModuleName))) of
        {module, ModuleName} ->
            #{success => true, module => atom_to_binary(ModuleName, utf8),
              status => compiled_and_reloaded};
        {error, load_err} ->
            #{success => false, error => load_failed, reason => iolist_to_binary(io_lib:format("~p", [load_err]))}
    end.