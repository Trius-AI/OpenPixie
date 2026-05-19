-module(openpixie_tools_self_improve).
-export([schema/0, run/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => self_improve,
                description => <<"Apply a targeted self-improvement change. This is the ONLY way to modify code or configuration in scheduled mode. Each call makes exactly one edit, but multiple calls are allowed within a single run to complete one conceptual change. If compilation fails, the broken edit is left in place - use read_file to examine the broken code, then call self_improve again with a corrected edit.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        issue => #{
                            type => string,
                            description => <<"The specific problem you identified that needs fixing.">>
                        },
                        plan => #{
                            type => string,
                            description => <<"Brief description of the change you plan to make.">>
                        },
                        file => #{
                            type => string,
                            description => <<"Path to the file to edit or create, relative to workspace (e.g. 'src/openpixie_ws.erl'). For new files, omit old_string.">>
                        },
                        old_string => #{
                            type => string,
                            description => <<"The exact text in the file that you want to replace. Must be unique in the file. Omit or leave empty to create a new file.">>
                        },
                        new_string => #{
                            type => string,
                            description => <<"The replacement text, or the full content for a new file.">>
                        }
                    },
                    required => [issue, plan, file, new_string]
                }
            }
        }
    ].

run(Args) when is_map(Args) ->
    do_improve(Args).

do_improve(Args) ->
    Issue = maps:get(<<"issue">>, Args, <<>>),
    Plan = maps:get(<<"plan">>, Args, <<>>),
    File = maps:get(<<"file">>, Args, <<>>),
    OldString = maps:get(<<"old_string">>, Args, <<>>),
    NewString = maps:get(<<"new_string">>, Args, <<>>),
    case Issue of
        <<>> -> #{success => false, error => <<"issue is required">>};
        _ ->
            case File of
                <<>> -> #{success => false, error => <<"file is required">>};
                _ ->
                    GuardianArgs = #{file => File, old_string => OldString, new_string => NewString},
                    case openpixie_guardian:pre_check(self_improve, GuardianArgs) of
                        {reject, Reason} ->
                            #{success => false, error => guardian_rejected, reason => Reason};
                        _ ->
                            apply_and_verify(Args)
                    end
            end
    end.

apply_and_verify(Args) ->
    Issue = maps:get(<<"issue">>, Args),
    Plan = maps:get(<<"plan">>, Args),
    File = maps:get(<<"file">>, Args),
    OldString = maps:get(<<"old_string">>, Args, <<>>),
    NewString = maps:get(<<"new_string">>, Args),
    FullPath = filename:join(openpixie_config:workspace(), binary_to_list(File)),
    IsNewFile = (OldString =:= <<>>),
    case file:read_file(FullPath) of
        {error, enoent} when IsNewFile ->
            ok = filelib:ensure_dir(FullPath),
            case file:write_file(FullPath, NewString) of
                ok ->
                    CompileResult = compile_and_check(File, FullPath),
                    case CompileResult of
                        ok ->
                            commit_result(Issue, Plan, File),
                            catch openpixie_guardian:post_check(self_improve, Args, #{success => true}),
                            broadcast_improvement(Issue),
                            #{success => true, issue => Issue, file => File, plan => Plan, created => true};
                        {error, CompileError} ->
                            #{success => false, error => compile_failed,
                              reason => CompileError,
                              file => File,
                              hint => <<"The new file was created but compilation failed. Use read_file to examine the broken code, then call self_improve again with a corrected edit to fix the compile error.">>}
                    end;
                {error, WriteReason} ->
                    #{success => false, error => write_failed, reason => iolist_to_binary(io_lib:format("~p", [WriteReason]))}
            end;
        {error, Reason} ->
            #{success => false, error => file_not_found, reason => iolist_to_binary(io_lib:format("~p", [Reason]))};
        {ok, Content} when IsNewFile ->
            #{success => false, error => <<"File already exists. Use old_string and new_string to edit it, or delete it first.">>};
        {ok, Content} ->
            case binary:match(Content, OldString) of
                nomatch ->
                    #{success => false, error => <<"old_string not found in file">>};
                _ ->
                    case count_occurrences(Content, OldString) of
                        N when N > 1 ->
                            #{success => false, error => <<"old_string appears multiple times in file">>, count => N};
                        _ ->
                            NewContent = binary:replace(Content, OldString, NewString),
                            case file:write_file(FullPath, NewContent) of
                                ok ->
                                    CompileResult = compile_and_check(File, FullPath),
                                    case CompileResult of
                                        ok ->
                                            commit_result(Issue, Plan, File),
                                            catch openpixie_guardian:post_check(self_improve, Args, #{success => true}),
                                            broadcast_improvement(Issue),
                                            #{success => true, issue => Issue, file => File, plan => Plan};
                                        {error, CompileError} ->
                                            #{success => false, error => compile_failed,
                                              reason => CompileError,
                                              file => File,
                                              hint => <<"The edit was applied but compilation failed. Use read_file to examine the broken code, then call self_improve again with a corrected edit to fix the compile error.">>}
                                    end;
                                {error, WriteReason} ->
                                    #{success => false, error => write_failed, reason => iolist_to_binary(io_lib:format("~p", [WriteReason]))}
                            end
                    end
            end
    end.

count_occurrences(Content, Pattern) ->
    case binary:match(Content, Pattern) of
        nomatch -> 0;
        {Pos, _} ->
            Rest = binary:part(Content, Pos + byte_size(Pattern), byte_size(Content) - Pos - byte_size(Pattern)),
            1 + count_occurrences(Rest, Pattern)
    end.

compile_and_check(File, FullPath) ->
    Ws = openpixie_config:workspace(),
    EbinDir = filename:join(Ws, "ebin"),
    ok = filelib:ensure_dir(filename:join(EbinDir, "dummy")),
    Ext = filename:extension(FullPath),
    case Ext of
        ".erl" ->
            compile_erlang(File, FullPath, EbinDir);
        _ ->
            %% Non-Erlang files don't need compilation, just verify the file exists
            case filelib:is_file(FullPath) of
                true -> ok;
                false -> {error, <<"File was not created successfully.">>}
            end
    end.

compile_erlang(File, FullPath, EbinDir) ->
    case compile:file(FullPath, [{outdir, EbinDir}, return_errors]) of
        {ok, ModuleName} ->
            case openpixie_tools_self:load_compiled_module_ex(ModuleName, EbinDir, File) of
                ok -> ok;
                {error, LoadErr} -> {error, LoadErr}
            end;
        {error, Errors, _Warnings} ->
            ErrBin = safe_iolist_to_binary([io_lib:format("~p~n", [E]) || E <- Errors]),
            {error, <<"Compilation failed: ", ErrBin/binary>>};
        {error, Errors} ->
            ErrBin = safe_iolist_to_binary([io_lib:format("~p~n", [E]) || E <- Errors]),
            {error, <<"Compilation failed: ", ErrBin/binary>>}
    end.

safe_iolist_to_binary(IoList) ->
    case catch iolist_to_binary(IoList) of
        {'EXIT', _} -> unicode:characters_to_binary(IoList, utf8);
        Bin when is_binary(Bin) -> Bin
    end.

commit_result(Issue, Plan, File) ->
    Msg = iolist_to_binary(["self-improve: ", Issue, " - ", Plan]),
    CommitArgs = #{<<"message">> => Msg, <<"files">> => [File]},
    openpixie_tools_git:git_commit(CommitArgs),
    record_improvement(Issue, Plan).

record_improvement(Issue, Plan) ->
    Path = openpixie_config:improvements_path(),
    Entry = #{
        <<"problem">> => Issue,
        <<"root_cause">> => <<"identified_during_self_improve">>,
        <<"solution">> => Plan,
        <<"outcome">> => <<"applied">>,
        <<"triggered_by">> => <<"schedule">>,
        <<"timestamp">> => erlang:system_time(millisecond)
    },
    ok = filelib:ensure_dir(Path),
    Line = <<(iolist_to_binary(jsx:encode(Entry)))/binary, "\n">>,
    file:write_file(Path, Line, [append]).

broadcast_improvement(Issue) ->
    TopicId = case get(topic_pid) of
        undefined -> undefined;
        TopicPid when is_pid(TopicPid) ->
            case catch openpixie_topic:get_id(TopicPid) of
                Id when is_binary(Id) -> Id;
                _ -> undefined
            end
    end,
    case TopicId of
        undefined -> ok;
        _ ->
            openpixie_push:notify(TopicId,
                iolist_to_binary([<<"\u2705 Self-improvement applied: ">>, Issue]),
                <<"system">>, <<"self_improve">>)
    end.
