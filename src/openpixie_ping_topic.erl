-module(openpixie_ping_topic).
-export([ping/0]).

-define(TOPIC_ID, <<"2QWBWJH86U5NP">>).

ping() ->
    case openpixie_topic_store:lookup_pid(?TOPIC_ID) of
        {ok, Pid} when is_pid(Pid) ->
            Timestamp = format_time(),
            Message = #{<<"type">> => <<"ping">>,
                        <<"content">> => <<"👋 Hello! This is your scheduled 5-minute ping from Pixie!">>,
                        <<"timestamp">> => Timestamp},
            openpixie_topic:broadcast(Pid, Message),
            openpixie_log:info("Ping sent to topic ~p", [?TOPIC_ID]);
        {error, not_found} ->
            openpixie_log:warn("Cannot ping topic ~p: not found", [?TOPIC_ID])
    end.

format_time() ->
    {{Y, Mo, D}, {H, M, S}} = erlang:localtime(),
    iolist_to_binary(io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w", [Y, Mo, D, H, M, S])).