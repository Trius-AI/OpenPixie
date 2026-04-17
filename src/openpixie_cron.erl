-module(openpixie_cron).
-behaviour(gen_server).

-export([start_link/0, add_job/3, remove_job/1, list_jobs/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CRON_TABLE, openpixie_cron_jobs).
-define(CHECK_INTERVAL, 60000).

-record(cron_job, {
    name :: atom(),
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
    timer:send_interval(?CHECK_INTERVAL, cron_tick),
    {ok, #{}}.

add_job(Name, Spec, MFA) ->
    gen_server:call(?SERVER, {add_job, Name, Spec, MFA}).

remove_job(Name) ->
    gen_server:call(?SERVER, {remove_job, Name}).

list_jobs() ->
    ets:tab2list(?CRON_TABLE).

register_default_jobs() ->
    DayJob = #cron_job{name = day_condense, spec = {daily, 23}, mfargs = {openpixie_memory, condense_day, []}},
    ReflectHour = openpixie_config:reflection_hour(),
    ReflectJob = #cron_job{name = daily_reflection, spec = {daily, ReflectHour}, mfargs = {openpixie_reflection, reflect, []}},
    ArchiveJob = #cron_job{name = archive_idle_topics, spec = {daily, 2}, mfargs = {openpixie_topic_store, archive_idle, []}},
    ets:insert(?CRON_TABLE, {day_condense, DayJob}),
    ets:insert(?CRON_TABLE, {daily_reflection, ReflectJob}),
    ets:insert(?CRON_TABLE, {archive_idle_topics, ArchiveJob}),
    ok.

handle_call({add_job, Name, Spec, MFA}, _From, State) ->
    Job = #cron_job{name = Name, spec = Spec, mfargs = MFA},
    ets:insert(?CRON_TABLE, {Name, Job}),
    {reply, ok, State};

handle_call({remove_job, Name}, _From, State) ->
    ets:delete(?CRON_TABLE, Name),
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