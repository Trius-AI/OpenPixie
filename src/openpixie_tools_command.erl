-module(openpixie_tools_command).
-export([schema/0, run_command/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => run_command,
                description => <<"Run a shell command in the workspace">>,
                parameters => #{
                    type => object,
                    properties => #{
                        command => #{type => string, description => <<"Shell command to run">>},
                        timeout => #{type => integer, description => <<"Timeout in milliseconds (default 30000)">>}
                    },
                    required => [command]
                }
            }
        }
    ].

run_command(Args) when is_map(Args) ->
    Cmd = maps:get(<<"command">>, Args, maps:get(command, Args, <<"">>)),
    Timeout = maps:get(<<"timeout">>, Args, maps:get(timeout, Args, 30000)),
    Ws = openpixie_config:workspace(),
    Mode = openpixie_config:permission_mode(),
    FullCmd = build_command(Cmd, Ws, Mode),
    case contains_injection(Cmd) of
        true ->
            #{success => false, error => command_rejected, reason => potential_injection};
        false ->
            execute_port(FullCmd, Timeout)
    end;
run_command(Cmd) when is_binary(Cmd) ->
    run_command(#{<<"command">> => Cmd}).

build_command(Cmd, Workspace, sandbox) when is_atom(sandbox) ->
    "bwrap --ro-bind / / --dev /dev --proc /proc --bind " ++
        shell_escape(Workspace) ++ " " ++ shell_escape(Workspace) ++
        " -- sh -c " ++ shell_escape(Cmd);
build_command(Cmd, Workspace, _Mode) ->
    "sh -c 'cd " ++ shell_escape(Workspace) ++ " && " ++ binary_to_list(Cmd) ++ "'".

execute_port(Cmd, TimeoutMs) ->
    case catch os:cmd(Cmd, [{timeout, TimeoutMs}]) of
        {'EXIT', Reason} ->
            #{success => false, error => command_failed, reason => iolist_to_binary(io_lib:format("~p", [Reason]))};
        Output when is_list(Output) ->
            BinOutput = iolist_to_binary(Output),
            ExitCode = case string:find(Output, "command not found") of
                nomatch -> 0;
                _ -> 127
            end,
            CleanOutput = clean_output(BinOutput),
            #{success => (ExitCode =:= 0), output => CleanOutput, exit_code => ExitCode}
    end.

contains_injection(Cmd) when is_binary(Cmd) ->
    binary:match(Cmd, <<"<<<<<<<">>) =/= nomatch orelse
    binary:match(Cmd, <<">>>>>>>">>) =/= nomatch;
contains_injection(_) ->
    false.

shell_escape(Str) when is_binary(Str) ->
    shell_escape(binary_to_list(Str));
shell_escape(Str) when is_list(Str) ->
    case lists:member($', Str) of
        true -> "'" ++ string:replace(Str, "'", "'\\''") ++ "'";
        false -> "'" ++ Str ++ "'"
    end.

clean_output(Output) ->
    MaxSize = 51200,
    case byte_size(Output) > MaxSize of
        true -> binary:part(Output, 0, MaxSize);
        false -> Output
    end.