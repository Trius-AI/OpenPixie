-module(openpixie_tools_cron).
-export([schema/0, schedule_message/1, schedule_prompt/1, list_schedules/1, cancel_schedule/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => schedule_message,
                description => <<"Schedule a recurring message to be sent to a conversation. The message will be delivered automatically at the specified interval. The schedule persists across restarts.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        topic_id => #{
                            type => string,
                            description => <<"The topic ID of the conversation to send the message to">>
                        },
                        content => #{
                            type => string,
                            description => <<"The message content to send">>
                        },
                        schedule => #{
                            type => string,
                            description => <<"When to send the message. Formats: 'daily:9' (every day at 9am), 'interval:30' (every 30 minutes), 'monthly:1' (on the 1st of each month), 'yearly:6:15' (June 15th)">>
                        },
                        name => #{
                            type => string,
                            description => <<"A unique name for this schedule (used to cancel it later). Defaults to auto-generated.">>
                        }
                    },
                    required => [topic_id, content, schedule]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => schedule_prompt,
                description => <<"Schedule a recurring agent prompt. At the specified time, the agent will create a fresh conversation, process the prompt there, and report results back to the specified topic. The agent runs autonomously with read-only access plus the self_improve tool for making one targeted code change. The schedule persists across restarts.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        topic_id => #{
                            type => string,
                            description => <<"The topic ID to report results to when the agent completes">>
                        },
                        prompt => #{
                            type => string,
                            description => <<"The prompt to send to the agent">>
                        },
                        schedule => #{
                            type => string,
                            description => <<"When to trigger the agent. Formats: 'daily:9' (every day at 9am), 'interval:30' (every 30 minutes), 'monthly:1' (on the 1st of each month), 'yearly:6:15' (June 15th)">>
                        },
                        name => #{
                            type => string,
                            description => <<"A unique name for this schedule (used to cancel it later). Defaults to auto-generated.">>
                        }
                    },
                    required => [topic_id, prompt, schedule]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => list_schedules,
                description => <<"List all scheduled message jobs.">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        },
        #{
            type => function,
            function => #{
                name => cancel_schedule,
                description => <<"Cancel a scheduled message job by name.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        name => #{
                            type => string,
                            description => <<"The name of the schedule to cancel">>
                        }
                    },
                    required => [name]
                }
            }
        }
    ].

schedule_message(Args) when is_map(Args) ->
    TopicId = maps:get(<<"topic_id">>, Args, maps:get(topic_id, Args, <<>>)),
    Content = maps:get(<<"content">>, Args, maps:get(content, Args, <<>>)),
    ScheduleBin = maps:get(<<"schedule">>, Args, maps:get(schedule, Args, <<>>)),
    Name0 = maps:get(<<"name">>, Args, maps:get(name, Args, undefined)),
    case TopicId of
        <<>> -> #{success => false, error => missing_topic_id};
        _ ->
            Name = case Name0 of
                undefined -> generate_name();
                N when is_binary(N) -> N
            end,
            NameAtom = try binary_to_existing_atom(Name, utf8) catch _:_ -> binary_to_atom(Name, utf8) end,
            Spec = openpixie_cron:binary_to_spec(ScheduleBin),
            MFA = {openpixie_push, notify, [TopicId, Content]},
            case openpixie_cron:add_job(NameAtom, Spec, MFA) of
                ok ->
                    openpixie_cron:save_scheduled_job(NameAtom, Spec, TopicId, Content, <<"message">>),
                    #{success => true, name => Name, schedule => ScheduleBin, topic_id => TopicId};
                {error, Reason} ->
                    #{success => false, error => schedule_failed, reason => iolist_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

schedule_prompt(Args) when is_map(Args) ->
    case get(triggered_by) of
        schedule -> #{success => false, error => <<"Cannot schedule prompts from within a scheduled prompt. Use schedule_message instead.">>};
        _ -> do_schedule_prompt(Args)
    end.

do_schedule_prompt(Args) ->
    TopicId = maps:get(<<"topic_id">>, Args, maps:get(topic_id, Args, <<>>)),
    Prompt = maps:get(<<"prompt">>, Args, <<>>),
    ScheduleBin = maps:get(<<"schedule">>, Args, maps:get(schedule, Args, <<>>)),
    Name0 = maps:get(<<"name">>, Args, maps:get(name, Args, undefined)),
    case {TopicId, Prompt, ScheduleBin} of
        {<<>>, _, _} -> #{success => false, error => missing_topic_id};
        {_, <<>>, _} -> #{success => false, error => missing_prompt};
        {_, _, <<>>} -> #{success => false, error => missing_schedule};
        _ ->
            Name = case Name0 of
                undefined -> generate_name();
                N when is_binary(N) -> N
            end,
            NameAtom = try binary_to_existing_atom(Name, utf8) catch _:_ -> binary_to_atom(Name, utf8) end,
            Spec = openpixie_cron:binary_to_spec(ScheduleBin),
            MFA = {openpixie_push, prompt, [TopicId, Prompt]},
            case openpixie_cron:add_job(NameAtom, Spec, MFA) of
                ok ->
                    openpixie_cron:save_scheduled_job(NameAtom, Spec, TopicId, Prompt, <<"prompt">>),
                    #{success => true, name => Name, schedule => ScheduleBin, topic_id => TopicId, type => <<"prompt">>};
                {error, Reason} ->
                    #{success => false, error => schedule_failed, reason => iolist_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

list_schedules(_Args) ->
    Jobs = openpixie_cron:list_jobs_info(),
    #{success => true, schedules => Jobs}.

cancel_schedule(Args) when is_map(Args) ->
    Name = maps:get(<<"name">>, Args, maps:get(name, Args, <<>>)),
    case Name of
        <<>> -> #{success => false, error => missing_name};
        _ ->
            NameAtom = try binary_to_existing_atom(Name, utf8) catch _:_ -> binary_to_atom(Name, utf8) end,
            openpixie_cron:remove_job(NameAtom),
            openpixie_cron:delete_scheduled_job(NameAtom),
            #{success => true, cancelled => Name}
    end.

generate_name() ->
    <<Int:64>> = crypto:strong_rand_bytes(8),
    <<"sched_", (integer_to_binary(Int, 36))/binary>>.