-module(openpixie_auth_test).

-include_lib("eunit/include/eunit.hrl").

auth_test_() ->
    {setup,
        fun setup/0,
        fun cleanup/1,
        [
            fun generate_key_works/0,
            fun authenticate_valid_key/0,
            fun authenticate_invalid_key/0
        ]
    }.

setup() ->
    {ok, Pid} = openpixie_auth:start_link(),
    Pid.

cleanup(_Pid) ->
    catch gen_server:stop(openpixie_auth).

generate_key_works() ->
    {Key, Hash} = openpixie_auth:generate_key(),
    ?assert(is_binary(Key)),
    ?assert(is_binary(Hash)).

authenticate_valid_key() ->
    {Key, _Hash} = openpixie_auth:generate_key(),
    ok = openpixie_auth:setup_key(Key),
    ?assertEqual({ok, master}, openpixie_auth:authenticate(Key)).

authenticate_invalid_key() ->
    ?assertEqual({error, invalid_key}, openpixie_auth:authenticate(<<"wrong-key">>)).