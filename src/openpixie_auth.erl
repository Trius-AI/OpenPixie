-module(openpixie_auth).
-behaviour(gen_server).

-export([start_link/0, authenticate/1, generate_key/0, get_key_hash/0, setup_key/1, setup_key_from_hash/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(KEY_TABLE, openpixie_api_keys).

-record(state, {keys = []}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ets:new(?KEY_TABLE, [named_table, public, set]),
    case application:get_env(openpixie, api_key_hash) of
        {ok, HashStr} when is_binary(HashStr) ->
            try
                Hash = hex_decode(HashStr),
                ets:insert(?KEY_TABLE, {master, Hash})
            catch
                _:_ ->
                    ets:insert(?KEY_TABLE, {master, HashStr})
            end;
        _ -> ok
    end,
    {ok, #state{}}.

authenticate(ApiKey) when is_binary(ApiKey) ->
    Hash = crypto:hash(sha256, ApiKey),
    case ets:lookup(?KEY_TABLE, master) of
        [{master, StoredHash}] ->
            case Hash =:= StoredHash of
                true -> {ok, master};
                false -> {error, invalid_key}
            end;
        [] ->
            {error, no_key_configured}
    end.

generate_key() ->
    RandBytes = crypto:strong_rand_bytes(32),
    Key = string:lowercase(binary:encode_hex(RandBytes)),
    Hash = crypto:hash(sha256, Key),
    HashStr = string:lowercase(binary:encode_hex(Hash)),
    {Key, HashStr}.

setup_key(Key) when is_binary(Key) ->
    Hash = crypto:hash(sha256, Key),
    HashStr = binary:encode_hex(Hash),
    application:set_env(openpixie, api_key_hash, HashStr),
    try
        ets:insert(?KEY_TABLE, {master, Hash}),
        ok
    catch
        error:badarg -> ok
    end.

setup_key_from_hash(HashHex) when is_binary(HashHex) ->
    application:set_env(openpixie, api_key_hash, HashHex),
    try
        Hash = hex_decode(HashHex),
        ets:insert(?KEY_TABLE, {master, Hash}),
        ok
    catch
        _:_ -> ok
    end.

get_key_hash() ->
    case ets:lookup(?KEY_TABLE, master) of
        [{master, Hash}] -> {ok, binary:encode_hex(Hash)};
        [] -> undefined
    end.

handle_call({setup_key, Hash}, _From, State) ->
    ets:insert(?KEY_TABLE, {master, Hash}),
    application:set_env(openpixie, api_key_hash, binary:encode_hex(Hash)),
    {reply, ok, State};

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

hex_decode(HexBin) ->
    binary:decode_hex(string:lowercase(HexBin)).