-module(openpixie_tools_ask).
-export([schema/0, ask_user/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => ask_user,
                description => <<"Ask the user a question and wait for their response. Use this when you need clarification, a decision, or information that only the user can provide.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        question => #{
                            type => string,
                            description => <<"The question to ask the user">>
                        },
                        context => #{
                            type => string,
                            description => <<"Additional context or explanation for why you are asking">>
                        }
                    },
                    required => [question]
                }
            }
        }
    ].

ask_user(Args) when is_map(Args) ->
    Question = maps:get(<<"question">>, Args, maps:get(question, Args, <<"">>)),
    Context = maps:get(<<"context">>, Args, maps:get(context, Args, <<"">>)),
    case get(triggered_by) of
        schedule ->
            #{success => false, error => no_user_available,
              message => <<"No user available to ask in scheduled mode. Proceed without asking.">>};
        _ ->
            case Question of
                <<>> -> #{success => false, error => empty_question};
                _ -> #{success => true, question => Question, context => Context, requires_user_input => true}
            end
    end.