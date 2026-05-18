-module(openpixie_http_health).
-export([init/2]).

init(Req, _State) ->
    {RuntimeMs, _} = erlang:statistics(runtime),
    OllamaStatus = case catch openpixie_ollama:list_models() of
        {ok, _} -> <<"up">>;
        _ -> <<"down">>
    end,
    Body = jsx:encode(#{
        <<"status">> => <<"ok">>,
        <<"ollama">> => OllamaStatus,
        <<"uptime_seconds">> => RuntimeMs div 1000
    }),
    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, _State}.