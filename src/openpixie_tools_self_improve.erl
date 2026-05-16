-module(openpixie_tools_self_improve).
-export([schema/0, run/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => self_improve,
                description => <<"Apply a targeted self-improvement change. This is the ONLY way to modify code or configuration in scheduled mode. Each call makes exactly one edit, compiles it, verifies the system is healthy, and records the change. Only ONE self-improvement is allowed per scheduled run.">>,
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
                            description => <<"Path to the file to edit, relative to workspace (e.g. 'src/openpixie_ws.erl').">>
                        },
                        old_string => #{
                            type => string,
                            description => <<"The exact text in the file that you want to replace. Must be unique in the file.">>
                        },
                        new_string => #{
                            type => string,
                            description => <<"The replacement text.">>
                        }
                    },
                    required => [issue, plan, file, old_string, new_string]
                }
            }
        }
    ].

run(Args) when is_map(Args) ->
    case get(self_improve_used) of
        true ->
            #{success => false, error => <<"Only one self-improvement is allowed per scheduled run.">>};
        _ ->
            do_improve(Args)
    end.

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
    OldString = maps:get(<<"old_string">>, Args),
    NewString = maps:get(<<"new_string">>, Args),
    FullPath = filename:join(openpixie_config:workspace(), binary_to_list(File)),
    case file:read_file(FullPath) of
        {error, Reason} ->
            #{success => false, error => file_not_found, reason => iolist_to_binary(io_lib:format("~p", [Reason]))};
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
                                            put(self_improve_used, true),
                                            catch openpixie_guardian:post_check(self_improve, Args, #{success => true}),
                                            broadcast_improvement(Issue),
                                            #{success => true, issue => Issue, file => File, plan => Plan};
                                        {error, CompileError} ->
                                            file:write_file(FullPath, Content),
                                            #{success => false, error => compile_failed, reason => CompileError}
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

compile_and_check(File, _FullPath) ->
    CompileArgs = #{<<"file">> => File},
    case openpixie_tools_self:compile_and_reload(CompileArgs) of
        #{success := true} ->
            ok;
        #{success := false} = Error ->
            Reason = maps:get(error, Error, <<"unknown compile error">>),
            {error, Reason};
        Error ->
            {error, iolist_to_binary(io_lib:format("~p", [Error]))}
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