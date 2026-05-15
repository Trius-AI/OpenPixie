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
                        <<"ssh_key">> ->
                            install_ssh_key(Content);
                        <<"git_remote">> ->
                            configure_git_remote(Content);
                        <<"git_branch">> ->
                            configure_git_branch(Content);
                        <<"git_name">> ->
                            configure_git_name(Content);
                        <<"git_email">> ->
                            configure_git_email(Content);
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

install_ssh_key(Content) ->
    Home = os:getenv("HOME", "/root"),
    SshDir = filename:join(Home, ".ssh"),
    ok = filelib:ensure_dir(filename:join(SshDir, "id_ed25519")),
    KeyPath = filename:join(SshDir, "id_ed25519"),
   _ok = file:write_file(KeyPath, <<Content/binary, "\n">>),
    _ = os:find_executable("chmod"),
    openpixie_tools_command:run_command_with_port("chmod 600 " ++ KeyPath, 5000),
    ok.

configure_git_remote(RemoteUrl) ->
    Url = binary_to_list(string:trim(RemoteUrl)),
    Ws = openpixie_config:workspace(),
    case Url of
        "" -> ok;
        _ ->
            CheckCmd = "git -C " ++ Ws ++ " remote -v 2>&1",
            HasOrigin = case openpixie_tools_command:run_command_with_port(CheckCmd, 10000) of
                #{success := true, output := Out} -> binary:match(Out, <<"origin">>) =/= nomatch;
                _ -> false
            end,
            if
                HasOrigin ->
                    SetCmd = "git -C " ++ Ws ++ " remote set-url origin " ++ Url ++ " 2>&1",
                    openpixie_tools_command:run_command_with_port(SetCmd, 10000);
                true ->
                    AddCmd = "git -C " ++ Ws ++ " remote add origin " ++ Url ++ " 2>&1",
                    openpixie_tools_command:run_command_with_port(AddCmd, 10000)
             end,
             ok
     end.

configure_git_branch(BranchName) ->
    Branch = binary_to_list(string:trim(BranchName)),
    Ws = openpixie_config:workspace(),
    case Branch of
        "" -> ok;
        _ ->
            openpixie_tools_command:run_command_with_port(
                "git -C " ++ Ws ++ " checkout -B " ++ shell_escape_git(Branch) ++ " 2>&1", 10000),
            openpixie_tools_command:run_command_with_port(
                "git -C " ++ Ws ++ " branch --set-upstream-to=origin/" ++ shell_escape_git(Branch) ++ " " ++ shell_escape_git(Branch) ++ " 2>&1", 10000),
            ok
    end.

shell_escape_git(Str) ->
    "'" ++ Str ++ "'".

configure_git_name(Name) ->
    Ws = openpixie_config:workspace(),
    Escaped = lists:flatten(string:replace(binary_to_list(string:trim(Name)), "'", "'\\''")),
    openpixie_tools_command:run_command_with_port(
        "git -C " ++ Ws ++ " config user.name '" ++ Escaped ++ "' 2>&1", 5000),
    ok.

configure_git_email(Email) ->
    Ws = openpixie_config:workspace(),
    Escaped = lists:flatten(string:replace(binary_to_list(string:trim(Email)), "'", "'\\''")),
    openpixie_tools_command:run_command_with_port(
        "git -C " ++ Ws ++ " config user.email '" ++ Escaped ++ "' 2>&1", 5000),
    ok.

resolve_file(<<"soul">>) ->
    {ok, openpixie_config:soul_path(), <<"text/markdown">>};
resolve_file(<<"config">>) ->
    {ok, openpixie_config:config_path(), <<"application/json">>};
resolve_file(<<"api_key">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "API_KEY"), <<"text/plain">>};
resolve_file(<<"ssh_key">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "ssh_key"), <<"text/plain">>};
resolve_file(<<"known_hosts">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "known_hosts"), <<"text/plain">>};
resolve_file(<<"git_remote">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "git_remote"), <<"text/plain">>};
resolve_file(<<"git_branch">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "git_branch"), <<"text/plain">>};
resolve_file(<<"git_name">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "git_name"), <<"text/plain">>};
resolve_file(<<"git_email">>) ->
    PixieDir = openpixie_config:pixie_dir(),
    {ok, filename:join(PixieDir, "git_email"), <<"text/plain">>};
resolve_file(_) ->
    undefined.

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.