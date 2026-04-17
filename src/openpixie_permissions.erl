-module(openpixie_permissions).
-behaviour(gen_server).

-export([start_link/0, check/2, set_mode/1, get_mode/0, allow/1, deny/1, is_readonly/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(RULES_TABLE, openpixie_permission_rules).

-record(rule, {
    pattern :: binary(),
    decision :: allow | deny | ask
}).

-record(state, {
    mode :: trust | sandbox | plan,
    rules = []
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ets:new(?RULES_TABLE, [named_table, public, set]),
    Mode = openpixie_config:permission_mode(),
    {ok, #state{mode = Mode}}.

check(ToolName, _Args) ->
    gen_server:call(?SERVER, {check, ToolName}, 5000).

set_mode(Mode) ->
    gen_server:call(?SERVER, {set_mode, Mode}, 5000).

get_mode() ->
    gen_server:call(?SERVER, get_mode, 5000).

allow(Pattern) ->
    gen_server:call(?SERVER, {add_rule, Pattern, allow}, 5000).

deny(Pattern) ->
    gen_server:call(?SERVER, {add_rule, Pattern, deny}, 5000).

handle_call({check, _ToolName}, _From, State = #state{mode = trust}) ->
    {reply, {allow, trust_mode}, State};

handle_call({check, ToolName}, _From, State = #state{mode = plan}) ->
    case is_readonly(ToolName) of
        true -> {reply, {allow, plan_readonly}, State};
        false -> {reply, {deny, plan_mode}, State}
    end;

handle_call({check, ToolName}, _From, State = #state{mode = sandbox}) ->
    case is_self_modification(ToolName) of
        true -> {reply, {deny, sandbox_self_mod}, State};
        false ->
            case is_readonly(ToolName) of
                true -> {reply, {allow, sandbox_readonly}, State};
                false -> {reply, {ask, sandbox_write}, State}
            end
    end;

handle_call({check, ToolName}, _From, State = #state{mode = ask}) ->
    case is_self_modification(ToolName) of
        true -> {reply, {ask, self_modification}, State};
        false ->
            case is_readonly(ToolName) of
                true -> {reply, {allow, ask_readonly}, State};
                false -> {reply, {ask, ask_write}, State}
            end
    end;

handle_call({set_mode, Mode}, _From, State) ->
    {reply, ok, State#state{mode = Mode}};

handle_call(get_mode, _From, State = #state{mode = Mode}) ->
    {reply, Mode, State};

handle_call({add_rule, Pattern, Decision}, _From, State = #state{rules = Rules}) ->
    NewRules = [#rule{pattern = Pattern, decision = Decision} | Rules],
    {reply, ok, State#state{rules = NewRules}};

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

is_readonly(ToolName) ->
    lists:member(ToolName, [
        <<"read_file">>, <<"list_files">>, <<"file_exists">>,
        <<"grep_files">>, <<"find_files">>,
        <<"git_status">>, <<"git_log">>, <<"git_diff">>,
        <<"list_models">>, <<"show_model">>,
        <<"list_skills">>, <<"load_skill">>,
        <<"search_memories">>, <<"recent_memories">>,
        <<"get_self_modules">>, <<"analyze_self">>,
        <<"get_soul_proposal">>,
        <<"list_snapshots">>,
        <<"health">>,
        <<"get_performance_trend">>, <<"get_improvements">>
    ]).

is_self_modification(ToolName) ->
    lists:member(ToolName, [
        <<"reload_module">>, <<"deploy_module">>, <<"compile_and_reload">>,
        <<"edit_file">>, <<"write_file">>,
        <<"propose_soul_edit">>, <<"apply_soul_proposal">>, <<"reject_soul_proposal">>
    ]).