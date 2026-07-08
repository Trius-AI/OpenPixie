-module(openpixie_guardian_test).

-include_lib("eunit/include/eunit.hrl").

%% Tests for the critical module hot-reload protection (self-reference guard).
%% These verify that Guardian rejects compile_and_reload / reload_module
%% on safety-layer modules (including Guardian itself).

guardian_test_() ->
    {setup,
        fun setup/0,
        fun cleanup/1,
        [
            fun is_guardian_relevant_for_critical_tools/0,
            fun pre_check_rejects_reload_guardian/0,
            fun pre_check_rejects_reload_auth/0,
            fun pre_check_rejects_reload_permissions/0,
            fun pre_check_rejects_compile_guardian_source/0,
            fun pre_check_allows_reload_non_critical/0,
            fun pre_check_allows_compile_non_critical/0
        ]
    }.

setup() ->
    {ok, Pid} = openpixie_guardian:start_link(),
    Pid.

cleanup(_Pid) ->
    try
        gen_server:stop(openpixie_guardian)
    catch
        _:_ -> ok
    end.

%% is_guardian_relevant should return true for compile_and_reload and reload_module
is_guardian_relevant_for_critical_tools() ->
    ?assertEqual(true, openpixie_guardian:is_guardian_relevant(<<"compile_and_reload">>, #{<<"path">> => <<"src/openpixie_topic.erl">>})),
    ?assertEqual(true, openpixie_guardian:is_guardian_relevant(<<"reload_module">>, #{<<"module">> => <<"openpixie_topic">>})).

%% reload_module on openpixie_guardian itself must be rejected
pre_check_rejects_reload_guardian() ->
    Result = openpixie_guardian:pre_check(<<"reload_module">>, #{<<"module">> => <<"openpixie_guardian">>}),
    ?assertMatch({reject, _}, Result).

%% reload_module on openpixie_auth must be rejected
pre_check_rejects_reload_auth() ->
    Result = openpixie_guardian:pre_check(<<"reload_module">>, #{<<"module">> => <<"openpixie_auth">>}),
    ?assertMatch({reject, _}, Result).

%% reload_module on openpixie_permissions must be rejected
pre_check_rejects_reload_permissions() ->
    Result = openpixie_guardian:pre_check(<<"reload_module">>, #{<<"module">> => <<"openpixie_permissions">>}),
    ?assertMatch({reject, _}, Result).

%% compile_and_reload on openpixie_guardian.erl must be rejected
pre_check_rejects_compile_guardian_source() ->
    Result = openpixie_guardian:pre_check(<<"compile_and_reload">>, #{<<"path">> => <<"src/openpixie_guardian.erl">>}),
    ?assertMatch({reject, _}, Result).

%% reload_module on a non-critical module should be allowed
pre_check_allows_reload_non_critical() ->
    Result = openpixie_guardian:pre_check(<<"reload_module">>, #{<<"module">> => <<"openpixie_topic">>}),
    ?assertEqual(ok, Result).

%% compile_and_reload on a non-critical module should be allowed
pre_check_allows_compile_non_critical() ->
    Result = openpixie_guardian:pre_check(<<"compile_and_reload">>, #{<<"path">> => <<"src/openpixie_topic.erl">>}),
    ?assertEqual(ok, Result).