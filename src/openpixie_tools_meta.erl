-module(openpixie_tools_meta).
-export([schema/0, get_system_status/1, get_performance_trend/1, get_improvements/1,
         save_snapshot/1, list_snapshots/1, load_snapshot/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => get_system_status,
                description => <<"Get comprehensive system status including health, metrics, and circuit breaker state">>,
                parameters => #{
                    type => object,
                    properties => #{},
                    required => []
                }
            }
        },
        #{
            type => function,
            function => #{
                name => get_performance_trend,
                description => <<"Get performance trend for a tracked metric">>,
                parameters => #{
                    type => object,
                    properties => #{
                        key => #{type => string, description => <<"Metric key to trend">>},
                        window => #{type => integer, description => <<"Window size in data points (default 5)">>}
                    },
                    required => [key]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => get_improvements,
                description => <<"Read the IMPROVEMENTS.md log of past improvement attempts">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        },
        #{
            type => function,
            function => #{
                name => save_snapshot,
                description => <<"Save an archive snapshot of current SOUL.md and source code as a stepping stone">>,
                parameters => #{
                    type => object,
                    properties => #{
                        label => #{type => string, description => <<"Label for this snapshot">>},
                        metadata => #{type => object, description => <<"Optional metadata about this snapshot">>}
                    },
                    required => [label]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => list_snapshots,
                description => <<"List all archive snapshots, optionally filtered by label">>,
                parameters => #{
                    type => object,
                    properties => #{
                        label => #{type => string, description => <<"Optional label filter">>}
                    },
                    required => []
                }
            }
        },
        #{
            type => function,
            function => #{
                name => load_snapshot,
                description => <<"Load a snapshot's SOUL.md and metadata from the archive">>,
                parameters => #{
                    type => object,
                    properties => #{
                        id => #{type => string, description => <<"Snapshot ID">>}
                    },
                    required => [id]
                }
            }
        }
    ].

get_system_status(_) ->
    {RuntimeMs, _} = erlang:statistics(runtime),
    OllamaStatus = case catch openpixie_ollama:list_models() of
        {ok, _} -> <<"up">>;
        _ -> <<"down">>
    end,
    TopicsCount = case catch openpixie_topic_store:list() of
        {ok, Topics} when is_list(Topics) -> length(Topics);
        _ -> 0
    end,
    CbStatus = case catch openpixie_circuit_breaker:status() of
        #{state := State, failure_count := Count, last_failure := LastFailure} ->
            #{state => atom_to_binary(State, utf8), failure_count => Count, last_failure_ts => LastFailure};
        _ -> #{state => <<"unknown">>}
    end,
    MemoryInfo = case erlang:memory() of
        MemList when is_list(MemList) ->
            #{
                total_bytes => proplists:get_value(total, MemList, 0),
                processes_bytes => proplists:get_value(processes, MemList, 0),
                binary_bytes => proplists:get_value(binary, MemList, 0),
                ets_bytes => proplists:get_value(ets, MemList, 0)
            };
        _ -> #{total_bytes => 0}
    end,
    MetricsData = case catch openpixie_metrics:get_all_keys() of
        {ok, Keys} when is_list(Keys) ->
            Summaries = lists:map(fun(Key) ->
                case openpixie_metrics:get_statistics(Key) of
                    {ok, Stats} when is_map(Stats) -> {Key, Stats};
                    _ -> {Key, #{error => <<"unavailable">>}}
                end
            end, Keys),
            maps:from_list(Summaries);
        _ -> #{}
    end,
    #{
        success => true,
        status => #{
            ollama => OllamaStatus,
            uptime_seconds => RuntimeMs div 1000,
            topics_count => TopicsCount,
            circuit_breaker => CbStatus,
            memory => MemoryInfo,
            metrics => MetricsData
        }
    }.

get_performance_trend(Args) ->
    Key = maps:get(<<"key">>, Args, maps:get(key, Args, undefined)),
    WindowVal = maps:get(<<"window">>, Args, maps:get(window, Args, 5)),
    Window = case is_integer(WindowVal) of true -> WindowVal; false -> catch binary_to_integer(WindowVal) end,
    WindowInt = case is_integer(Window) of true -> Window; false -> 5 end,
    case Key of
        undefined -> #{success => false, error => missing_key};
        _ ->
            case openpixie_metrics:get_trend(Key, WindowInt) of
                {ok, no_data} -> #{success => true, trend => no_data};
                {ok, insufficient_history} -> #{success => true, trend => insufficient_history};
                {ok, Result} -> #{success => true, trend => Result};
                {error, Reason} -> #{success => false, error => Reason}
            end
    end.

get_improvements(_) ->
    case openpixie_reflection:read_improvements() of
        {ok, Improvements} -> #{success => true, improvements => Improvements};
        {error, Reason} -> #{success => false, error => Reason}
    end.

save_snapshot(Args) ->
    Label = maps:get(<<"label">>, Args, maps:get(label, Args, <<"snapshot">>)),
    MetadataRaw = maps:get(<<"metadata">>, Args, maps:get(metadata, Args, #{})),
    Metadata = case MetadataRaw of
        M when is_map(M) -> M;
        B when is_binary(B) ->
            case jsx:is_json(B) of
                true -> jsx:decode(B, [return_maps]);
                false -> #{<<"note">> => B}
            end
    end,
    case openpixie_archive:save_snapshot(Label, Metadata) of
        {ok, Result} -> #{success => true, snapshot => Result};
        {error, Reason} -> #{success => false, error => Reason}
    end.

list_snapshots(Args) ->
    Label = maps:get(<<"label">>, Args, maps:get(label, Args, undefined)),
    case Label of
        undefined ->
            case openpixie_archive:list_snapshots() of
                {ok, Snapshots} -> #{success => true, snapshots => Snapshots};
                {error, Reason} -> #{success => false, error => Reason}
            end;
        <<>> ->
            case openpixie_archive:list_snapshots() of
                {ok, Snapshots} -> #{success => true, snapshots => Snapshots};
                {error, Reason} -> #{success => false, error => Reason}
            end;
        _ ->
            case openpixie_archive:list_snapshots(Label) of
                {ok, Snapshots} -> #{success => true, snapshots => Snapshots};
                {error, Reason} -> #{success => false, error => Reason}
            end
    end.

load_snapshot(Args) ->
    Id = maps:get(<<"id">>, Args, maps:get(id, Args, <<"">>)),
    case openpixie_archive:load_snapshot(Id) of
        {ok, Result} -> #{success => true, snapshot => Result};
        {error, not_found} -> #{success => false, error => snapshot_not_found};
        {error, Reason} -> #{success => false, error => Reason}
    end.