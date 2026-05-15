-module(openpixie_tools_push).
-export([schema/0, push_message/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => push_message,
                description => <<"Send a message to a conversation topic. The message appears immediately for any connected user and is stored in the conversation history. Use this to proactively reach out to the user, send reminders, or deliver scheduled notifications.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        topic_id => #{
                            type => string,
                            description => <<"The topic ID to send the message to. Use the current conversation's topic ID unless targeting a different conversation.">>
                        },
                        content => #{
                            type => string,
                            description => <<"The message content to send.">>
                        },
                        name => #{
                            type => string,
                            description => <<"Optional name label for the message (e.g. 'reminder', 'cron', 'system').">>
                        }
                    },
                    required => [topic_id, content]
                }
            }
        }
    ].

push_message(Args) when is_map(Args) ->
    TopicId = maps:get(<<"topic_id">>, Args, maps:get(topic_id, Args, <<>>)),
    Content = maps:get(<<"content">>, Args, maps:get(content, Args, <<>>)),
    Name = case maps:get(<<"name">>, Args, maps:get(name, Args, undefined)) of
        undefined -> undefined;
        N when is_binary(N) -> N
    end,
    case TopicId of
        <<>> -> #{success => false, error => missing_topic_id};
        _ ->
            case openpixie_push:notify(TopicId, Content, <<"assistant">>, Name) of
                ok -> #{success => true, message => <<"Message sent to topic ", TopicId/binary>>};
                {error, topic_not_found} -> #{success => false, error => topic_not_found}
            end
    end.