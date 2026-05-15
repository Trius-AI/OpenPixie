-module(openpixie_metrics).
-behaviour(gen_server).

-export([start_link/0, record/3, get_trend/1, get_trend/2, get_statistics/1,
         get_all_keys/0, get_recent/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(METRICS_TABLE, openpixie_metrics).
-define(CLEANUP_INTERVAL_MS, 3600000). % 1 hour
-define(MAX_AGE_MS, 86400000). % 24 hours

-record(state, {cleanup_timer :: reference() | undefined}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ets:new(?METRICS_TABLE, [named_table, public, ordered_set]),
    {ok, #state{}}.

record(Key, Value, Metadata) when is_binary(Key) ->
    Ts = erlang:system_time(millisecond),
    Entry = #{key => Key, value => Value, timestamp => Ts, metadata => Metadata},
    ets:insert(?METRICS_TABLE, {{Key, Ts}, Entry}),
    {ok, Ts}.

get_trend(Key) ->
    get_trend(Key, 5).

get_trend(Key, Window) when is_binary(Key) ->
    Now = erlang:system_time(millisecond),
    Entries = ets:select(?METRICS_TABLE, [
        {{{Key, '$1'}, '$2'}, [{'>=', '$1', {const, Now - Window * 60000}}],
         ['$_']}
    ]),
    OlderCutoff = Now - Window * 2 * 60000,
    OlderEntries = ets:select(?METRICS_TABLE, [
        {{{Key, '$1'}, '$2'}, [{'>=', '$1', {const, OlderCutoff}}, {'<', '$1', {const, Now - Window * 60000}}],
         ['$_']}
    ]),
    case {Entries, OlderEntries} of
        {[], _} -> {ok, no_data};
        {_, []} -> {ok, insufficient_history};
        {Recent, Older} ->
            RecentAvg = avg_values(Recent),
            OlderAvg = avg_values(Older),
            Trend = RecentAvg - OlderAvg,
            {ok, #{trend => Trend, recent_avg => RecentAvg, older_avg => OlderAvg,
                   recent_count => length(Recent), older_count => length(Older)}}
    end.

get_statistics(Key) when is_binary(Key) ->
    Entries = ets:select(?METRICS_TABLE, [
        {{{Key, '_'}, '$1'}, [], ['$1']}
    ]),
    case Entries of
        [] -> {ok, no_data};
        _ ->
            Values = [maps:get(value, E) || E <- Entries],
            {ok, #{
                count => length(Values),
                min => lists:min(Values),
                max => lists:max(Values),
                avg => lists:sum(Values) / length(Values)
            }}
    end.

get_all_keys() ->
    MatchSpec = [{{{'$1', '_'}, '_'}, [], ['$1']}],
    Keys = ets:select(?METRICS_TABLE, MatchSpec),
    {ok, lists:usort(Keys)}.

get_recent(Key, N) when is_binary(Key), is_integer(N) ->
    Entries = ets:select(?METRICS_TABLE, [
        {{{Key, '_'}, '$1'}, [], ['$1']}
    ]),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(timestamp, A) > maps:get(timestamp, B)
    end, Entries),
    {ok, lists:sublist(Sorted, N)}.

avg_values(Entries) ->
    Values = [maps:get(value, E) || E <- Entries],
    case Values of
        [] -> 0;
        _ -> lists:sum(Values) / length(Values)
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.