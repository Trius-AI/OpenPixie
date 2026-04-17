-module(openpixie_permissions_test).

-include_lib("eunit/include/eunit.hrl").

perm_test_() ->
    {setup,
        fun setup/0,
        fun cleanup/1,
        [
            fun trust_mode_allows_all/0,
            fun plan_mode_blocks_writes/0,
            fun sandbox_mode_blocks_self_mod/0
        ]
    }.

setup() ->
    {ok, Pid} = openpixie_permissions:start_link(),
    Pid.

cleanup(_Pid) ->
    catch gen_server:stop(openpixie_permissions).

trust_mode_allows_all() ->
    openpixie_permissions:set_mode(trust),
    ?assertEqual({allow, trust_mode}, openpixie_permissions:check(<<"read_file">>, #{})),
    ?assertEqual({allow, trust_mode}, openpixie_permissions:check(<<"write_file">>, #{})).

plan_mode_blocks_writes() ->
    openpixie_permissions:set_mode(plan),
    ?assertEqual({allow, plan_readonly}, openpixie_permissions:check(<<"read_file">>, #{})),
    ?assertEqual({deny, plan_mode}, openpixie_permissions:check(<<"write_file">>, #{})).

sandbox_mode_blocks_self_mod() ->
    openpixie_permissions:set_mode(sandbox),
    ?assertEqual({allow, sandbox_readonly}, openpixie_permissions:check(<<"read_file">>, #{})),
    ?assertEqual({deny, sandbox_self_mod}, openpixie_permissions:check(<<"reload_module">>, #{})).