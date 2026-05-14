-module(openpixie_http_spa).
-export([init/2]).

init(Req, State) ->
    DashboardDir = openpixie_http:resolve_dashboard_dir(),
    IndexFile = case DashboardDir of
        undefined -> undefined;
        Dir -> filename:join(Dir, "index.html")
    end,
    case IndexFile of
        undefined ->
            Req2 = cowboy_req:reply(404, #{<<"content-type">> => <<"text/plain">>}, <<"Not found">>, Req),
            {ok, Req2, State};
        _ ->
            case file:read_file(IndexFile) of
                {ok, Content} ->
                    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"text/html">>}, Content, Req),
                    {ok, Req2, State};
                {error, _} ->
                    Req2 = cowboy_req:reply(500, #{<<"content-type">> => <<"text/plain">>}, <<"Internal error">>, Req),
                    {ok, Req2, State}
            end
    end.