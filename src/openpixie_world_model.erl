-module(openpixie_world_model).
-behaviour(gen_server).

-export([
    start_link/0,
    build_graph/0,
    impact_assessment/2,
    get_dependencies/1,
    get_dependents/1,
    get_graph_summary/0,
    get_world_model_context/1,
    refresh/0,
    status/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(STATE_FILE, "world_model.json").
-define(CONTRACTS_FILE, "CONTRACTS").

-record(state, {
    graph = #{} :: map(),
    contracts = [] :: [term()],
    graph_ts = 0 :: integer()
}).

%%===================================================================
%% API
%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

build_graph() ->
    gen_server:call(?SERVER, build_graph, 30000).

impact_assessment(Module, Functions) when is_atom(Module), is_list(Functions) ->
    gen_server:call(?SERVER, {impact_assessment, Module, Functions}, 10000).

get_dependencies(Module) when is_atom(Module) ->
    gen_server:call(?SERVER, {get_dependencies, Module}, 5000).

get_dependents(Module) when is_atom(Module) ->
    gen_server:call(?SERVER, {get_dependents, Module}, 5000).

get_graph_summary() ->
    gen_server:call(?SERVER, graph_summary, 5000).

get_world_model_context(Module) when is_atom(Module) ->
    gen_server:call(?SERVER, {world_model_context, Module}, 5000).

refresh() ->
    gen_server:call(?SERVER, build_graph, 30000).

status() ->
    gen_server:call(?SERVER, status, 5000).

%%===================================================================
%% gen_server callbacks
%%===================================================================

init([]) ->
    State = case load_state_file() of
        {ok, SavedGraph} ->
            #state{
                graph = SavedGraph,
                graph_ts = erlang:system_time(millisecond)
            };
        {error, _} ->
            case catch do_build_graph() of
                {ok, Graph} ->
                    spawn(fun() -> catch save_state_file(Graph) end),
                    #state{
                        graph = Graph,
                        graph_ts = erlang:system_time(millisecond)
                    };
                _ ->
                    #state{}
            end
    end,
    {ok, State}.

handle_call(build_graph, _From, State) ->
    case catch do_build_graph() of
        {ok, Graph} ->
            spawn(fun() -> catch save_state_file(Graph) end),
            NewTs = erlang:system_time(millisecond),
            {reply, ok, State#state{graph = Graph, graph_ts = NewTs}};
        Error ->
            {reply, {error, Error}, State}
    end;

handle_call({impact_assessment, Module, Functions}, _From, State = #state{graph = Graph}) ->
    Result = do_impact_assessment(Module, Functions, Graph),
    {reply, Result, State};

handle_call({get_dependencies, Module}, _From, State = #state{graph = Graph}) ->
    case maps:get(Module, Graph, undefined) of
        #{calls := Calls} -> {reply, {ok, Calls}, State};
        undefined -> {reply, {ok, []}, State}
    end;

handle_call({get_dependents, Module}, _From, State = #state{graph = Graph}) ->
    Dependents = maps:fold(fun(Mod, #{called_by := CB}, Acc) ->
        case lists:member(Module, CB) of
            true -> [Mod | Acc];
            false -> Acc
        end
    end, [], Graph),
    {reply, {ok, Dependents}, State};

handle_call(graph_summary, _From, State = #state{graph = Graph, graph_ts = Ts}) ->
    ModuleCount = maps:size(Graph),
    Summary = #{
        module_count => ModuleCount,
        last_built => Ts,
        modules => maps:keys(Graph)
    },
    {reply, {ok, Summary}, State};

handle_call({world_model_context, Module}, _From, State = #state{graph = Graph}) ->
    Context = build_world_model_context(Module, Graph),
    {reply, Context, State};

handle_call(status, _From, State = #state{graph = Graph, graph_ts = Ts}) ->
    {reply, #{
        module_count => maps:size(Graph),
        last_built => Ts
    }, State};

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

%%===================================================================
%% Internal: Graph Building
%%===================================================================

do_build_graph() ->
    Loaded = code:all_loaded(),
    PixieMods = lists:filter(fun({M, _}) -> is_openpixie_module(M) end, Loaded),
    Graph = lists:foldl(fun({M, _}, Acc) ->
        Calls = scan_module_calls(M),
        CalledBy = [],  %% filled in second pass
        ModInfo = #{
            calls => Calls,
            called_by => CalledBy,
            exports => get_exports(M),
            contracts => scan_module_contracts(M)
        },
        maps:put(M, ModInfo, Acc)
    end, #{}, PixieMods),
    %% Second pass: fill in called_by
    FinalGraph = fill_called_by(Graph),
    {ok, FinalGraph}.

scan_module_calls(M) ->
    try
        {_, BeamPath} = code:ensure_loaded(M),
        case BeamPath of
            preloaded -> [];
            _ ->
                case xref:m(M) of
                    {ok, #{
                        imports := Imports,
                        exports := _Exports,
                        locals := _Locals
                    }} ->
                        Filtered = [Imp || Imp <- Imports, is_openpixie_module(Imp)],
                        lists:usort(Filtered);
                    _ ->
                        %% Fallback: scan source
                        scan_calls_from_source(M)
                end
        end
    catch
        _:_ -> scan_calls_from_source(M)
    end.

scan_calls_from_source(M) ->
    Ws = openpixie_config:workspace(),
    ModBin = atom_to_binary(M, utf8),
    Path = filename:join([Ws, "src", binary_to_list(ModBin) ++ ".erl"]),
    case file:read_file(Path) of
        {ok, Content} ->
            Pattern = <<"openpixie_">>,
            Calls = extract_openpixie_calls(Content, Pattern),
            lists:usort(Calls);
        {error, _} ->
            []
    end.

extract_openpixie_calls(Content, Pattern) ->
    case binary:match(Content, Pattern) of
        nomatch -> [];
        {Pos, _} ->
            %% Find the word boundary after "openpixie_"
            {End, _} = find_word_end(Content, Pos),
            Word = binary:part(Content, Pos, End - Pos),
            Module = try binary_to_existing_atom(Word, utf8) catch _:_ -> Word end,
            Rest = binary:part(Content, End, byte_size(Content) - End),
            case is_atom(Module) andalso is_openpixie_module(Module) of
                true -> [Module | extract_openpixie_calls(Rest, Pattern)];
                false -> extract_openpixie_calls(Rest, Pattern)
            end
    end.

find_word_end(Content, Pos) ->
    find_word_end(Content, Pos, Pos).

find_word_end(Content, _Start, Pos) when Pos >= byte_size(Content) ->
    {Pos, 0};
find_word_end(Content, Start, Pos) ->
    case binary:at(Content, Pos) of
        C when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_ ->
            find_word_end(Content, Start, Pos + 1);
        $: ->
            %% module:function — skip the colon and continue for the function name
            find_word_end(Content, Start, Pos + 1);
        _ ->
            {Pos, Pos - Start}
    end.

fill_called_by(Graph) ->
    maps:map(fun(Mod, Info) ->
        CalledBy = maps:fold(fun(OtherMod, #{calls := OtherCalls}, Acc) ->
            case lists:member(Mod, OtherCalls) of
                true -> [OtherMod | Acc];
                false -> Acc
            end
        end, [], Graph),
        Info#{called_by => lists:usort(CalledBy)}
    end, Graph).

get_exports(M) ->
    try
        ExportList = M:module_info(exports),
        [#{name => F, arity => A} || {F, A} <- ExportList, F =/= module_info]
    catch
        _:_ -> []
    end.

scan_module_contracts(M) ->
    try
        {_Mod, BeamPath} = code:ensure_loaded(M),
        case BeamPath of
            preloaded -> [];
            _ ->
                case code:get_object_code(M) of
                    {_, Bin, _} ->
                        extract_specs_from_beam(Bin);
                    _ -> []
                end
        end
    catch
        _:_ -> []
    end.

extract_specs_from_beam(_Bin) ->
    %% For now, contracts come from hand-authored source
    %% Future: parse abstract code from beam to extract -spec annotations
    [].

is_openpixie_module(M) when is_atom(M) ->
    Name = atom_to_binary(M, utf8),
    binary:part(Name, 0, min(10, byte_size(Name))) =:= <<"openpixie_">>;
is_openpixie_module(_) -> false.

%%===================================================================
%% Internal: Impact Assessment
%%===================================================================

do_impact_assessment(Module, Functions, Graph) ->
    ModuleInfo = maps:get(Module, Graph, #{}),
    DirectDeps = maps:get(calls, ModuleInfo, []),
    DirectDependents = maps:get(called_by, ModuleInfo, []),
    TransitiveDependents = compute_transitive_dependents(Module, Graph, sets:new(), 3),
    ContractsAtRisk = find_contracts_at_risk(Module, Functions, Graph),
    Risk = assess_risk(Module, Functions, DirectDependents, TransitiveDependents, ContractsAtRisk),
    #{
        module => Module,
        modified_functions => Functions,
        direct_dependencies => DirectDeps,
        direct_dependents => DirectDependents,
        transitive_dependents => sets:to_list(TransitiveDependents),
        contracts_at_risk => ContractsAtRisk,
        risk => Risk
    }.

compute_transitive_dependents(_Module, _Graph, Visited, Depth) when Depth =< 0 ->
    Visited;
compute_transitive_dependents(Module, Graph, Visited, Depth) ->
    case sets:is_element(Module, Visited) of
        true -> Visited;
        false ->
            NewVisited = sets:add_element(Module, Visited),
            CalledBy = maps:get(called_by, maps:get(Module, Graph, #{}), []),
            lists:foldl(fun(Mod, Acc) ->
                compute_transitive_dependents(Mod, Graph, Acc, Depth - 1)
            end, NewVisited, CalledBy)
    end.

find_contracts_at_risk(_Module, _Functions, _Graph) ->
    %% Placeholder: in future, cross-reference function changes with contract specs
    [].

assess_risk(Module, Functions, DirectDependents, TransitiveDependents, _ContractsAtRisk) ->
    DepCount = length(DirectDependents),
    TransCount = sets:size(TransitiveDependents),
    IsSafetyCritical = is_safety_critical_module(Module),
    ModifiesCore = lists:any(fun(F) -> is_core_function(Module, F) end, Functions),
    if
        IsSafetyCritical andalso ModifiesCore -> high;
        IsSafetyCritical -> moderate;
        TransCount > 5 -> moderate;
        DepCount > 3 -> moderate;
        true -> low
    end.

is_safety_critical_module(openpixie_guardian) -> true;
is_safety_critical_module(openpixie_permissions) -> true;
is_safety_critical_module(openpixie_auth) -> true;
is_safety_critical_module(openpixie_sup) -> true;
is_safety_critical_module(openpixie_circuit_breaker) -> true;
is_safety_critical_module(_) -> false.

is_core_function(openpixie_guardian, pre_check) -> true;
is_core_function(openpixie_guardian, post_check) -> true;
is_core_function(openpixie_guardian, do_post_check) -> true;
is_core_function(openpixie_permissions, check) -> true;
is_core_function(openpixie_auth, authenticate_request) -> true;
is_core_function(openpixie_sup, init) -> true;
is_core_function(_, _) -> false.

%%===================================================================
%% Internal: World Model Context for LLM
%%===================================================================

build_world_model_context(Module, Graph) ->
    case maps:get(Module, Graph, undefined) of
        undefined ->
            <<"## World Model\n\nNo dependency data available for this module.\n">>;
        #{calls := Calls, called_by := CalledBy} ->
            CallsBin = format_module_list(Calls, <<"calls">>),
            CalledByBin = format_module_list(CalledBy, <<"called by">>),
            Risk = assess_risk(Module, [], CalledBy, sets:new(), []),
            RiskBin = atom_to_binary(Risk, utf8),
            ModBin = atom_to_binary(Module, utf8),
            <<"## World Model — `", ModBin/binary, "`\n\n"
              "### Dependency Graph\n",
              CallsBin/binary, "\n",
              CalledByBin/binary, "\n\n"
              "### Risk Level\n",
              "This module is classified as **", RiskBin/binary, "** risk for modification.\n\n"
              "Use this information to understand the impact of changes to this module.\n">>
    end.

format_module_list([], _Label) ->
    <<"">>;
format_module_list(Modules, Label) ->
    Items = iolist_to_binary([<<"`", (atom_to_binary(M, utf8))/binary, "`">> || M <- Modules]),
    <<Label/binary, ": ", Items/binary, "\n">>.

%%===================================================================
%% Internal: Persistence
%%===================================================================

save_state_file(Graph) ->
    PixieDir = openpixie_config:pixie_dir(),
    Path = filename:join(PixieDir, ?STATE_FILE),
    ok = filelib:ensure_dir(filename:join(PixieDir, "dummy")),
    Serialized = serialize_graph(Graph),
    Encoded = jsx:encode(Serialized),
    TmpPath = Path ++ ".tmp",
    ok = file:write_file(TmpPath, Encoded),
    ok = file:rename(TmpPath, Path),
    ok.

load_state_file() ->
    PixieDir = openpixie_config:pixie_dir(),
    Path = filename:join(PixieDir, ?STATE_FILE),
    case file:read_file(Path) of
        {ok, Content} ->
            try
                Decoded = jsx:decode(Content, [return_maps]),
                Graph = deserialize_graph(Decoded),
                {ok, Graph}
            catch
                _:_ -> {error, parse_error}
            end;
        {error, _} ->
            {error, not_found}
    end.

serialize_graph(Graph) ->
    maps:fold(fun(Mod, #{calls := Calls, called_by := CalledBy}, Acc) ->
        ModBin = atom_to_binary(Mod, utf8),
        CallsBin = [atom_to_binary(C, utf8) || C <- Calls],
        CalledByBin = [atom_to_binary(C, utf8) || C <- CalledBy],
        Acc#{ModBin => #{<<"calls">> => CallsBin, <<"called_by">> => CalledByBin}}
    end, #{}, Graph).

deserialize_graph(Data) when is_map(Data) ->
    maps:fold(fun(ModBin, Info, Acc) ->
        Mod = binary_to_existing_atom(ModBin, utf8),
        Calls = [binary_to_existing_atom(C, utf8) || C <- maps:get(<<"calls">>, Info, [])],
        CalledBy = [binary_to_existing_atom(C, utf8) || C <- maps:get(<<"called_by">>, Info, [])],
        Acc#{Mod => #{calls => Calls, called_by => CalledBy}}
    end, #{}, Data).
