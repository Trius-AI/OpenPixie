-module(openpixie_http_health).
-export([init/2]).

init(Req, _State) ->
    {RuntimeMs, _} = erlang:statistics(runtime),
    OllamaStatus = case catch openpixie_ollama:list_models() of
        {ok, _} -> <<"up">>;
        _ -> <<"down">>
    end,
    TopicsCount = get_topics_count(),
    CbStatus = get_circuit_breaker_status(),
    MemoryInfo = get_memory_info(),
    ModulesCount = get_modules_count(),
    MetricsData = get_metrics_summary(),
    Body = jsx:encode(#{
        <<"status">> => <<"ok">>,
        <<"ollama">> => OllamaStatus,
        <<"uptime_seconds">> => RuntimeMs div 1000,
        <<"topics">> => #{
            <<"active_count">> => TopicsCount
        },
        <<"circuit_breaker">> => CbStatus,
        <<"memory">> => MemoryInfo,
        <<"modules">> => #{
            <<"loaded_count">> => ModulesCount
        },
        <<"metrics">> => MetricsData
    }),
    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, _State}.

get_topics_count() ->
    case catch openpixie_topic_store:list() of
        {ok, Topics} when is_list(Topics) -> length(Topics);
        _ -> 0
    end.

get_circuit_breaker_status() ->
    case catch openpixie_circuit_breaker:status() of
        #{state := State, failure_count := Count, last_failure := LastFailure} ->
            #{
                <<"state">> => atom_to_binary(State, utf8),
                <<"failure_count">> => Count,
                <<"last_failure_ts">> => LastFailure
            };
        _ ->
            #{<<"state">> => <<"unknown">>}
    end.

get_memory_info() ->
    case erlang:memory() of
        MemList when is_list(MemList) ->
            Total = proplists:get_value(total, MemList, 0),
            Processes = proplists:get_value(processes, MemList, 0),
            Binary = proplists:get_value(binary, MemList, 0),
            Ets = proplists:get_value(ets, MemList, 0),
            #{
                <<"total_bytes">> => Total,
                <<"processes_bytes">> => Processes,
                <<"binary_bytes">> => Binary,
                <<"ets_bytes">> => Ets
            };
        _ ->
            #{<<"total_bytes">> => 0}
    end.

get_modules_count() ->
    Modules = [M || {M, _} <- code:all_loaded(),
                    case atom_to_list(M) of
                        "openpixie" ++ _ -> true;
                        _ -> false
                    end],
    length(Modules).

get_metrics_summary() ->
    case catch openpixie_metrics:get_all_keys() of
        {ok, Keys} when is_list(Keys) ->
            Summaries = lists:map(fun(Key) ->
                case openpixie_metrics:get_statistics(Key) of
                    {ok, Stats} when is_map(Stats) ->
                        {Key, Stats};
                    _ ->
                        {Key, #{error => <<"unavailable">>}}
                end
            end, Keys),
            maps:from_list(Summaries);
        _ ->
            #{error => <<"metrics_unavailable">>}
    end.