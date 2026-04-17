-module(openpixie_http_skills).
-export([init/2]).

init(Req, State) ->
    case authenticate(Req) of
        {ok, _} -> handle(Req, State);
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

authenticate(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Key/binary>> -> openpixie_auth:authenticate(Key);
        _ -> {error, no_auth}
    end.

handle(Req, State) ->
    RawSkills = openpixie_skills:list_skills(),
    Skills = lists:map(fun({Name, S}) ->
        #{name => list_to_binary(Name), description => element(3, S), always => element(4, S), tags => element(7, S)}
    end, RawSkills),
    Body = iolist_to_binary(jsx:encode(#{skills => Skills})),
    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.