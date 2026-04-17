-module(openpixie_semaphore).
-behaviour(gen_server).

-export([start_link/0, acquire/0, release/0, available/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    max = 1,
    current = 0,
    queue = queue:new()
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    Max = openpixie_config:max_llm_concurrency(),
    {ok, #state{max = Max}}.

acquire() ->
    gen_server:call(?SERVER, acquire, infinity).

release() ->
    gen_server:cast(?SERVER, release).

available() ->
    gen_server:call(?SERVER, available).

handle_call(acquire, _From, State = #state{current = Current, max = Max})
  when Current < Max ->
    NewState = State#state{current = Current + 1},
    {reply, {ok, acquired}, NewState};

handle_call(acquire, From, State = #state{queue = Q}) ->
    NewQ = queue:in(From, Q),
    {noreply, State#state{queue = NewQ}};

handle_call(available, _From, State = #state{current = Current, max = Max}) ->
    {reply, Max - Current, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(release, State = #state{current = Current, queue = Q}) ->
    case queue:out(Q) of
        {{value, From}, NewQ} ->
            gen_server:reply(From, {ok, acquired}),
            {noreply, State#state{queue = NewQ}};
        {empty, _} ->
            {noreply, State#state{current = max(0, Current - 1)}}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.