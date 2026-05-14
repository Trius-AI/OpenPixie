-module(openpixie_http_topics).
-export([init/2]).

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} ->
            handle(Req, State);
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle(Req, State) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            Qs = cowboy_req:parse_qs(Req),
            ChannelId = proplists:get_value(<<"channel">>, Qs),
            RawTopics = case ChannelId of
                undefined -> openpixie_topic_store:list();
                _ -> openpixie_topic_store:list_by_channel(ChannelId)
            end,
            Formatted = lists:map(fun({Id, Pid, Status, ChId, Title}) ->
                StatusBin = case is_atom(Status) of true -> atom_to_binary(Status, utf8); false -> Status end,
                #{id => Id, status => StatusBin, channel_id => ChId, title => Title, active => is_pid(Pid)}
            end, RawTopics),
            Channels = openpixie_channel:list(),
            ChannelList = lists:map(fun({Name, Data}) ->
                Data#{name => Name}
            end, Channels),
            RespBody = iolist_to_binary(jsx:encode(#{topics => Formatted, channels => ChannelList})),
            Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, RespBody, Req),
            {ok, Req2, State};
        <<"POST">> ->
            {ok, Body, Req2} = cowboy_req:read_body(Req),
            Msg = jsx:decode(Body, [return_maps]),
            ChannelId = maps:get(<<"channel_id">>, Msg, <<"general">>),
            Title = maps:get(<<"title">>, Msg, <<"Untitled">>),
            ParentId = maps:get(<<"parent_id">>, Msg, undefined),
            {ok, TopicId, TopicPid} = openpixie_topic_sup:start_topic(),
            case ParentId of
                undefined -> ok;
                _ -> openpixie_topic:set_fork(TopicPid, Title, ChannelId, ParentId)
            end,
            openpixie_topic_store:update(TopicId, ChannelId, Title),
            RespBody = jsx:encode(#{topic_id => TopicId, title => Title, channel_id => ChannelId}),
            Req3 = cowboy_req:reply(201, #{<<"content-type">> => <<"application/json">>}, RespBody, Req2),
            {ok, Req3, State};
        <<"DELETE">> ->
            TopicId = cowboy_req:binding(id, Req, <<"">>),
            ok = openpixie_topic:delete_topic(TopicId),
            RespBody = jsx:encode(#{deleted => true, topic_id => TopicId}),
            Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, RespBody, Req),
            {ok, Req2, State};
        _ ->
            Req2 = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req),
            {ok, Req2, State}
    end.