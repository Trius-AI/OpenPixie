-module(openpixie_circuit_breaker_test).

-include_lib("eunit/include/eunit.hrl").

cb_test_() ->
    {setup,
        fun setup/0,
        fun cleanup/1,
        [
            fun closed_allows_call/0,
            fun open_blocks_call/0
        ]
    }.

setup() ->
    {ok, Pid} = openpixie_circuit_breaker:start_link(),
    Pid.

cleanup(_Pid) ->
    catch gen_server:stop(openpixie_circuit_breaker).

closed_allows_call() ->
    openpixie_circuit_breaker:reset(),
    Result = openpixie_circuit_breaker:call(fun() -> {ok, hello} end),
    ?assertEqual({ok, hello}, Result).

open_blocks_call() ->
    openpixie_circuit_breaker:reset(),
    MaxFailures = openpixie_config:circuit_breaker_failures(),
    lists:foreach(fun(_) ->
        openpixie_circuit_breaker:call(fun() -> {error, test_failure} end)
    end, lists:seq(1, MaxFailures)),
    Result = openpixie_circuit_breaker:call(fun() -> {ok, hello} end),
    ?assertEqual({error, circuit_open}, Result).