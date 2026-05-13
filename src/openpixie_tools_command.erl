-module(openpixie_tools_command).
-export([schema/0, run_command/1, run_command_with_port/2]).

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
            run_command_with_port(FullCmd, Timeout)
    end;
run_command(Cmd) when is_binary(Cmd) ->
    run_command(#{<<"command">> => Cmd}).

build_command(Cmd, Workspace, sandbox) when is_atom(sandbox) ->
    "bwrap --ro-bind / / --dev /dev --proc /proc --bind " ++
        shell_escape(Workspace) ++ " " ++ shell_escape(Workspace) ++
        " -- sh -c " ++ shell_escape(Cmd);
build_command(Cmd, Workspace, _Mode) ->
    "sh -c " ++ shell_escape("cd " ++ shell_escape_raw(Workspace) ++ " && " ++ binary_to_list(Cmd)).

run_command_with_port(Cmd, TimeoutMs) ->
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
        catch port_close(Port),
        {error, timeout}
    end.

contains_injection(Cmd) when is_binary(Cmd) ->
    binary:match(Cmd, <<"<<<<<<<">>) =/= nomatch orelse
    binary:match(Cmd, <<">>>>>>>">>) =/= nomatch;
contains_injection(_) ->
    false.

shell_escape(Str) when is_binary(Str) ->
    shell_escape(binary_to_list(Str));
shell_escape(Str) when is_list(Str) ->
    lists:flatten("'" ++ string:replace(Str, "'", "'\\''") ++ "'").

shell_escape_raw(Str) when is_binary(Str) ->
    shell_escape_raw(binary_to_list(Str));
shell_escape_raw(Str) when is_list(Str) ->
    lists:flatten(string:replace(Str, "'", "'\\''")).

clean_output(Output) ->
    MaxSize = 51200,
    case byte_size(Output) > MaxSize of
        true -> binary:part(Output, 0, MaxSize);
        false -> Output
    end.