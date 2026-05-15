-module(openpixie_http_skills).
-export([init/2]).

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} ->
            Method = cowboy_req:method(Req),
            case Method of
                <<"GET">> -> handle_list(Req, State);
                <<"POST">> -> handle_post(Req, State);
                _ -> reply_json(Req, State, 405, #{error => method_not_allowed})
            end;
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle_list(Req, State) ->
    RawSkills = openpixie_skills:list_skills(),
    Skills = lists:map(fun({Name, S}) ->
        #{
            name => list_to_binary(Name),
            description => element(3, S),
            always => element(4, S),
            tags => element(7, S)
        }
    end, RawSkills),
    reply_json(Req, State, 200, #{skills => Skills}).

handle_post(Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 1048576, period => 5000}),
    case jsx:is_json(Body) of
        true ->
            Msg = jsx:decode(Body, [return_maps]),
            Action = maps:get(<<"action">>, Msg, undefined),
            case Action of
                <<"create">> -> handle_create(Req2, State, Msg);
                <<"update">> -> handle_update(Req2, State, Msg);
                <<"delete">> -> handle_delete(Req2, State, Msg);
                <<"load">> -> handle_load(Req2, State, Msg);
                <<"rescan">> -> handle_rescan(Req2, State);
                _ -> reply_json(Req2, State, 400, #{error => unknown_action})
            end;
        false ->
            reply_json(Req, State, 400, #{error => invalid_json})
    end.

handle_create(Req, State, Msg) ->
    Name = maps:get(<<"name">>, Msg, undefined),
    Content = maps:get(<<"content">>, Msg, undefined),
    case {Name, Content} of
        {undefined, _} -> reply_json(Req, State, 400, #{error => missing_name});
        {_, undefined} -> reply_json(Req, State, 400, #{error => missing_content});
        {Name, Content} ->
            case openpixie_skills:create_skill(Name, Content) of
                {ok, Skill} ->
                    reply_json(Req, State, 200, #{success => true, skill => skill_to_map(Skill)});
                {error, already_exists} ->
                    reply_json(Req, State, 409, #{error => already_exists});
                {error, Reason} ->
                    reply_json(Req, State, 500, #{error => create_failed, reason => format_reason(Reason)})
            end
    end.

handle_update(Req, State, Msg) ->
    Name = maps:get(<<"name">>, Msg, undefined),
    Content = maps:get(<<"content">>, Msg, undefined),
    case {Name, Content} of
        {undefined, _} -> reply_json(Req, State, 400, #{error => missing_name});
        {_, undefined} -> reply_json(Req, State, 400, #{error => missing_content});
        {Name, Content} ->
            case openpixie_skills:update_skill(Name, Content) of
                {ok, Skill} ->
                    reply_json(Req, State, 200, #{success => true, skill => skill_to_map(Skill)});
                {error, Reason} ->
                    reply_json(Req, State, 500, #{error => update_failed, reason => format_reason(Reason)})
            end
    end.

handle_delete(Req, State, Msg) ->
    Name = maps:get(<<"name">>, Msg, undefined),
    case Name of
        undefined -> reply_json(Req, State, 400, #{error => missing_name});
        Name ->
            case openpixie_skills:delete_skill(Name) of
                ok -> reply_json(Req, State, 200, #{success => true});
                {error, not_found} -> reply_json(Req, State, 404, #{error => not_found});
                {error, Reason} -> reply_json(Req, State, 500, #{error => delete_failed, reason => format_reason(Reason)})
            end
    end.

handle_load(Req, State, Msg) ->
    Name = maps:get(<<"name">>, Msg, undefined),
    case Name of
        undefined -> reply_json(Req, State, 400, #{error => missing_name});
        Name ->
            case openpixie_skills:load_skill(Name) of
                {ok, Content} -> reply_json(Req, State, 200, #{success => true, name => Name, content => Content});
                {error, not_found} -> reply_json(Req, State, 404, #{error => not_found});
                {error, Reason} -> reply_json(Req, State, 500, #{error => load_failed, reason => format_reason(Reason)})
            end
    end.

handle_rescan(Req, State) ->
    ok = openpixie_skills:rescan(),
    handle_list(Req, State).

skill_to_map(S) ->
    #{name => element(2, S), description => element(3, S), always => element(4, S), tags => element(7, S)}.

format_reason({write_failed, R}) -> list_to_binary(io_lib:format("~p", [R]));
format_reason(R) when is_atom(R) -> atom_to_binary(R, utf8);
format_reason(R) -> list_to_binary(io_lib:format("~p", [R])).

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.