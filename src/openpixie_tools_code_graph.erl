-module(openpixie_tools_code_graph).
-export([schema/0, code_graph/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => code_graph,
                description => <<"Query the code graph to efficiently navigate your own codebase without re-reading files. "
                    "Use this instead of repeatedly reading the same source files. "
                    "Actions: 'summary' (module list with exports), 'lookup' (search modules/functions by name), "
                    "'module' (detailed info about one module), 'function' (info about a specific function), "
                    "'dependents' (what calls this module), 'dependencies' (what this module calls), "
                    "'search' (search by keyword across modules and functions).">>,
                parameters => #{
                    type => object,
                    properties => #{
                        action => #{
                           type => string,
                            description => <<"One of: summary, lookup, module, function, dependents, dependencies, search, refresh">>
                       },
                        query => #{
                            type => string,
                            description => <<"Search term, module name, or function name (used with lookup, module, function, dependents, dependencies, search)">>
                        },
                        function_name => #{
                            type => string,
                            description => <<"Function name (used with 'function' action, alongside query for module)">>
                        },
                        kind => #{
                            type => string,
                            description => <<"Filter for 'lookup' action: 'module', 'function', or 'all' (default: all)">>
                        }
                    },
                    required => [action]
                }
            }
        }
    ].

code_graph(Args) when is_map(Args) ->
    Action = to_bin(maps:get(<<"action">>, Args, maps:get(action, Args, <<"summary">>))),
    Query = to_bin(maps:get(<<"query">>, Args, maps:get(query, Args, <<"">>))),
    FunctionName = to_bin(maps:get(<<"function_name">>, Args, maps:get(function_name, Args, <<"">>))),
    Kind = to_bin(maps:get(<<"kind">>, Args, maps:get(kind, Args, <<"all">>))),
    case Action of
        <<"summary">> ->
            do_summary();
        <<"lookup">> ->
            do_lookup(Query, Kind);
        <<"module">> ->
            do_module(Query);
        <<"function">> ->
            do_function(Query, FunctionName);
        <<"dependents">> ->
            do_dependents(Query);
        <<"dependencies">> ->
            do_dependencies(Query);
        <<"search">> ->
                do_search(Query);
        <<"refresh">> ->
            do_refresh();
        _ ->
            #{success => false, error => <<"Unknown action. Use: summary, lookup, module, function, dependents, dependencies, search, refresh">>}
    end.

do_refresh() ->
    case openpixie_code_graph:refresh() of
        ok ->
            #{success => true, message => <<"Code graph refreshed successfully.">>};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_summary() ->
    case openpixie_code_graph:summary() of
        {ok, Result} ->
            #{success => true, summary => Result};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_lookup(Query, Kind) ->
    case openpixie_code_graph:lookup(Query, #{<<"kind">> => Kind}) of
        {ok, Result} ->
            Formatted = format_lookup_result(Result),
            #{success => true, results => Formatted};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_module(Query) ->
    case openpixie_code_graph:module_info(Query) of
        {ok, Info} ->
            #{success => true, module => Query, info => Info};
        {error, not_found} ->
            #{success => false, error => <<"Module not found">>, module => Query};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_function(Module, Function) ->
    case Function of
        <<>> ->
            #{success => false, error => <<"function_name is required for 'function' action">>};
        _ ->
            case openpixie_code_graph:function_info(Module, Function) of
                {ok, Info} ->
                    #{success => true, module => Module, function => Function, info => Info};
                {error, not_found} ->
                    #{success => false, error => <<"Function not found">>, module => Module, function => Function};
                {error, Reason} ->
                    #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

do_dependents(Query) ->
    case openpixie_code_graph:dependents(Query) of
        {ok, Deps} ->
            DepBins = [atom_to_binary(D, utf8) || D <- Deps],
            #{success => true, module => Query, dependents => DepBins};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_dependencies(Query) ->
    case openpixie_code_graph:dependencies(Query) of
        {ok, Deps} ->
            DepBins = [atom_to_binary(D, utf8) || D <- Deps],
            #{success => true, module => Query, dependencies => DepBins};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_search(Query) ->
    case openpixie_code_graph:search(Query) of
        {ok, #{modules := Mods, functions := Funs}} ->
            FormattedMods = lists:map(fun({Mod, Info}) ->
                #{module => atom_to_binary(Mod, utf8),
                  description => maps:get(description, Info, <<"">>),
                  file => maps:get(file, Info, <<"">>),
                  exports => maps:get(exports, Info, [])}
            end, Mods),
            FormattedFuns = lists:map(fun({Mod, Fun, Info}) ->
                #{module => atom_to_binary(Mod, utf8),
                  function => atom_to_binary(Fun, utf8),
                  arity => maps:get(arity, Info, 0),
                  exported => maps:get(exported, Info, false),
                  line => maps:get(line, Info, 0),
                  description => maps:get(description, Info, <<"">>)}
            end, Funs),
            #{success => true, modules => FormattedMods, functions => FormattedFuns};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

format_lookup_result(#{modules := Mods, functions := Funs}) ->
    FormattedMods = lists:map(fun({Mod, Info}) ->
        #{module => atom_to_binary(Mod, utf8),
          description => maps:get(description, Info, <<"">>),
          file => maps:get(file, Info, <<"">>),
          exports => maps:get(exports, Info, [])}
    end, Mods),
    FormattedFuns = lists:map(fun({Mod, Fun, Info}) ->
        #{module => atom_to_binary(Mod, utf8),
          function => atom_to_binary(Fun, utf8),
          arity => maps:get(arity, Info, 0),
          exported => maps:get(exported, Info, false),
          line => maps:get(line, Info, 0),
          description => maps:get(description, Info, <<"">>)}
    end, Funs),
    #{modules => FormattedMods, functions => FormattedFuns}.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
