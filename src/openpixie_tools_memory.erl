-module(openpixie_tools_memory).
-export([schema/0, search_memories/1, recent_memories/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => search_memories,
                description => <<"Search across all memory files">>,
                parameters => #{
                    type => object,
                    properties => #{
                        query => #{type => string, description => <<"Search query">>}
                    },
                    required => [query]
                }
            }
        },
        #{
            type => function,
            function => #{
                name => recent_memories,
                description => <<"Get paths of recent memory files">>,
                parameters => #{
                    type => object,
                    properties => #{
                        n => #{type => integer, description => <<"Number of recent memories (default 5)">>}
                    },
                    required => []
                }
            }
        }
    ].

search_memories(Args) ->
    Query = maps:get(<<"query">>, Args, maps:get(query, Args, <<"">>)),
    case openpixie_memory:search_memories(Query) of
        {ok, Results} -> #{success => true, results => Results};
        {error, Reason} -> #{success => false, error => Reason}
    end.

recent_memories(Args) ->
    N = case maps:get(<<"n">>, Args, maps:get(n, Args, 5)) of
        I when is_integer(I) -> I;
        B -> catch binary_to_integer(B, 10)
    end,
    NInt = case is_integer(N) of true -> N; false -> 5 end,
    case openpixie_memory:recent_memories(NInt) of
        {ok, Paths} -> #{success => true, paths => Paths};
        {error, Reason} -> #{success => false, error => Reason}
    end.