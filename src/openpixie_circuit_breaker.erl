-module(openpixie_circuit_breaker).
-behaviour(gen_server).

-export([start_link/0, call/1, call/2, status/0, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(STATE_CLOSED, closed).
-define(STATE_OPEN, open).
-define(STATE_HALF_OPEN, half_open).

-record(state, {
    cb_state = ?STATE_CLOSED,
    failure_count = 0,
    last_failure = undefined,
    half_open_timer = undefined
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}}.

call(Fun) ->
    call(Fun, openpixie_config:llm_timeout_ms()).

call(Fun, Timeout) ->
    gen_server:call(?SERVER, {call, Fun, Timeout}, Timeout + 5000).

status() ->
    gen_server:call(?SERVER, status).

reset() ->
    gen_server:cast(?SERVER, reset).

handle_call({call, _Fun, _Timeout}, _From, State = #state{cb_state = ?STATE_OPEN}) ->
    openpixie_log:warn("Circuit breaker: rejecting call (circuit open, failures=~p)", [State#state.failure_count]),
    {reply, {error, circuit_open}, State};

handle_call({call, Fun, _Timeout}, _From, State = #state{cb_state = ?STATE_CLOSED}) ->
    case catch Fun() of
        {ok, Result} ->
            NewState = State#state{failure_count = 0},
            {reply, {ok, Result}, NewState};
        {error, Reason} ->
            NewCount = State#state.failure_count + 1,
            MaxFailures = openpixie_config:circuit_breaker_failures(),
            case NewCount >= MaxFailures of
                true ->
                    Cooldown = openpixie_config:circuit_breaker_cooldown_ms(),
                    TimerRef = erlang:send_after(Cooldown, self(), half_open_attempt),
                    openpixie_log:error("Circuit breaker: opening (failures=~p >= max=~p), cooldown=~pms", [NewCount, MaxFailures, Cooldown]),
                    {reply, {error, Reason},
                     State#state{cb_state = ?STATE_OPEN, failure_count = NewCount,
                                last_failure = erlang:system_time(millisecond),
                                half_open_timer = TimerRef}};
                false ->
                    {reply, {error, Reason},
                     State#state{failure_count = NewCount,
                                last_failure = erlang:system_time(millisecond)}}
            end;
        Other ->
            {reply, {error, {unexpected, Other}}, State}
    end;

handle_call({call, Fun, _Timeout}, _From, State = #state{cb_state = ?STATE_HALF_OPEN}) ->
    case catch Fun() of
        {ok, Result} ->
            openpixie_log:info("Circuit breaker: recovered to closed state (service healthy)", []),
            catch erlang:cancel_timer(State#state.half_open_timer),
            {reply, {ok, Result}, State#state{cb_state = ?STATE_CLOSED, failure_count = 0,
                                                half_open_timer = undefined}};
        {error, Reason} ->
            catch erlang:cancel_timer(State#state.half_open_timer),
            Cooldown = openpixie_config:circuit_breaker_cooldown_ms(),
            TimerRef = erlang:send_after(Cooldown, self(), half_open_attempt),
            {reply, {error, Reason}, State#state{cb_state = ?STATE_OPEN,
                                                  half_open_timer = TimerRef}};
        Other ->
            {reply, {error, {unexpected, Other}}, State}
    end;

handle_call(status, _From, State) ->
    {reply, #{state => State#state.cb_state,
              failure_count => State#state.failure_count,
              last_failure => State#state.last_failure}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(reset, _State) ->
    {noreply, #state{}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(half_open_attempt, State = #state{half_open_timer = TimerRef}) ->
    catch erlang:cancel_timer(TimerRef),
    openpixie_log:info("Circuit breaker: entering half_open state, attempting recovery test", []),
    HalfOpenTimeout = openpixie_config:circuit_breaker_cooldown_ms() * 2,
    TimeoutRef = erlang:send_after(HalfOpenTimeout, self(), half_open_timeout),
    {noreply, State#state{cb_state = ?STATE_HALF_OPEN, half_open_timer = TimeoutRef}};

handle_info(half_open_timeout, State) ->
    {noreply, State#state{cb_state = ?STATE_CLOSED, failure_count = 0, half_open_timer = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
