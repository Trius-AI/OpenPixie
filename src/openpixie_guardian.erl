-module(openpixie_guardian).
-behaviour(gen_server).

-export([
    pre_check/2,
    post_check/3,
    init_snapshot/0,
    snapshot_state/0,
    status/0,
    is_guardian_relevant/2,
    start_link/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(GUARDIAN_CALL_TIMEOUT, 5000).
-define(STATE_FILE, "guardian_state.json").

-define(EXCLUDED_TOOLS, [
    <<"reject_soul_proposal">>,
    <<"deploy_module">>
]).

-define(SELF_SOURCE_SUFFIXES, [".erl", "index.html", ".js", "SKILL.md", "INTERNAL.md"]).

-define(GUARDIAN_RELEVANT_TOOLS, [
    <<"edit_file">>, <<"write_file">>,
    <<"compile_and_reload">>, <<"reload_module">>,
    <<"propose_soul_edit">>, <<"apply_soul_proposal">>,
    <<"self_improve">>
]).

-define(BASELINE_WS_CLIENT_TYPES, [
    <<"connect">>, <<"chat">>, <<"new_topic">>, <<"switch_topic">>,
    <<"list_topics">>, <<"resolve_topic">>, <<"reopen_topic">>,
    <<"delete_topic">>, <<"tool_confirm">>, <<"frontend_error">>,
    <<"heartbeat">>, <<"interrupt">>
]).

-define(BASELINE_WS_SERVER_TYPES, [
    <<"connected">>, <<"response">>, <<"chunk">>, <<"thinking">>,
    <<"stream_done">>, <<"tool_step">>, <<"tool_confirm_request">>,
    <<"tool_approved">>, <<"tool_rejected">>,
    <<"guardian_check">>, <<"guardian_result">>,
    <<"topic_created">>, <<"topic_switched">>, <<"topics_list">>,
    <<"topic_resolved">>, <<"topic_reopened">>, <<"topic_deleted">>,
    <<"topic_ended">>, <<"session_ended">>, <<"heartbeat">>,
    <<"interrupted">>, <<"error">>,
    <<"ask_user_request">>, <<"ask_user_received">>
]).

-define(BASELINE_ROUTES, [
    {<<"GET">>, <<"/health">>, <<"openpixie_http_health">>},
    {<<"POST">>, <<"/api/v1/chat">>, <<"openpixie_http_chat">>},
    {<<"GET">>, <<"/api/v1/topics">>, <<"openpixie_http_topics">>},
    {<<"POST">>, <<"/api/v1/topics">>, <<"openpixie_http_topics">>},
    {<<"DELETE">>, <<"/api/v1/topics/:id">>, <<"openpixie_http_topics">>},
    {<<"GET">>, <<"/api/v1/models">>, <<"openpixie_http_models">>},
    {<<"GET">>, <<"/api/v1/skills">>, <<"openpixie_http_skills">>},
    {<<"GET">>, <<"/api/v1/sync">>, <<"openpixie_http_sync">>},
    {<<"POST">>, <<"/api/v1/sync">>, <<"openpixie_http_sync">>},
    {<<"GET">>, <<"/api/v1/config">>, <<"openpixie_http_config">>},
    {<<"POST">>, <<"/api/v1/config">>, <<"openpixie_http_config">>},
    {<<"GET">>, <<"/api/v1/files">>, <<"openpixie_http_files">>},
    {<<"POST">>, <<"/api/v1/files">>, <<"openpixie_http_files">>},
    {<<"GET">>, <<"/api/v1/pixie-data/:name">>, <<"openpixie_http_pixie_data">>},
    {<<"GET">>, <<"/api/v1/tools">>, <<"openpixie_http_tools">>},
    {<<"GET">>, <<"/api/v1/metrics">>, <<"openpixie_http_metrics">>},
    {<<"GET">>, <<"/api/v1/metrics/:key">>, <<"openpixie_http_metrics">>},
    {<<"GET">>, <<"/api/v1/metrics/:key/:action">>, <<"openpixie_http_metrics">>},
    {<<"POST">>, <<"/api/v1/login">>, <<"openpixie_http_login">>},
    {<<"DELETE">>, <<"/api/v1/login">>, <<"openpixie_http_login">>},
    {<<"GET">>, <<"/login">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/dashboard">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/chat">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/chat/:topic_id">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/settings">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/guardian">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/files">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/skill2tool">>, <<"openpixie_http_spa">>},
    {<<"GET">>, <<"/metrics">>, <<"openpixie_http_spa">>},
    {<<"WS">>, <<"/ws">>, <<"openpixie_ws">>},
    {<<"POST">>, <<"/recover">>, <<"openpixie_http_recover">>},
    {<<"STATIC">>, <<"/">>, <<"cowboy_static">>}
]).

-record(state, {
    snapshot = #{} :: map(),
    snapshot_ts = 0 :: integer(),
    permissive = false :: boolean(),
    inconsistencies = [] :: [term()]
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

pre_check(ToolName, Args) ->
    try
        gen_server:call(?SERVER, {pre_check, ToolName, Args}, ?GUARDIAN_CALL_TIMEOUT)
    catch
        exit:{timeout, _} -> ok;
        exit:{noproc, _} -> ok;
        _:timeout -> ok
    end.

post_check(ToolName, Args, Result) ->
    try
        gen_server:call(?SERVER, {post_check, ToolName, Args, Result}, ?GUARDIAN_CALL_TIMEOUT)
    catch
        exit:{timeout, _} -> ok;
        exit:{noproc, _} -> ok;
        _:timeout -> ok
    end.

init_snapshot() ->
    try
        gen_server:call(?SERVER, init_snapshot, ?GUARDIAN_CALL_TIMEOUT)
    catch
        _:_ -> {error, unavailable}
    end.

snapshot_state() ->
    try
        gen_server:call(?SERVER, snapshot_state, ?GUARDIAN_CALL_TIMEOUT)
    catch
        _:_ -> {error, unavailable}
    end.

status() ->
    try
        gen_server:call(?SERVER, status, ?GUARDIAN_CALL_TIMEOUT)
    catch
        _:_ -> #{available => false}
    end.

is_guardian_relevant(ToolName, Args) ->
    case lists:member(ToolName, ?EXCLUDED_TOOLS) of
        true -> false;
        false ->
            case lists:member(ToolName, ?GUARDIAN_RELEVANT_TOOLS) of
                true ->
                    case ToolName of
                        <<"edit_file">> -> is_self_source_path_from_args(Args);
                        <<"write_file">> -> is_self_source_path_from_args(Args);
                        _ -> true
                    end;
                false -> false
            end
    end.

init([]) ->
    Permissive = case check_internal_doc() of
        ok -> false;
        missing ->
            openpixie_log:warn("Guardian: docs/INTERNAL.md is missing — entering permissive mode", []),
            true;
        corrupted ->
            openpixie_log:warn("Guardian: docs/INTERNAL.md is corrupted — entering permissive mode", []),
            true
    end,
    case load_state_file() of
        {ok, Snap} ->
            Inconsistencies = check_consistency(Snap),
            case Inconsistencies of
                [] -> ok;
                _ ->
                    lists:foreach(fun(Inc) ->
                        openpixie_log:warn("Guardian: inconsistency detected: ~p", [Inc])
                    end, Inconsistencies)
            end,
            {ok, #state{snapshot = Snap,
                        snapshot_ts = maps:get(timestamp, Snap, 0),
                        permissive = Permissive,
                        inconsistencies = Inconsistencies}};
        {error, _} ->
            {ok, Snap2} = build_and_save_snapshot(),
            {ok, #state{snapshot = Snap2,
                        snapshot_ts = maps:get(timestamp, Snap2, 0),
                        permissive = Permissive,
                        inconsistencies = []}}
    end.

handle_call({pre_check, ToolName, Args}, _From, State = #state{permissive = true}) ->
    case is_self_modification_tool(ToolName) of
        true ->
            openpixie_log:warn("Guardian: permissive mode but self-modification — validating ~p", [ToolName]),
            Reply = do_pre_check(ToolName, Args, State),
            {reply, Reply, State};
        false ->
            openpixie_log:warn("Guardian: permissive mode — allowing ~p without validation", [ToolName]),
            {reply, ok, State}
    end;

handle_call({pre_check, ToolName, Args}, _From, State) ->
    Reply = do_pre_check(ToolName, Args, State),
    {reply, Reply, State};

handle_call({post_check, ToolName, Args, Result}, _From, State = #state{permissive = true}) ->
    case is_self_modification_tool(ToolName) of
        true ->
            openpixie_log:warn("Guardian: permissive mode but self-modification — validating ~p", [ToolName]),
            case maps:get(success, Result, false) of
                true ->
                    {Reply, NewState} = do_post_check(ToolName, Args, Result, State),
                    {reply, Reply, NewState};
                false ->
                    {reply, ok, State}
            end;
        false ->
            {reply, ok, State}
    end;

handle_call({post_check, ToolName, Args, Result}, _From, State) ->
    case maps:get(success, Result, false) of
        true ->
            {Reply, NewState} = do_post_check(ToolName, Args, Result, State),
            {reply, Reply, NewState};
        false ->
            {reply, ok, State}
    end;

handle_call(init_snapshot, _From, State) ->
    {ok, NewSnap} = build_and_save_snapshot(),
    Inconsistencies = check_consistency(NewSnap),
    {reply, {ok, NewSnap}, State#state{snapshot = NewSnap,
                                        snapshot_ts = maps:get(timestamp, NewSnap, 0),
                                        inconsistencies = Inconsistencies}};

handle_call(snapshot_state, _From, State = #state{snapshot = Snap}) ->
    {reply, {ok, Snap}, State};

handle_call(status, _From, State = #state{snapshot = Snap, snapshot_ts = Ts,
                                           permissive = P, inconsistencies = Incs}) ->
    Modules = maps:get(modules, Snap, #{}),
    Tools = maps:get(tools, Snap, #{}),
    Reply = #{
        available => true,
        snapshot_timestamp => Ts,
        modules_tracked => maps:size(Modules),
        tools_tracked => maps:size(Tools),
        permissive => P,
        inconsistencies => Incs
    },
    {reply, Reply, State};

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

do_pre_check(ToolName, Args, #state{snapshot = Snap}) ->
    case ToolName of
        <<"edit_file">> ->
            pre_check_edit_file(Args, Snap);
        <<"write_file">> ->
            pre_check_write_file(Args, Snap);
        <<"compile_and_reload">> ->
            pre_check_compile_and_reload(Args, Snap);
        <<"reload_module">> ->
            pre_check_reload_module(Args, Snap);
        <<"propose_soul_edit">> ->
            ok;
        <<"apply_soul_proposal">> ->
            ok;
        _ ->
            ok
    end.

pre_check_edit_file(Args, _Snap) ->
    Path = maps:get(<<"path">>, Args, <<"">>),
    case is_self_source_path(Path) of
        false -> ok;
        true ->
            case is_critical_system_file(Path) of
                true ->
                    {reject, <<"Editing this critical system file may break the system on restart. Use a different approach.">>};
                false ->
                    OldString = maps:get(<<"old_string">>, Args, <<"">>),
                    case removes_contract_function(Path, OldString) of
                        true ->
                            {warn, <<"This edit may remove a contract function. Verify that the function is no longer needed after the edit.">>};
                        false ->
                            case is_new_erlang_module(Path) of
                                true -> ok;
                                false -> ok
                            end
                    end
            end
    end.

pre_check_write_file(Args, _Snap) ->
    Path = maps:get(<<"path">>, Args, <<"">>),
    case is_self_source_path(Path) of
        false -> ok;
        true ->
            case is_critical_system_file(Path) of
                true ->
                    {reject, <<"Writing to this critical system file may break the system on restart. Use a different approach.">>};
                false ->
                    Ws = list_to_binary(openpixie_config:workspace()),
                    RelPath = case binary:match(Path, Ws) of
                        {Pos, _Len} ->
                            PrefixLen = byte_size(Ws),
                            case binary:part(Path, Pos + PrefixLen, byte_size(Path) - Pos - PrefixLen) of
                                <<$/, Rest/binary>> -> Rest;
                                R -> R
                            end;
                        _ -> Path
                    end,
                    case is_new_erlang_module(RelPath) of
                        true ->
                            {warn, <<"New module detected. After compile_and_reload, you will likely need to: "
                                     "(1) Add the module to openpixie_sup if it is a worker/supervisor, "
                                     "(2) Add dispatch entries in openpixie_tools:dispatch/2 if it exposes tools, "
                                     "(3) Add schema entries in the module's schema/0, "
                                     "(4) Add validation in openpixie_tools_schema, "
                                     "(5) Add permission rules in openpixie_permissions if applicable, "
                                     "(6) Update docs/INTERNAL.md.">>};
                        false ->
                            ok
                    end
            end
    end.

pre_check_compile_and_reload(Args, _Snap) ->
    _File = maps:get(<<"file">>, Args, <<"">>),
    ok.

pre_check_reload_module(Args, _Snap) ->
    _Module = maps:get(<<"module">>, Args, <<"">>),
    ok.

do_post_check(ToolName, Args, Result, State = #state{snapshot = OldSnap}) ->
    DocChanges = case ToolName of
        <<"edit_file">> -> post_check_file_edit(Args, Result);
        <<"write_file">> -> post_check_file_write(Args, Result);
        <<"compile_and_reload">> -> post_check_compile(Args, Result, OldSnap);
        <<"reload_module">> -> post_check_reload(Args, Result, OldSnap);
        <<"propose_soul_edit">> -> [];
        <<"apply_soul_proposal">> -> post_check_soul_apply(Result);
        _ -> []
    end,
    {ok, NewSnap} = build_and_save_snapshot(),
    StateChanges = diff_snapshots(OldSnap, NewSnap),
    AllChanges = DocChanges ++ StateChanges,
    apply_doc_updates(AllChanges),
    case AllChanges of
        [] -> {ok, State#state{snapshot = NewSnap, snapshot_ts = maps:get(timestamp, NewSnap, 0)}};
        _ -> {{update_doc, AllChanges}, State#state{snapshot = NewSnap, snapshot_ts = maps:get(timestamp, NewSnap, 0)}}
    end.

post_check_file_edit(Args, _Result) ->
    Path = maps:get(<<"path">>, Args, <<"">>),
    case is_self_source_path(Path) of
        false -> [];
        true ->
            case filename:extension(binary_to_list(Path)) of
                ".erl" -> do_erl_post_check(Path);
                ".html" -> do_html_post_check(Path);
                _ -> []
            end
    end.

post_check_file_write(Args, _Result) ->
    Path = maps:get(<<"path">>, Args, <<"">>),
    case is_self_source_path(Path) of
        false -> [];
        true ->
            case filename:extension(binary_to_list(Path)) of
                ".erl" -> do_erl_post_check(Path);
                ".html" -> do_html_post_check(Path);
                _ -> []
            end
    end.

do_erl_post_check(Path) ->
    ModuleName = path_to_module(Path),
    case code:is_loaded(ModuleName) of
        false -> [];
        _ ->
            try
                Exports = ModuleName:module_info(exports),
                Required = required_exports(ModuleName),
                Missing = lists:filter(fun({F, A}) ->
                    not lists:member({F, A}, Exports)
                end, Required),
                case Missing of
                    [] -> [];
                    _ ->
                        MissingStr = iolist_to_binary([io_lib:format("~p/~p", [F, A]) || {F, A} <- Missing]),
                        openpixie_log:error("Guardian: module ~p missing required exports: ~s", [ModuleName, MissingStr]),
                        [{contract_violation, ModuleName, Missing}]
                end
            catch
                _:Reason ->
                    openpixie_log:warn("Guardian: could not check exports for ~p: ~p", [ModuleName, Reason]),
                    []
            end
    end.

do_html_post_check(_Path) ->
    [].

post_check_compile(Args, _Result, OldSnap) ->
    File = maps:get(<<"file">>, Args, <<"">>),
    ModuleName = path_to_module(File),
    try
        Exports = ModuleName:module_info(exports),
        OldModules = maps:get(modules, OldSnap, #{}),
        ModuleBin = atom_to_binary(ModuleName, utf8),
        OldExports = maps:get(ModuleBin, OldModules, []),
        _Removed = find_removed_exports(OldExports, Exports),
        Required = required_exports(ModuleName),
        Missing = lists:filter(fun({F, A}) ->
            not lists:member({F, A}, Exports)
        end, Required),
        case Missing of
            [] -> [];
            _ ->
                openpixie_log:error("Guardian: after compile, module ~p missing required exports", [ModuleName]),
                [{contract_violation, ModuleName, Missing}]
        end
    catch
        _:Reason ->
            openpixie_log:warn("Guardian: post compile check failed for ~p: ~p", [ModuleName, Reason]),
            []
    end.

post_check_reload(Args, _Result, OldSnap) ->
    ModuleBin = maps:get(<<"module">>, Args, <<"">>),
    try
        ModuleName = binary_to_existing_atom(ModuleBin, utf8),
        Exports = ModuleName:module_info(exports),
        _OldModules = maps:get(modules, OldSnap, #{}),
        _OldExports = maps:get(ModuleBin, _OldModules, []),
        Required = required_exports(ModuleName),
        Missing = lists:filter(fun({F, A}) ->
            not lists:member({F, A}, Exports)
        end, Required),
        case Missing of
            [] -> [];
            _ ->
                openpixie_log:error("Guardian: after reload, module ~p missing required exports", [ModuleBin]),
                [{contract_violation, ModuleName, Missing}]
        end
    catch
        _:_ -> []
    end.

post_check_soul_apply(_Result) ->
    [].

required_exports(openpixie_ws) ->
    [{init, 2}, {websocket_init, 1}, {websocket_handle, 2},
     {websocket_info, 2}, {terminate, 3}];
required_exports(Mod) ->
    try
        Behaviours = proplists:get_value(behaviour, Mod:module_info(attributes), []),
        case Behaviours of
            _ when is_list(Behaviours) ->
                IsGenServer = lists:member(gen_server, Behaviours),
                IsSupervisor = lists:member(supervisor, Behaviours),
                case {IsGenServer, IsSupervisor} of
                    {true, false} ->
                        [{init, 1}, {handle_call, 3}, {handle_cast, 2},
                         {handle_info, 2}, {terminate, 2}, {code_change, 3}];
                    {false, true} ->
                        [{init, 1}];
                    {true, true} ->
                        [{init, 1}, {handle_call, 3}, {handle_cast, 2},
                         {handle_info, 2}, {terminate, 2}, {code_change, 3}];
                    _ ->
                        case is_cowboy_handler(Mod) of
                            true -> [{init, 2}];
                            false -> []
                        end
                end;
            _ ->
                case is_cowboy_handler(Mod) of
                    true -> [{init, 2}];
                    false -> []
                end
        end
    catch
        _:_ -> []
    end.

is_cowboy_handler(Mod) ->
    case code:which(Mod) of
        Path when is_list(Path) ->
            case file:read_file(Path) of
                {ok, _} ->
                    Exports = Mod:module_info(exports),
                    lists:member({init, 2}, Exports);
                _ -> false
            end;
        _ -> false
    end.

is_self_source_path(PathBin) when is_binary(PathBin) ->
    Lower = string:lowercase(binary_to_list(PathBin)),
    lists:any(fun(Suffix) -> lists:suffix(Suffix, Lower) end, ?SELF_SOURCE_SUFFIXES);
is_self_source_path(PathStr) when is_list(PathStr) ->
    is_self_source_path(list_to_binary(PathStr)).

is_self_source_path_from_args(Args) when is_map(Args) ->
    Path = maps:get(<<"path">>, Args, <<"">>),
    is_self_source_path(Path);
is_self_source_path_from_args(_) ->
    false.

is_self_modification_tool(ToolName) ->
    lists:member(ToolName, [
        <<"reload_module">>, <<"deploy_module">>, <<"compile_and_reload">>,
        <<"edit_file">>, <<"write_file">>,
        <<"propose_soul_edit">>, <<"apply_soul_proposal">>, <<"reject_soul_proposal">>,
        <<"register_tool">>, <<"unregister_tool">>,
        <<"sync_import">>
    ]).

is_critical_system_file(Path) ->
    Lower = string:lowercase(binary_to_list(case is_binary(Path) of true -> Path; false -> list_to_binary(Path) end)),
    lists:any(fun(P) -> string:find(Lower, P) =/= nomatch end,
              ["config/sys.config", "rebar.config", ".erlang.cookie", "vm.args",
               "openpixie_http_recover.erl", "openpixie_guardian.erl", "openpixie_auth.erl",
               "openpixie_http_files.erl", "openpixie_http_login.erl"]).

is_new_erlang_module(Path) ->
    Lower = string:lowercase(binary_to_list(case is_binary(Path) of true -> Path; false -> list_to_binary(Path) end)),
    case lists:suffix(".erl", Lower) of
        false -> false;
        true ->
            Filename = filename:basename(Lower, ".erl"),
            lists:prefix("openpixie_", Filename)
    end.

removes_contract_function(_Path, _OldString) ->
    false.

path_to_module(Path) when is_binary(Path) ->
    Base = filename:basename(binary_to_list(Path), ".erl"),
    try
        list_to_existing_atom(Base)
    catch
        _:_ -> list_to_atom(Base)
    end;
path_to_module(Path) when is_list(Path) ->
    path_to_module(list_to_binary(Path)).

find_removed_exports(OldExports, NewExports) when is_list(OldExports), is_list(NewExports) ->
    OldExportStrs = [export_to_bin(E) || E <- OldExports],
    NewExportStrs = [export_to_bin(E) || E <- NewExports],
    OldExportStrs -- NewExportStrs.

export_to_bin({F, A}) when is_atom(F), is_integer(A) ->
    list_to_binary(atom_to_list(F) ++ "/" ++ integer_to_list(A));
export_to_bin(B) when is_binary(B) -> B.

diff_snapshots(OldSnap, NewSnap) ->
    OldModules = maps:get(modules, OldSnap, #{}),
    NewModules = maps:get(modules, NewSnap, #{}),
    NewModuleKeys = maps:keys(NewModules) -- maps:keys(OldModules),
    NewModuleChanges = [{new_module, Mod, maps:get(Mod, NewModules, [])} || Mod <- NewModuleKeys],

    OldTools = maps:get(tools, OldSnap, #{}),
    NewTools = maps:get(tools, NewSnap, #{}),
    NewToolKeys = maps:keys(NewTools) -- maps:keys(OldTools),
    NewToolChanges = [{new_tool, Tool, maps:get(Tool, NewTools, #{})} || Tool <- NewToolKeys],

    OldPermsSM = maps:get(permission_self_mod, OldSnap, []),
    NewPermsSM = maps:get(permission_self_mod, NewSnap, []),
    NewPermsSMChanges = case NewPermsSM -- OldPermsSM of
        [] -> [];
        AddedSM -> [{new_permission_self_mod, AddedSM}]
    end,

    OldPermsRO = maps:get(permission_readonly, OldSnap, []),
    NewPermsRO = maps:get(permission_readonly, NewSnap, []),
    NewPermsROChanges = case NewPermsRO -- OldPermsRO of
        [] -> [];
        AddedRO -> [{new_permission_readonly, AddedRO}]
    end,

    OldWsClient = maps:get(ws_types_client, OldSnap, []),
    NewWsClient = maps:get(ws_types_client, NewSnap, []),
    NewWsClientChanges = case NewWsClient -- OldWsClient of
        [] -> [];
        AddedWC -> [{new_ws_client_type, AddedWC}]
    end,

    OldWsServer = maps:get(ws_types_server, OldSnap, []),
    NewWsServer = maps:get(ws_types_server, NewSnap, []),
    NewWsServerChanges = case NewWsServer -- OldWsServer of
        [] -> [];
        AddedWS -> [{new_ws_server_type, AddedWS}]
    end,

    OldConfigKeys = maps:get(config_keys, OldSnap, []),
    NewConfigKeys = maps:get(config_keys, NewSnap, []),
    NewConfigChanges = case NewConfigKeys -- OldConfigKeys of
        [] -> [];
        AddedCK -> [{new_config_key, AddedCK}]
    end,

    OldRoutes = maps:get(routes, OldSnap, []),
    NewRoutes = maps:get(routes, NewSnap, []),
    NewRouteChanges = diff_routes(OldRoutes, NewRoutes),

    NewModuleChanges ++ NewToolChanges ++ NewPermsSMChanges ++
        NewPermsROChanges ++ NewWsClientChanges ++ NewWsServerChanges ++
        NewConfigChanges ++ NewRouteChanges.

diff_routes(OldRoutes, NewRoutes) ->
    OldSet = sets:from_list(OldRoutes),
    NewSet = sets:from_list(NewRoutes),
    Added = sets:to_list(sets:subtract(NewSet, OldSet)),
    [{new_route, R} || R <- Added].

apply_doc_updates([]) -> ok;
apply_doc_updates(Changes) ->
    Ws = openpixie_config:workspace(),
    DocPath = filename:join([Ws, "docs", "INTERNAL.md"]),
    case file:read_file(DocPath) of
        {ok, Content} ->
            Updated = apply_changes_to_doc(Content, Changes),
            TmpPath = DocPath ++ ".guardian.tmp",
            ok = file:write_file(TmpPath, Updated),
            ok = file:rename(TmpPath, DocPath),
            Ts = erlang:system_time(millisecond),
            openpixie_log:info("Guardian: updated docs/INTERNAL.md with ~p changes at ~p", [length(Changes), Ts]);
        {error, Reason} ->
            openpixie_log:warn("Guardian: could not update docs/INTERNAL.md: ~p", [Reason])
    end.

apply_changes_to_doc(Content, Changes) ->
    lists:foldl(fun(Change, Acc) ->
        apply_single_change(Acc, Change)
    end, Content, Changes).

apply_single_change(Content, {new_module, Mod, _Exports}) ->
    ModuleBin = case is_atom(Mod) of true -> atom_to_binary(Mod, utf8); false -> Mod end,
    Row = <<"\n| `", ModuleBin/binary, "` | worker/supervisor | (added by Guardian — fill in description) |">>,
    insert_after_section(Content, <<"## 2. Module Index">>, Row);
apply_single_change(Content, {new_tool, Tool, Info}) ->
    ToolBin = case is_binary(Tool) of true -> Tool; false -> atom_to_binary(Tool, utf8) end,
    ModBin = case maps:get(module, Info, undefined) of
        undefined -> <<"unknown">>;
        M when is_atom(M) -> atom_to_binary(M, utf8);
        M -> M
    end,
    CatBin = case maps:get(category, Info, undefined) of
        undefined -> <<"unknown">>;
        C when is_atom(C) -> atom_to_binary(C, utf8);
        C -> C
    end,
    Row = <<"\n| `", ToolBin/binary, "` | `", ModBin/binary, "` | ", CatBin/binary, " |">>,
    insert_after_section(Content, <<"### 6.1 Tool Registry">>, Row);
apply_single_change(Content, {new_route, {Method, Path, _Handler}}) ->
    Row = <<"\n| ", Method/binary, " | `", Path/binary, "` | Yes | (added by Guardian) |">>,
    insert_after_section(Content, <<"### 4.2 Endpoints">>, Row);
apply_single_change(Content, {new_ws_client_type, Types}) ->
    Rows = iolist_to_binary([<<"\n| `", T/binary, "` | (added by Guardian — fill in description) |">> || T <- Types]),
    insert_after_section(Content, <<"### 3.3 Client">>, Rows);
apply_single_change(Content, {new_ws_server_type, Types}) ->
    Rows = iolist_to_binary([<<"\n| `", T/binary, "` | (added by Guardian — fill in description) |">> || T <- Types]),
    insert_after_section(Content, <<"### 3.4 Server">>, Rows);
apply_single_change(Content, {new_config_key, Keys}) ->
    Rows = iolist_to_binary([<<"\n| `", K/binary, "` | (default) | (added by Guardian — fill in) |">> || K <- Keys]),
    insert_after_section(Content, <<"### 8.4 Key Configuration Defaults">>, Rows);
apply_single_change(Content, {new_permission_self_mod, Tools}) ->
    append_to_list_in_section(Content, <<"**Self-modification tools**">>, Tools);
apply_single_change(Content, {new_permission_readonly, Tools}) ->
    append_to_list_in_section(Content, <<"**Readonly tools**">>, Tools);
apply_single_change(Content, {contract_violation, _Mod, _Missing}) ->
    Content;
apply_single_change(Content, _) ->
    Content.

insert_after_section(Content, SectionHeader, Insertion) ->
    case binary:match(Content, SectionHeader) of
        {Pos, _Len} ->
            AfterHeader = Pos + byte_size(SectionHeader),
            case find_next_table_row(Content, AfterHeader) of
                {ok, RowStart} ->
                    case find_table_end(Content, RowStart) of
                        {ok, TableEnd} ->
                            Prefix = binary:part(Content, 0, TableEnd),
                            Suffix = binary:part(Content, TableEnd, byte_size(Content) - TableEnd),
                            <<Prefix/binary, Insertion/binary, Suffix/binary>>;
                        error ->
                            <<Content/binary, Insertion/binary>>
                    end;
                error ->
                    <<Content/binary, Insertion/binary>>
            end;
        nomatch ->
            <<Content/binary, Insertion/binary>>
    end.

find_next_table_row(Content, Start) ->
    case binary:match(Content, <<"|">>, [{scope, {Start, byte_size(Content) - Start}}]) of
        {Pos, _} -> {ok, Pos};
        nomatch -> error
    end.

find_table_end(Content, Start) ->
    find_table_end(Content, Start, Start).

find_table_end(Content, _Start, Pos) when Pos >= byte_size(Content) -> {ok, Pos};
find_table_end(Content, Start, Pos) ->
    case binary:at(Content, Pos) of
        $\n ->
        case Pos + 1 < byte_size(Content) of
            true ->
                case binary:at(Content, Pos + 1) of
                    $| -> find_table_end(Content, Start, Pos + 1);
                    _ -> {ok, Pos + 1}
                end;
            false -> {ok, Pos + 1}
        end;
        _ -> find_table_end(Content, Start, Pos + 1)
    end.

append_to_list_in_section(Content, Marker, Items) ->
    ItemStrs = [<<", `", I/binary, "`">> || I <- Items],
    Insertion = iolist_to_binary(ItemStrs),
    case binary:match(Content, Marker) of
        {Pos, Len} ->
            AfterMarker = Pos + Len,
            case binary:match(Content, <<"\n">>, [{scope, {AfterMarker, byte_size(Content) - AfterMarker}}]) of
                {EolPos, _} ->
                    Prefix = binary:part(Content, 0, EolPos),
                    Suffix = binary:part(Content, EolPos, byte_size(Content) - EolPos),
                    <<Prefix/binary, Insertion/binary, Suffix/binary>>;
                nomatch ->
                    <<Content/binary, Insertion/binary>>
            end;
        nomatch ->
            Content
    end.

build_and_save_snapshot() ->
    Snap = build_snapshot(),
    ok = save_state_file(Snap),
    {ok, Snap}.

build_snapshot() ->
    #{
        version => 1,
        timestamp => erlang:system_time(millisecond),
        modules => snapshot_modules(),
        tools => snapshot_tools(),
        routes => snapshot_routes(),
        ws_types_client => snapshot_ws_client_types(),
        ws_types_server => snapshot_ws_server_types(),
        config_keys => snapshot_config_keys(),
        permission_self_mod => snapshot_perm_self_mod(),
        permission_readonly => snapshot_perm_readonly()
    }.

snapshot_modules() ->
    Loaded = code:all_loaded(),
    PixieMods = lists:filter(fun({M, _}) ->
        case atom_to_binary(M, utf8) of
            <<"openpixie", _/binary>> -> true;
            _ -> false
        end
    end, Loaded),
    maps:from_list(lists:map(fun({M, _}) ->
        ModBin = atom_to_binary(M, utf8),
        Exports = try
            ExportList = M:module_info(exports),
            [#{name => list_to_binary(atom_to_list(F)), arity => A} || {F, A} <- ExportList]
        catch
            _:_ -> []
        end,
        {ModBin, Exports}
    end, PixieMods)).

snapshot_tools() ->
    Schemas = try openpixie_tools:tool_schema() catch _:_ -> [] end,
    lists:foldl(fun(Schema, Acc) ->
        case Schema of
            #{function := #{name := Name0}} ->
                Name = if is_atom(Name0) -> atom_to_binary(Name0, utf8); is_binary(Name0) -> Name0; true -> iolist_to_binary(io_lib:format("~p", [Name0])) end,
                Cat = case tool_category(Name) of
                    undefined -> <<"unknown">>;
                    C -> C
                end,
                Mod = case tool_module(Name) of
                    undefined -> <<"unknown">>;
                    M -> M
                end,
                Acc#{Name => #{module => Mod, category => Cat}};
            _ ->
                Acc
        end
    end, #{}, Schemas).

snapshot_routes() ->
    lists:map(fun({Method, Path, Handler}) ->
        #{method => Method, path => Path, handler => Handler}
    end, ?BASELINE_ROUTES).

snapshot_ws_client_types() ->
    scan_ws_types_from_source(<<"openpixie_ws">>, client).

snapshot_ws_server_types() ->
    scan_ws_types_from_source(<<"openpixie_ws">>, server).

snapshot_config_keys() ->
    try
        Exports = openpixie_config:module_info(exports),
        [list_to_binary(atom_to_list(F)) ++ "/" ++ integer_to_list(A) || {F, A} <- Exports]
    catch
        _:_ -> []
    end.

snapshot_perm_self_mod() ->
    [<<"reload_module">>, <<"deploy_module">>, <<"compile_and_reload">>,
     <<"edit_file">>, <<"write_file">>,
     <<"propose_soul_edit">>, <<"apply_soul_proposal">>, <<"reject_soul_proposal">>].

snapshot_perm_readonly() ->
    [<<"read_file">>, <<"list_files">>, <<"file_exists">>,
     <<"grep_files">>, <<"find_files">>,
     <<"git_status">>, <<"git_log">>, <<"git_diff">>,
     <<"list_models">>, <<"show_model">>,
     <<"list_skills">>, <<"load_skill">>,
     <<"search_memories">>, <<"recent_memories">>,
     <<"get_self_modules">>, <<"analyze_self">>,
     <<"get_soul_proposal">>,
     <<"list_snapshots">>,
     <<"health">>,
     <<"get_performance_trend">>, <<"get_improvements">>].

scan_ws_types_from_source(ModuleBin, Direction) ->
    Ws = openpixie_config:workspace(),
    SrcPath = filename:join([Ws, "src", binary_to_list(ModuleBin) ++ ".erl"]),
    case file:read_file(SrcPath) of
        {ok, SrcContent} ->
            case Direction of
                client ->
                    ClientPatterns = re:run(SrcContent, <<"\"type\"\\s*=>\\s*<<\"([^\"]+)\">>">>,
                                            [global, {capture, [1], binary}]),
                    case ClientPatterns of
                        {match, Matches} ->
                            case re:run(SrcContent, <<"<<\"([^\"]+)\">>.*=>.*handle_">>,
                                                [global, {capture, [1], binary}]) of
                                {match, HandlerMatches} ->
                                    HandleTypes = [T || [T] <- HandlerMatches],
                                    SendTypes = [T || [T] <- Matches],
                                    lists:usort(HandleTypes ++ SendTypes);
                                nomatch ->
                                    [T || [T] <- Matches]
                            end;
                        nomatch ->
                            baseline_ws_types(client)
                    end;
                server ->
                    ServerPatterns = re:run(SrcContent,
                                            <<"{type\\s*=>\\s*<<\"([^\"]+)\">>">>,
                                            [global, {capture, [1], binary}]),
                    case ServerPatterns of
                        {match, Matches} ->
                            lists:usort([T || [T] <- Matches]);
                        nomatch ->
                            baseline_ws_types(server)
                    end
            end;
        {error, _} ->
            baseline_ws_types(Direction)
    end.

baseline_ws_types(client) -> ?BASELINE_WS_CLIENT_TYPES;
baseline_ws_types(server) -> ?BASELINE_WS_SERVER_TYPES.

tool_category(<<"read_file">>) -> <<"file">>;
tool_category(<<"write_file">>) -> <<"file">>;
tool_category(<<"edit_file">>) -> <<"file">>;
tool_category(<<"create_directory">>) -> <<"file">>;
tool_category(<<"list_files">>) -> <<"file">>;
tool_category(<<"file_exists">>) -> <<"file">>;
tool_category(<<"verify_file">>) -> <<"file">>;
tool_category(<<"git_status">>) -> <<"git">>;
tool_category(<<"git_diff">>) -> <<"git">>;
tool_category(<<"git_log">>) -> <<"git">>;
tool_category(<<"git_add">>) -> <<"git">>;
tool_category(<<"git_commit">>) -> <<"git">>;
tool_category(<<"git_branch">>) -> <<"git">>;
tool_category(<<"git_stash">>) -> <<"git">>;
tool_category(<<"git_pull">>) -> <<"git">>;
tool_category(<<"git_push">>) -> <<"git">>;
tool_category(<<"git_remote">>) -> <<"git">>;
tool_category(<<"run_command">>) -> <<"command">>;
tool_category(<<"grep_files">>) -> <<"search">>;
tool_category(<<"find_files">>) -> <<"search">>;
tool_category(<<"search_memories">>) -> <<"memory">>;
tool_category(<<"recent_memories">>) -> <<"memory">>;
tool_category(<<"ask_user">>) -> <<"interaction">>;
tool_category(<<"sync_export">>) -> <<"self-modification">>;
tool_category(<<"sync_import">>) -> <<"self-modification">>;
tool_category(<<"register_tool">>) -> <<"self-modification">>;
tool_category(<<"unregister_tool">>) -> <<"self-modification">>;
tool_category(<<"list_skills">>) -> <<"skills">>;
tool_category(<<"load_skill">>) -> <<"skills">>;
tool_category(<<"compile_and_reload">>) -> <<"self-modification">>;
tool_category(<<"reload_module">>) -> <<"self-modification">>;
tool_category(<<"get_self_modules">>) -> <<"self-modification">>;
tool_category(<<"analyze_self">>) -> <<"self-modification">>;
tool_category(<<"list_models">>) -> <<"self-modification">>;
tool_category(<<"show_model">>) -> <<"self-modification">>;
tool_category(<<"propose_soul_edit">>) -> <<"self-modification">>;
tool_category(<<"get_soul_proposal">>) -> <<"self-modification">>;
tool_category(<<"apply_soul_proposal">>) -> <<"self-modification">>;
tool_category(<<"reject_soul_proposal">>) -> <<"self-modification">>;
tool_category(<<"get_performance_trend">>) -> <<"metacognitive">>;
tool_category(<<"get_improvements">>) -> <<"metacognitive">>;
tool_category(<<"save_snapshot">>) -> <<"metacognitive">>;
tool_category(<<"list_snapshots">>) -> <<"metacognitive">>;
tool_category(<<"load_snapshot">>) -> <<"metacognitive">>;
tool_category(_) -> undefined.

tool_module(Name) ->
    DispatchMap = #{
        <<"read_file">> => <<"openpixie_tools_file">>,
        <<"write_file">> => <<"openpixie_tools_file">>,
        <<"edit_file">> => <<"openpixie_tools_file">>,
        <<"create_directory">> => <<"openpixie_tools_file">>,
        <<"list_files">> => <<"openpixie_tools_file">>,
        <<"file_exists">> => <<"openpixie_tools_file">>,
        <<"verify_file">> => <<"openpixie_tools_file">>,
        <<"git_status">> => <<"openpixie_tools_git">>,
        <<"git_diff">> => <<"openpixie_tools_git">>,
        <<"git_log">> => <<"openpixie_tools_git">>,
        <<"git_add">> => <<"openpixie_tools_git">>,
        <<"git_commit">> => <<"openpixie_tools_git">>,
        <<"git_branch">> => <<"openpixie_tools_git">>,
        <<"git_stash">> => <<"openpixie_tools_git">>,
        <<"git_pull">> => <<"openpixie_tools_git">>,
        <<"git_push">> => <<"openpixie_tools_git">>,
        <<"git_remote">> => <<"openpixie_tools_git">>,
        <<"run_command">> => <<"openpixie_tools_command">>,
        <<"grep_files">> => <<"openpixie_tools_search">>,
        <<"find_files">> => <<"openpixie_tools_search">>,
        <<"search_memories">> => <<"openpixie_tools_memory">>,
        <<"recent_memories">> => <<"openpixie_tools_memory">>,
        <<"list_skills">> => <<"openpixie_tools_skills">>,
        <<"load_skill">> => <<"openpixie_tools_skills">>,
        <<"compile_and_reload">> => <<"openpixie_tools_self">>,
        <<"reload_module">> => <<"openpixie_tools_self">>,
        <<"get_self_modules">> => <<"openpixie_tools_self">>,
        <<"analyze_self">> => <<"openpixie_tools_self">>,
        <<"list_models">> => <<"openpixie_tools_self">>,
        <<"show_model">> => <<"openpixie_tools_self">>,
        <<"propose_soul_edit">> => <<"openpixie_tools_self">>,
        <<"get_soul_proposal">> => <<"openpixie_tools_self">>,
        <<"apply_soul_proposal">> => <<"openpixie_tools_self">>,
        <<"reject_soul_proposal">> => <<"openpixie_tools_self">>,
        <<"get_performance_trend">> => <<"openpixie_tools_meta">>,
        <<"get_improvements">> => <<"openpixie_tools_meta">>,
        <<"save_snapshot">> => <<"openpixie_tools_meta">>,
        <<"list_snapshots">> => <<"openpixie_tools_meta">>,
        <<"ask_user">> => <<"openpixie_tools_ask">>,
        <<"sync_export">> => <<"openpixie_tools_sync">>,
        <<"sync_import">> => <<"openpixie_tools_sync">>,
        <<"register_tool">> => <<"openpixie_tools_self">>,
        <<"unregister_tool">> => <<"openpixie_tools_self">>,
        <<"load_snapshot">> => <<"openpixie_tools_meta">>
    },
    maps:get(Name, DispatchMap, undefined).

check_consistency(Snap) ->
    Inconsistencies = [],
    Tools = maps:get(tools, Snap, #{}),
    PermsSM = maps:get(permission_self_mod, Snap, []),
    PermsRO = maps:get(permission_readonly, Snap, []),
    PhantomSM = [T || T <- PermsSM, not maps:is_key(T, Tools)],
    PhantomRO = [T || T <- PermsRO, not maps:is_key(T, Tools)],
    Inconsistencies2 = case PhantomSM of
        [] -> Inconsistencies;
        _ -> [{phantom_self_mod_tool, PhantomSM} | Inconsistencies]
    end,
    Inconsistencies3 = case PhantomRO of
        [] -> Inconsistencies2;
        _ -> [{phantom_readonly_tool, PhantomRO} | Inconsistencies2]
    end,
    DispatchToolNames = maps:keys(Tools),
    UnlistedSM = [T || T <- DispatchToolNames, not lists:member(T, PermsSM), not lists:member(T, PermsRO)],
    Inconsistencies4 = case UnlistedSM of
        [] -> Inconsistencies3;
        _ -> [{tool_without_permission_entry, UnlistedSM} | Inconsistencies3]
    end,
    Inconsistencies4.

check_internal_doc() ->
    Ws = openpixie_config:workspace(),
    DocPath = filename:join([Ws, "docs", "INTERNAL.md"]),
    case file:read_file(DocPath) of
        {ok, Content} when byte_size(Content) > 0 -> ok;
        {ok, _} -> corrupted;
        {error, enoent} -> missing;
        {error, _} -> corrupted
    end.

load_state_file() ->
    PixieDir = openpixie_config:pixie_dir(),
    Path = filename:join(PixieDir, ?STATE_FILE),
    case file:read_file(Path) of
        {ok, Content} ->
            try
                Decoded = jsx:decode(Content, [return_maps]),
                case maps:get(version, Decoded, undefined) of
                    1 -> {ok, Decoded};
                    _ -> {error, bad_version}
                end
            catch
                _:_ -> {error, parse_error}
            end;
        {error, enoent} ->
            {error, not_found};
        {error, Reason} ->
            {error, Reason}
    end.

save_state_file(Snap) ->
    PixieDir = openpixie_config:pixie_dir(),
    Path = filename:join(PixieDir, ?STATE_FILE),
    ok = filelib:ensure_dir(filename:join(PixieDir, "dummy")),
    Encoded = jsx:encode(Snap),
    TmpPath = Path ++ ".tmp",
    ok = file:write_file(TmpPath, Encoded),
    ok = file:rename(TmpPath, Path),
    ok.