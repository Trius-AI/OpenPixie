-module(openpixie_tools_git).
-export([schema/0, git_status/1, git_diff/1, git_log/1, git_add/1, git_commit/1,
         git_branch/1, git_stash/1, git_pull/1, git_push/1, git_remote/1]).

schema() ->
    [
        tool(git_status, <<"Show git status">>, #{}),
        tool(git_diff, <<"Show git diff">>, #{path => #{type => string, description => <<"Path to diff">>}}),
        tool(git_log, <<"Show git log">>, #{n => #{type => integer, description => <<"Number of commits">>}}),
        tool(git_add, <<"Stage files">>, #{path => #{type => string, description => <<"Path to add">>}}),
        tool(git_commit, <<"Commit staged changes">>, #{message => #{type => string, description => <<"Commit message">>}}),
        tool(git_branch, <<"List or create branches">>, #{name => #{type => string, description => <<"Branch name">>}}),
        tool(git_stash, <<"Stash changes">>, #{}),
        tool(git_pull, <<"Pull from remote">>, #{remote => #{type => string, description => <<"Remote name">>}}),
        tool(git_push, <<"Push to remote">>, #{remote => #{type => string, description => <<"Remote name">>}}),
        tool(git_remote, <<"Manage remotes">>, #{action => #{type => string, description => <<"list|add|remove">>}})
    ].

tool(Name, Desc, Props) ->
    #{
        type => function,
        function => #{
            name => Name,
            description => Desc,
            parameters => #{
                type => object,
                properties => Props,
                required => []
            }
        }
    }.

git_status(_) -> run_git("status --porcelain").
git_diff(Args) ->
    Path = maps:get(<<"path">>, Args, maps:get(path, Args, undefined)),
    case Path of
        undefined -> run_git("diff");
        _ -> run_git("diff " ++ shell_escape(Path))
    end.
git_log(Args) ->
    N = maps:get(<<"n">>, Args, maps:get(n, Args, 10)),
    NInt = case is_integer(N) of true -> N; false -> catch binary_to_integer(N) end,
    case NInt of
        I when is_integer(I) -> run_git("log --oneline -" ++ integer_to_list(I));
        _ -> run_git("log --oneline -10")
    end.
git_add(Args) ->
    Path = maps:get(<<"path">>, Args, maps:get(path, Args, <<".">>)),
    run_git("add " ++ shell_escape(Path)).
git_commit(Args) ->
    Msg = maps:get(<<"message">>, Args, maps:get(message, Args, <<"update">>)),
    run_git("commit -m " ++ shell_escape(Msg)).
git_branch(Args) ->
    Name = maps:get(<<"name">>, Args, maps:get(name, Args, undefined)),
    case Name of
        undefined -> run_git("branch");
        _ -> run_git("checkout -b " ++ shell_escape(Name))
    end.
git_stash(_) -> run_git("stash").
git_pull(Args) ->
    Remote = maps:get(<<"remote">>, Args, maps:get(remote, Args, undefined)),
    case Remote of
        undefined -> run_git("pull");
        _ -> run_git("pull " ++ shell_escape(Remote))
    end.
git_push(Args) ->
    Remote = maps:get(<<"remote">>, Args, maps:get(remote, Args, undefined)),
    case Remote of
        undefined -> run_git("push");
        _ -> run_git("push " ++ shell_escape(Remote))
    end.
git_remote(Args) ->
    Action = maps:get(<<"action">>, Args, maps:get(action, Args, undefined)),
    case Action of
        undefined -> run_git("remote -v");
        _ -> run_git("remote " ++ shell_escape(Action))
    end.

run_git(SubCmd) ->
    Ws = openpixie_config:workspace(),
    GitCmd = "git -C " ++ shell_escape(Ws) ++ " " ++ SubCmd ++ " 2>&1",
    Cmd = case ssh_key_exists() of
        true ->
            Home = os:getenv("HOME", "/root"),
            SshCmd = "ssh -i " ++ filename:join(Home, ".ssh/id_ed25519") ++ " -o StrictHostKeyChecking=no",
            "GIT_SSH_COMMAND=" ++ shell_escape(SshCmd) ++ " " ++ GitCmd;
        false ->
            GitCmd
    end,
    run_command_with_timeout(Cmd, 30000).

ssh_key_exists() ->
    PixieDir = openpixie_config:pixie_dir(),
    filelib:is_file(filename:join(PixieDir, "ssh_key")).

run_command_with_timeout(Cmd, TimeoutMs) ->
    PortName = {spawn, Cmd},
    PortOpts = [exit_status, use_stdio, stderr_to_stdout, {line, 4096}],
    case catch open_port(PortName, PortOpts) of
        Port when is_port(Port) ->
            Result = collect_port_output(Port, TimeoutMs, <<>>),
            catch port_close(Port),
            case Result of
                {ok, Output} ->
                    CleanOutput = clean_output(Output),
                    #{success => true, output => CleanOutput};
                {error, timeout} ->
                    #{success => false, error => command_timeout}
            end;
        Error ->
            #{success => false, error => command_failed, reason => iolist_to_binary(io_lib:format("~p", [Error]))}
    end.

collect_port_output(Port, Timeout, Acc) ->
    receive
        {Port, {data, {eol, Line}}} ->
            LineBin = if is_binary(Line) -> Line; is_list(Line) -> list_to_binary(Line); true -> iolist_to_binary(Line) end,
            collect_port_output(Port, Timeout, <<Acc/binary, LineBin/binary, "\n">>);
        {Port, {data, {noeol, Line}}} ->
            LineBin = if is_binary(Line) -> Line; is_list(Line) -> list_to_binary(Line); true -> iolist_to_binary(Line) end,
            collect_port_output(Port, Timeout, <<Acc/binary, LineBin/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, _Code}} ->
            {ok, Acc}
    after Timeout ->
        {error, timeout}
    end.

shell_escape(Str) when is_binary(Str) ->
    shell_escape(binary_to_list(Str));
shell_escape(Str) ->
    "'" ++ string:replace(Str, "'", "'\\''") ++ "'".

clean_output(Output) ->
    case byte_size(Output) > 51200 of
        true -> binary:part(Output, 0, 51200);
        false -> Output
    end.