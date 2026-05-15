-module(openpixie_tools_cron).
-export([schema/0, add_cron_job/1, remove_cron_job/1, list_cron_jobs/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => add_cron_job,
                description => <<"Schedule a recurring cron job">>,
                parameters => #{
                    type => object,
                    properties => #{
                        name => #{type => string, description => <<"Unique name for this job">>},
                        spec_type => #{type => string, description => <<"Cron spec type: 'interval', 'daily', 'monthly', or 'yearly'">>},
                        spec_value => #{type => string, description => <<"For interval: minutes (e.g. '5'), for daily: hour (0-23), for monthly: day (1-31), for yearly: 'month:day' format">>},
                        action_type => #{type => string, description => <<"Action to perform: 'push_message'">>},
                        topic_id => #{type => string, description => <<"Topic ID to push message to (required for push_message action)">>},
                        message => #{type => string, description => <<"Message content to send (required for push_message action)">>}
                    },
                    required => [name, spec_type, spec_value, action_type]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => remove_cron_job,
                description => <<"Remove a scheduled cron job">>,
                parameters => #{
                    type => object,
                    properties => #{
                        name => #{type => string, description => <<"Name of the job to remove">>}
                    },
                    required => [name]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => list_cron_jobs,
                description => <<"List all scheduled cron jobs">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        }
    ].

add_cron_job(Args) ->
    NameBin = maps:get(<<"name">>, Args),
    SpecType = maps:get(<<"spec_type">>, Args),
    SpecValue = maps:get(<<"spec_value">>, Args),
    ActionType = maps:get(<<"action_type">>, Args),

    Name = binary_to_atom(NameBin, utf8),

    Spec = parse_spec(SpecType, SpecValue),
    MFA = build_mfa(ActionType, Args),

    case openpixie_cron:add_job(Name, Spec, MFA) of
        ok -> #{success => true, message => <<"Cron job added successfully">>};
        Error -> #{success => false, error => Error}
    end.

remove_cron_job(Args) ->
    NameBin = maps:get(<<"name">>, Args),
    Name = binary_to_atom(NameBin, utf8),
    case openpixie_cron:remove_job(Name) of
        ok -> #{success => true, message => <<"Cron job removed successfully">>};
        Error -> #{success => false, error => Error}
    end.

list_cron_jobs(_Args) ->
    Jobs = openpixie_cron:list_jobs(),
    #{
        success => true,
        jobs => [format_job(Job) || Job <- Jobs]
    }.

parse_spec(<<"interval">>, ValueBin) ->
    Minutes = binary_to_integer(ValueBin),
    {interval, Minutes};
parse_spec(<<"daily">>, ValueBin) ->
    Hour = binary_to_integer(ValueBin),
    {daily, Hour};
parse_spec(<<"monthly">>, ValueBin) ->
    Day = binary_to_integer(ValueBin),
    {monthly, Day};
parse_spec(<<"yearly">>, ValueBin) ->
    [MonthBin, DayBin] = binary:split(ValueBin, <<":">>),
    Month = binary_to_integer(MonthBin),
    Day = binary_to_integer(DayBin),
    {yearly, Month, Day}.

build_mfa(<<"push_message">>, Args) ->
    TopicId = maps:get(<<"topic_id">>, Args),
    Message = maps:get(<<"message">>, Args),
    {openpixie_push, notify, [TopicId, Message]}.

format_job({Name, #{} = Job}) ->
    #{
        name => Name,
        spec => format_spec(Job),
        last_run => maps:get(last_run, Job, undefined)
    };
format_job({Name, Job}) when is_tuple(Job) ->
    %% Record format
    #{
        name => Name,
        spec => format_spec_tuple(Job),
        last_run => undefined
    }.

format_spec(_Job) ->
    <<"unknown">>.

format_spec_tuple(#cron_job{spec = Spec}) ->
    format_cron_spec(Spec);
format_spec_tuple(Record) when is_tuple(Record) ->
    %% It's a cron_job record, extract spec from element 3
    format_cron_spec(element(3, Record)).

format_cron_spec({interval, Mins}) ->
    #{type => <<"interval">>, minutes => Mins};
format_cron_spec({daily, Hour}) ->
    #{type => <<"daily">>, hour => Hour};
format_cron_spec({monthly, Day}) ->
    #{type => <<"monthly">>, day => Day};
format_cron_spec({yearly, Month, Day}) ->
    #{type => <<"yearly">>, month => Month, day => Day}.