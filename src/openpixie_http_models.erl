-module(openpixie_http_models).
-export([init/2]).

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} -> handle(Req, State);
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle(Req, State) ->
    case openpixie_ollama:list_models() of
        {ok, Response} ->
            Body = jsx:encode(Response),
            Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req),
            {ok, Req2, State};
        {error, _Reason} ->
            Req2 = cowboy_req:reply(503, #{}, <<"Ollama unavailable">>, Req),
            {ok, Req2, State}
    end.