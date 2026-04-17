-module(openpixie_tools_search).
-export([schema/0, grep_files/1, find_files/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => grep_files,
                description => <<"Search file contents with a regex pattern">>,
                parameters => #{
                    type => object,
                    properties => #{
                        pattern => #{type => string, description => <<"Regex pattern">>},
                        path => #{type => string, description => <<"Directory to search (default workspace)">>}
                    },
                    required => [pattern]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => find_files,
                description => <<"Find files matching a glob pattern">>,
                parameters => #{
                    type => object,
                    properties => #{
                        pattern => #{type => string, description => <<"Glob pattern">>},
                        path => #{type => string, description => <<"Directory to search">>}
                    },
                    required => [pattern]
                }
            }
        }
    ].

grep_files(Args) ->
    Ws = openpixie_config:workspace(),
    Path = maps:get(<<"path">>, Args, maps:get(path, Args, Ws)),
    Pattern = maps:get(<<"pattern">>, Args, maps:get(pattern, Args, <<"">>)),
    Cmd = "grep -rn --include='*' -E " ++ shell_escape(binary_to_list(Pattern)) ++
          " " ++ shell_escape(binary_to_list(Path)) ++ " 2>&1 | head -100",
    case os:cmd(Cmd) of
        Output ->
            #{success => true, results => list_to_binary(Output)}
    end.

find_files(Args) ->
    Ws = openpixie_config:workspace(),
    Path = maps:get(<<"path">>, Args, maps:get(path, Args, Ws)),
    Pattern = maps:get(<<"pattern">>, Args, maps:get(pattern, Args, <<"">>)),
    Cmd = "find " ++ shell_escape(binary_to_list(Path)) ++
          " -name " ++ shell_escape(binary_to_list(Pattern)) ++ " 2>/dev/null | head -100",
    case os:cmd(Cmd) of
        Output ->
            #{success => true, results => list_to_binary(Output)}
    end.

shell_escape(Str) ->
    "'" ++ string:replace(Str, "'", "'\\''") ++ "'".