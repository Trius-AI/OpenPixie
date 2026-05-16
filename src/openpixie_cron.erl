-module(openpixie_cron).
-behaviour(gen_server).

-export([start_link/0, add_job/3, remove_job/1, list_jobs/0, list_jobs_info/0,
         binary_to_spec/1, save_scheduled_job/4, save_scheduled_job/5, delete_scheduled_job/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CRON_TABLE, openpixie_cron_jobs).
-define(CHECK_INTERVAL, 60000).

-record(cron_job, {
    name :: atom() | binary(),
    spec :: cron_spec(),
    mfargs :: {atom(), atom(), [term()]},
    last_run :: integer() | undefined
}).

-type cron_spec() :: {daily, Hour :: 0..23} |
                     {interval, Minutes :: pos_integer()} |
                     {monthly, Day :: 1..31} |
                     {yearly, Month :: 1..12, Day :: 1..31}.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ets:new(?CRON_TABLE, [named_table, public, set]),
    register_default_jobs(),
    restore_scheduled_jobs(),
    timer:send_interval(?CHECK_INTERVAL, cron_tick),
    {ok, #{}}.

add_job(Name, Spec, MFA) when is_binary(Name) ->
    add_job(binary_to_existing_atom(Name, utf8), Spec, MFA);
add_job(Name, Spec, MFA) when is_atom(Name) ->
    gen_server:call(?SERVER, {add_job, Name, Spec, MFA}).

remove_job(Name) when is_binary(Name) ->
    remove_job(binary_to_existing_atom(Name, utf8));
remove_job(Name) when is_atom(Name) ->
    gen_server:call(?SERVER, {remove_job, Name}).

list_jobs() ->
    ets:tab2list(?CRON_TABLE).

list_jobs_info() ->
    Jobs = ets:tab2list(?CRON_TABLE),
    lists:filtermap(fun
        ({_, #cron_job{name = Name, spec = Spec, mfargs = {M, F, A}}}) ->
            case is_atom(Name) andalso (Name =:= day_condense orelse Name =:= daily_reflection orelse Name =:= archive_idle_topics) of
                true -> false;
                false ->
                    {true, #{
                        name => atom_to_binary(Name, utf8),
                        spec => spec_to_binary(Spec),
                        module => atom_to_binary(M, utf8),
                        function => atom_to_binary(F, utf8),
                        args => A,
                        last_run => case ets:lookup(?CRON_TABLE, {last_run, Name}) of
                            [{{last_run, Name}, T}] -> T;
                            [] -> null
                        end
                    }}
            end;
        (_) -> false
    end, Jobs).

register_default_jobs() ->
    DayJob = #cron_job{name = day_condense, spec = {daily, 23}, mfargs = {openpixie_memory, condense_day, []}},
    ReflectHour = openpixie_config:reflection_hour(),
    ReflectJob = #cron_job{name = daily_reflection, spec = {daily, ReflectHour}, mfargs = {openpixie_reflection, reflect, []}},
    ArchiveJob = #cron_job{name = archive_idle_topics, spec = {daily, 2}, mfargs = {openpixie_topic_store, archive_idle, []}},
    ets:insert(?CRON_TABLE, {day_condense, DayJob}),
    ets:insert(?CRON_TABLE, {daily_reflection, ReflectJob}),
    ets:insert(?CRON_TABLE, {archive_idle_topics, ArchiveJob}),
    ok.

restore_scheduled_jobs() ->
    SchedDir = filename:join(openpixie_config:pixie_dir(), "schedules"),
    case filelib:is_dir(SchedDir) of
        false -> ok;
        true ->
            case file:list_dir(SchedDir) of
                {ok, Files} ->
                    lists:foreach(fun(F) ->
                        case filename:extension(F) of
                            ".json" ->
                                Path = filename:join(SchedDir, F),
                                case file:read_file(Path) of
                                    {ok, Bin} ->
                                        try jsx:decode(Bin, [return_maps]) of
                                            Job ->
                                                Name = binary_to_existing_atom(maps:get(<<"name">>, Job), utf8),
                                                Spec = binary_to_spec(maps:get(<<"spec">>, Job)),
                                                TopicId = maps:get(<<"topic_id">>, Job),
                                                Content = maps:get(<<"content">>, Job),
                                                JobType = maps:get(<<"type">>, Job, <<"message">>),
                                                MFA = case JobType of
                                                    <<"prompt">> -> {openpixie_push, prompt, [TopicId, Content]};
                                                    _ -> {openpixie_push, notify, [TopicId, Content]}
                                                end,
                                                JobRecord = #cron_job{name = Name, spec = Spec, mfargs = MFA},
                                                ets:insert(?CRON_TABLE, {Name, JobRecord})
                                        catch _:_ -> ok
                                        end;
                                    _ -> ok
                                end;
                            _ -> ok
                        end
                    end, Files);
                _ -> ok
            end
    end.

save_scheduled_job(Name, Spec, TopicId, Content) ->
    save_scheduled_job(Name, Spec, TopicId, Content, <<"message">>).

save_scheduled_job(Name, Spec, TopicId, Content, Type) ->
    SchedDir = filename:join(openpixie_config:pixie_dir(), "schedules"),
    ok = filelib:ensure_dir(filename:join(SchedDir, "dummy")),
    Filename = <<(atom_to_binary(Name, utf8))/binary, ".json">>,
    Path = filename:join(SchedDir, Filename),
    JobData = #{
        name => atom_to_binary(Name, utf8),
        spec => spec_to_binary(Spec),
        topic_id => TopicId,
        content => Content,
        type => Type
    },
    file:write_file(Path, jsx:encode(JobData)).

delete_scheduled_job(Name) ->
    SchedDir = filename:join(openpixie_config:pixie_dir(), "schedules"),
    Filename = <<(atom_to_binary(Name, utf8))/binary, ".json">>,
    Path = filename:join(SchedDir, Filename),
    file:delete(Path).

handle_call({add_job, Name, Spec, MFA}, _From, State) ->
    Job = #cron_job{name = Name, spec = Spec, mfargs = MFA},
    ets:insert(?CRON_TABLE, {Name, Job}),
    {reply, ok, State};

handle_call({remove_job, Name}, _From, State) ->
    ets:delete(?CRON_TABLE, Name),
    ets:delete(?CRON_TABLE, {last_run, Name}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cron_tick, State) ->
    Now = erlang:localtime(),
    Jobs = ets:tab2list(?CRON_TABLE),
    lists:foreach(fun({_Name, Job}) ->
        case should_run(Job, Now) of
            true -> run_job(Job);
            false -> ok
        end
    end, Jobs),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

should_run(#cron_job{spec = {daily, Hour}}, {{_, _, _}, {H, Min, _}}) ->
    H =:= Hour andalso Min < 1;
should_run(#cron_job{name = Name, spec = {interval, Minutes}}, _Now) ->
    case ets:lookup(?CRON_TABLE, {last_run, Name}) of
        [{{last_run, Name}, LastRun}] ->
            (erlang:system_time(second) - LastRun) >= Minutes * 60;
        [] ->
            true
    end;
should_run(#cron_job{spec = {monthly, Day}}, {{_, _Mo, D}, {H, Min, _}}) ->
    D =:= Day andalso H =:= 0 andalso Min < 1;
should_run(#cron_job{spec = {yearly, Month, Day}}, {{_, Mo, D}, {H, Min, _}}) ->
    Mo =:= Month andalso D =:= Day andalso H =:= 0 andalso Min < 1;
should_run(_, _Now) ->
    false.

run_job(#cron_job{name = Name, mfargs = {M, F, A}}) ->
    spawn(fun() ->
        try apply(M, F, A) of
            _ -> ok
        catch
            _:Reason ->
                openpixie_log:error("Cron job ~p failed: ~p", [Name, Reason])
        end
    end),
    ets:insert(?CRON_TABLE, {{last_run, Name}, erlang:system_time(second)}).

spec_to_binary({daily, Hour}) -> <<"daily:", Hour/integer>>;
spec_to_binary({interval, Minutes}) -> <<"interval:", (integer_to_binary(Minutes))/binary>>;
spec_to_binary({monthly, Day}) -> <<"monthly:", Day/integer>>;
spec_to_binary({yearly, Month, Day}) -> iolist_to_binary([<<"yearly:">>, integer_to_binary(Month), <<":">>, integer_to_binary(Day)]);
spec_to_binary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

binary_to_spec(<<"daily:", H/binary>>) -> {daily, binary_to_integer(H)};
binary_to_spec(<<"interval:", M/binary>>) -> {interval, binary_to_integer(M)};
binary_to_spec(<<"monthly:", D/binary>>) -> {monthly, binary_to_integer(D)};
binary_to_spec(<<"yearly:", Rest/binary>>) ->
    [M, D] = binary:split(Rest, <<":">>),
    {yearly, binary_to_integer(M), binary_to_integer(D)};
binary_to_spec(Other) -> {interval, 60}.