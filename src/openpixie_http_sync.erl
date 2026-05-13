-module(openpixie_http_sync).
-export([init/2]).

init(Req, State) ->
    case authenticate(Req) of
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

authenticate(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Key/binary>> -> openpixie_auth:authenticate(Key);
        _ ->
            Qs = cowboy_req:parse_qs(Req),
            case proplists:get_value(<<"key">>, Qs) of
                undefined -> {error, no_key};
                Key -> openpixie_auth:authenticate(Key)
            end
    end.

handle_get(Req, State) ->
    Qs = cowboy_req:parse_qs(Req),
    Action = proplists:get_value(<<"action">>, Qs, <<"export">>),
    case Action of
        <<"export">> ->
            case openpixie_sync:export_patch() of
                {ok, empty} ->
                    reply_json(Req, State, 200, #{success => true, empty => true, message => <<"No changes to export">>});
                {ok, Patch} ->
                    Ts = timestamp_str(),
                    Filename = <<"openpixie_changes_", Ts/binary, ".patch">>,
                    Req2 = cowboy_req:reply(200, #{
                        <<"content-type">> => <<"text/x-diff">>,
                        <<"content-disposition">> => <<"attachment; filename=\"", Filename/binary, "\"">>
                    }, Patch, Req),
                    {ok, Req2, State};
                {error, Reason} ->
                    ErrBin = iolist_to_binary(io_lib:format("~p", [Reason])),
                    reply_json(Req, State, 500, #{success => false, error => ErrBin})
            end;
        <<"diff">> ->
            case openpixie_sync:get_diff() of
                {ok, Output} ->
                    reply_json(Req, State, 200, #{success => true, diff => Output});
                {error, Reason} ->
                    ErrBin = iolist_to_binary(io_lib:format("~p", [Reason])),
                    reply_json(Req, State, 500, #{success => false, error => ErrBin})
            end;
        _ ->
            reply_json(Req, State, 400, #{error => unknown_action})
    end.

handle_post(Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 5242880, period => 5000}),
    ContentType = cowboy_req:header(<<"content-type">>, Req, <<"application/json">>),
    Result = case binary:match(ContentType, <<"text/plain">>) of
        _ when ContentType =:= <<"text/plain">>; ContentType =:= <<"text/x-diff">>; ContentType =:= <<"application/x-diff">> ->
            openpixie_sync:import_patch_text(Body);
        _ ->
            case jsx:is_json(Body) of
                true ->
                    Msg = jsx:decode(Body, [return_maps]),
                    Patch = maps:get(<<"patch">>, Msg, undefined),
                    case Patch of
                        undefined -> {error, no_patch_field};
                        _ -> openpixie_sync:import_patch(Patch)
                    end;
                false ->
                    openpixie_sync:import_patch_text(Body)
            end
    end,
    case Result of
        {ok, Info} ->
            reply_json(Req2, State, 200, maps:merge(#{success => true}, Info));
        {error, Reason} ->
            ErrBin = error_to_binary(Reason),
            reply_json(Req2, State, 500, #{success => false, error => ErrBin})
    end.

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.

timestamp_str() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:now_to_datetime(erlang:timestamp()),
    iolist_to_binary(io_lib:format("~4..0B~2..0B~2..0B_~2..0B~2..0B~2..0B", [Y, Mo, D, H, Mi, S])).

error_to_binary(Reason) when is_binary(Reason) -> Reason;
error_to_binary(Reason) when is_list(Reason) -> iolist_to_binary(Reason);
error_to_binary(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).