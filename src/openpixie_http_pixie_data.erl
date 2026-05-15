-module(openpixie_http_pixie_data).
-export([init/2]).

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} ->
            Method = cowboy_req:method(Req),
            Name = cowboy_req:binding(name, Req, <<"">>),
            case Method of
                <<"GET">> -> handle_get(Req, State, Name);
                <<"PUT">> -> handle_put(Req, State, Name);
                _ -> reply_json(Req, State, 405, #{error => method_not_allowed})
            end;
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle_get(Req, State, Name) ->
    case resolve_file(Name) of
        {ok, FilePath, ContentType} ->
            case file:read_file(FilePath) of
                {ok, RawContent} ->
                    Content = case byte_size(RawContent) > 0 andalso binary:last(RawContent) =:= 10 of
                        true -> binary:part(RawContent, 0, byte_size(RawContent) - 1);
                        false -> RawContent
                    end,
                    Data = #{
                        name => Name,
                        content => Content,
                        content_type => ContentType,
                        path => list_to_binary(FilePath)
                    },
                    reply_json(Req, State, 200, Data);
                {error, enoent} ->
                    reply_json(Req, State, 200, #{name => Name, content => <<>>, content_type => ContentType, path => list_to_binary(FilePath)});
                {error, Reason} ->
                    reply_json(Req, State, 500, #{error => read_error, reason => atom_to_binary(Reason, utf8)})
            end;
        undefined ->
            reply_json(Req, State, 404, #{error => unknown_file})
    end.

handle_put(Req, State, Name) ->
    case resolve_file(Name) of
        {ok, FilePath, _ContentType} ->
            {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => 1048576, period => 5000}),
            case jsx:is_json(Body) of
                true ->
                    Msg = jsx:decode(Body, [return_maps]),
                    case {Name, maps:get(<<"action">>, Msg, undefined)} of
                        {<<"api_key">>, <<"regenerate">>} ->
                            {NewKey, _HashStr} = openpixie_auth:generate_key(),
                            openpixie_auth:setup_key(NewKey),
                            PixieDir = openpixie_config:pixie_dir(),
                            ApiKeyPath = filename:join(PixieDir, "API_KEY"),
                            file:write_file(ApiKeyPath, <<NewKey/binary, "\n">>),
                            reply_json(Req2, State, 200, #{success => true, name => Name, new_key => NewKey});
                        _ ->
                            Content = maps:get(<<"content">>, Msg, undefined),
                            case Content of
                                undefined ->
                                    reply_json(Req2, State, 400, #{error => missing_content});
                                Content ->
                                    write_file(Req2, State, Name, FilePath, Content)
                            end
                    end;
                false ->
                    reply_json(Req2, State, 400, #{error => invalid_json})
            end;
        undefined ->
            reply_json(Req, State, 404, #{error => unknown_file})
    end.

write_file(Req, State, Name, FilePath, Content) ->
    TmpPath = FilePath ++ ".tmp",
    case file:write_file(TmpPath, Content) of
        ok ->
            case file:rename(TmpPath, FilePath) of
                ok ->
                    case Name of
                        <<"api_key">> ->
                            openpixie_auth:setup_key(Content);
                        <<"config">> ->
                            openpixie_config:load_config();
                        _ -> ok
                    end,
                    reply_json(Req, State, 200, #{success => true, name => Name});
                {error, Reason} ->
                    file:delete(TmpPath),
                    reply_json(Req, State, 500, #{error => rename_failed, reason => atom_to_binary(Reason, utf8)})
            end;
        {error, Reason} ->
            reply_json(Req, State, 500, #{error => write_error, reason => atom_to_binary(Reason, utf8)})
    end.

resolve_file(<<"soul">>) ->
    {ok, openpixie_config:soul_path(), <<"text/markdown">>};
resolve_file(<<"config">>) ->
    {ok, openpixie_config:config_path(), <<"application/json">>};
resolve_file(<<"api_key">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "API_KEY"), <<"text/plain">>};
resolve_file(_) ->
    undefined.

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.