-module(openpixie_channel).
-behaviour(gen_server).

-export([start_link/0, list/0, create/1, create/2, get/1,
         topics/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CHANNELS_TABLE, openpixie_channels).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ets:new(?CHANNELS_TABLE, [named_table, public, set]),
    do_init_defaults(),
    {ok, #{}}.

do_init_defaults() ->
    case ets:lookup(?CHANNELS_TABLE, <<"general">>) of
        [] ->
            Now = erlang:system_time(millisecond),
            Data = #{name => <<"general">>, description => <<"General conversation">>, created_at => Now},
            ets:insert(?CHANNELS_TABLE, {<<"general">>, Data}),
            Dir = openpixie_config:channels_dir(),
            ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
            ok = file:write_file(filename:join(Dir, "general.json"), jsx:encode(Data));
        _ -> ok
    end,
    ok.

list() ->
    ets:tab2list(?CHANNELS_TABLE).

create(Name) ->
    create(Name, Name).

create(Name, Description) when is_binary(Name) ->
    gen_server:call(?SERVER, {create, Name, Description}).

get(Name) when is_binary(Name) ->
    case ets:lookup(?CHANNELS_TABLE, Name) of
        [{Name, Data}] -> {ok, Data};
        [] -> {error, not_found}
    end.

topics(ChannelId) ->
    openpixie_topic_store:list_by_channel(ChannelId).

handle_call({create, Name, Description}, _From, State) ->
    Now = erlang:system_time(millisecond),
    Data = #{
        name => Name,
        description => Description,
        created_at => Now
    },
    ets:insert(?CHANNELS_TABLE, {Name, Data}),
    Dir = openpixie_config:channels_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    ok = file:write_file(filename:join(Dir, binary_to_list(Name) ++ ".json"), jsx:encode(Data)),
    {reply, {ok, Data}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.