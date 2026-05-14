-module(openpixie_http_login).
-export([init/2]).

init(Req, State) ->
    Method = cowboy_req:method(Req),
    case Method of
        <<"POST">> -> handle_post(Req, State);
        <<"DELETE">> -> handle_logout(Req, State);
        _ -> reply_json(Req, State, 405, #{error => method_not_allowed})
    end.

handle_post(Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 65536, period => 5000}),
    case jsx:is_json(Body) of
        true ->
            Msg = jsx:decode(Body, [return_maps]),
            ApiKey = maps:get(<<"api_key">>, Msg, undefined),
            case ApiKey of
                undefined -> reply_json(Req2, State, 400, #{error => <<"api_key required">>});
                _ ->
                    case openpixie_auth:create_session(ApiKey) of
                        {ok, SessionToken} ->
                            Req3 = cowboy_req:set_resp_cookie(<<"openpixie_session">>, SessionToken,
                                Req2, #{path => <<"/">>, same_site => strict, http_only => true, <<"max-age">> => 86400}),
                            reply_json(Req3, State, 200, #{success => true});
                        {error, Reason} ->
                            reply_json(Req2, State, 401, #{error => atom_to_binary(Reason, utf8)})
                    end
            end;
        false ->
            reply_json(Req2, State, 400, #{error => invalid_json})
    end.

handle_logout(Req, State) ->
    Cookies = cowboy_req:parse_cookies(Req),
    case proplists:get_value(<<"openpixie_session">>, Cookies) of
        undefined -> ok;
        Token -> openpixie_auth:delete_session(Token)
    end,
    Req2 = cowboy_req:set_resp_cookie(<<"openpixie_session">>, <<"">>,
        Req, #{path => <<"/">>, same_site => strict, http_only => true, <<"max-age">> => 0}),
    reply_json(Req2, State, 200, #{success => true}).

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.