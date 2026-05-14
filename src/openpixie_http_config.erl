-module(openpixie_http_config).
-export([init/2, apply_config/1]).

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} ->
            Method = cowboy_req:method(Req),
            case Method of
                <<"GET">> -> handle_get(Req, State);
                <<"POST">> -> handle_post(Req, State);
                _ -> reply_json(Req, State, 405, #{error => method_not_allowed})
            end;
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle_get(Req, State) ->
    Config = get_config(),
    reply_json(Req, State, 200, Config).

handle_post(Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 65536, period => 5000}),
    case jsx:is_json(Body) of
        true ->
            Msg = jsx:decode(Body, [return_maps]),
            Result = apply_config(Msg),
            reply_json(Req2, State, 200, Result);
        false ->
            reply_json(Req2, State, 400, #{error => invalid_json})
    end.

get_config() ->
    #{
        ollama_host => list_to_binary(openpixie_config:ollama_host()),
        ollama_model => openpixie_config:ollama_model(),
        permission_mode => atom_to_binary(openpixie_config:permission_mode(), utf8),
        llm_timeout_ms => openpixie_config:llm_timeout_ms(),
        max_context_tokens => openpixie_config:max_context_tokens(),
        idle_timeout_minutes => openpixie_config:idle_timeout_minutes(),
        max_llm_concurrency => openpixie_config:max_llm_concurrency()
    }.

apply_config(Msg) ->
    Changes = [],
    Changes1 = case maps:get(<<"ollama_host">>, Msg, undefined) of
        undefined -> Changes;
        Host when is_binary(Host) ->
            openpixie_config:set_ollama_host(binary_to_list(Host)),
            [{ollama_host, Host} | Changes];
        _ -> Changes
    end,
    Changes2 = case maps:get(<<"ollama_model">>, Msg, undefined) of
        undefined -> Changes1;
        Model when is_binary(Model) ->
            openpixie_config:set_ollama_model(Model),
            [{ollama_model, Model} | Changes1];
        _ -> Changes1
    end,
    Changes3 = case maps:get(<<"permission_mode">>, Msg, undefined) of
        undefined -> Changes2;
        ModeBin when is_binary(ModeBin) ->
            Mode = case ModeBin of
                <<"trust">> -> trust;
                <<"auto_noselfmod">> -> auto_noselfmod;
                <<"ask">> -> ask;
                <<"sandbox">> -> sandbox;
                <<"plan">> -> plan;
                _ -> ask
            end,
            openpixie_permissions:set_mode(Mode),
            openpixie_config:set_permission_mode(Mode),
            [{permission_mode, ModeBin} | Changes2];
        _ -> Changes2
    end,
    Changes4 = case maps:get(<<"max_context_tokens">>, Msg, undefined) of
        undefined -> Changes3;
        Tokens when is_integer(Tokens) ->
            application:set_env(openpixie, max_context_tokens, Tokens),
            [{max_context_tokens, Tokens} | Changes3];
        _ -> Changes3
    end,
    Changes5 = case maps:get(<<"llm_timeout_ms">>, Msg, undefined) of
        undefined -> Changes4;
        Timeout when is_integer(Timeout) ->
            application:set_env(openpixie, llm_timeout_ms, Timeout),
            [{llm_timeout_ms, Timeout} | Changes4];
        _ -> Changes4
    end,
    Changes6 = case maps:get(<<"idle_timeout_minutes">>, Msg, undefined) of
        undefined -> Changes5;
        Mins when is_integer(Mins) ->
            application:set_env(openpixie, idle_timeout_minutes, Mins),
            [{idle_timeout_minutes, Mins} | Changes5];
        _ -> Changes5
    end,
    save_config_changes(Changes6),
    #{success => true, updated => Changes6}.

save_config_changes([]) -> ok;
save_config_changes(Changes) ->
    ExistingConfig = case file:read_file(openpixie_config:config_path()) of
        {ok, Content} ->
            case jsx:is_json(Content) of
                true -> jsx:decode(Content, [return_maps]);
                false -> #{}
            end;
        {error, _} -> #{}
    end,
    Updated = lists:foldl(fun({Key, Val}, Acc) ->
        Acc#{atom_to_binary(Key, utf8) => Val}
    end, ExistingConfig, Changes),
    openpixie_config:save_config(Updated).

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.