-module(openpixie_http_metrics).
-export([init/2]).

%% HTTP handler for metrics API
%% Provides endpoints for performance metrics tracking
%% GET /api/v1/metrics - list all metric keys
%% GET /api/v1/metrics/:key - get statistics for a key
%% GET /api/v1/metrics/:key/trend - get trend for a key

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} ->
            Method = cowboy_req:method(Req),
            Key = cowboy_req:binding(key, Req, undefined),
            Action = cowboy_req:binding(action, Req, undefined),
            handle_request(Req, State, Method, Key, Action);
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle_request(Req, State, <<"GET">>, undefined, undefined) ->
    %% List all metric keys
    case openpixie_metrics:get_all_keys() of
        {ok, Keys} ->
            reply_json(Req, State, 200, #{keys => Keys});
        {error, Reason} ->
            reply_json(Req, State, 500, #{error => Reason})
    end;
handle_request(Req, State, <<"GET">>, Key, undefined) when Key =/= undefined ->
    %% Get statistics for a specific key
    case openpixie_metrics:get_statistics(Key) of
        {ok, no_data} ->
            reply_json(Req, State, 200, #{key => Key, statistics => no_data});
        {ok, Stats} ->
            reply_json(Req, State, 200, #{key => Key, statistics => Stats});
        {error, Reason} ->
            reply_json(Req, State, 500, #{error => Reason})
    end;
handle_request(Req, State, <<"GET">>, Key, <<"trend">>) when Key =/= undefined ->
    %% Get trend for a specific key
    WindowParam = cowboy_req:parse_qs(Req),
    Window = case lists:keyfind(<<"window">>, 1, WindowParam) of
        {_, W} when is_binary(W) -> catch binary_to_integer(W);
        _ -> 5
    end,
    WindowInt = case is_integer(Window) of true -> Window; false -> 5 end,
    case openpixie_metrics:get_trend(Key, WindowInt) of
        {ok, no_data} ->
            reply_json(Req, State, 200, #{key => Key, trend => no_data});
        {ok, insufficient_history} ->
            reply_json(Req, State, 200, #{key => Key, trend => insufficient_history});
        {ok, TrendData} ->
            reply_json(Req, State, 200, #{key => Key, trend => TrendData, window => WindowInt});
        {error, Reason} ->
            reply_json(Req, State, 500, #{error => Reason})
    end;
handle_request(Req, State, <<"GET">>, Key, <<"recent">>) when Key =/= undefined ->
    %% Get recent entries for a specific key
    NParam = cowboy_req:parse_qs(Req),
    N = case lists:keyfind(<<"n">>, 1, NParam) of
        {_, NVal} when is_binary(NVal) -> catch binary_to_integer(NVal);
        _ -> 10
    end,
    NInt = case is_integer(N) of true -> N; false -> 10 end,
    case openpixie_metrics:get_recent(Key, NInt) of
        {ok, Entries} ->
            reply_json(Req, State, 200, #{key => Key, entries => Entries, count => length(Entries)});
        {error, Reason} ->
            reply_json(Req, State, 500, #{error => Reason})
    end;
handle_request(Req, State, _Method, _Key, _Action) ->
    reply_json(Req, State, 405, #{error => method_not_allowed}).

reply_json(Req, State, Status, Data) ->
    Body = jsx:encode(Data),
    Req2 = cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.