-module(openpixie_tools).
-export([tool_schema/0, execute/2, execute/3, dispatch/2]).

tool_schema() ->
    static_tool_schemas() ++
    openpixie_tool_registry:list_schemas().

static_tool_schemas() ->
    openpixie_tools_file:schema() ++
    openpixie_tools_git:schema() ++
    openpixie_tools_command:schema() ++
    openpixie_tools_search:schema() ++
    openpixie_tools_memory:schema() ++
    openpixie_tools_skills:schema() ++
    openpixie_tools_self:schema() ++
    openpixie_tools_meta:schema() ++
    openpixie_tools_ask:schema() ++
    openpixie_tools_sync:schema() ++
    openpixie_tools_push:schema().

execute(ToolName, Args) ->
    execute(ToolName, Args, #{}).

execute(ToolName, Args, Opts) ->
    case openpixie_tools_schema:validate(ToolName, Args) of
        {error, Missing} -> #{success => false, error => validation_error, missing => Missing};
        {ok, ValidatedArgs} ->
            case openpixie_permissions:check(ToolName, ValidatedArgs) of
                {allow, _Reason} ->
                    guardian_dispatch(ToolName, ValidatedArgs, Opts);
                {deny, Reason} ->
                    #{success => false, error => permission_denied, reason => Reason};
                {ask, Reason} ->
                    Confirmation = maps:get(confirmation, Opts, auto_deny),
                    case Confirmation of
                        approved ->
                            guardian_dispatch(ToolName, ValidatedArgs, Opts);
                        auto_deny ->
                            #{success => false, error => requires_confirmation,
                              reason => Reason, tool => ToolName}
                    end;
                {error, _} = Err ->
                    #{success => false, error => permission_error, reason => Err}
            end
    end.

guardian_dispatch(ToolName, ValidatedArgs, _Opts) ->
    case openpixie_guardian:is_guardian_relevant(ToolName, ValidatedArgs) of
        true ->
            case openpixie_guardian:pre_check(ToolName, ValidatedArgs) of
                ok ->
                    Result = dispatch(ToolName, ValidatedArgs),
                    openpixie_guardian:post_check(ToolName, ValidatedArgs, Result),
                    Result;
                {reject, Reason} ->
                    #{success => false, error => guardian_rejected, reason => Reason};
                {warn, Reason} ->
                    openpixie_log:warn("Guardian warning: ~p", [Reason]),
                    Result = dispatch(ToolName, ValidatedArgs),
                    openpixie_guardian:post_check(ToolName, ValidatedArgs, Result),
                    Result
            end;
        false ->
            dispatch(ToolName, ValidatedArgs)
    end.

dispatch(<<"read_file">>, Args) -> openpixie_tools_file:read_file(Args);
dispatch(<<"write_file">>, Args) -> openpixie_tools_file:write_file(Args);
dispatch(<<"edit_file">>, Args) -> openpixie_tools_file:edit_file(Args);
dispatch(<<"create_directory">>, Args) -> openpixie_tools_file:create_directory(Args);
dispatch(<<"list_files">>, Args) -> openpixie_tools_file:list_files(Args);
dispatch(<<"file_exists">>, Args) -> openpixie_tools_file:file_exists(Args);
dispatch(<<"verify_file">>, Args) -> openpixie_tools_file:verify_file(Args);

dispatch(<<"git_status">>, Args) -> openpixie_tools_git:git_status(Args);
dispatch(<<"git_diff">>, Args) -> openpixie_tools_git:git_diff(Args);
dispatch(<<"git_log">>, Args) -> openpixie_tools_git:git_log(Args);
dispatch(<<"git_add">>, Args) -> openpixie_tools_git:git_add(Args);
dispatch(<<"git_commit">>, Args) -> openpixie_tools_git:git_commit(Args);
dispatch(<<"git_branch">>, Args) -> openpixie_tools_git:git_branch(Args);
dispatch(<<"compile_and_reload">>, Args) -> openpixie_tools_self:compile_and_reload(Args);
dispatch(<<"git_stash">>, Args) -> openpixie_tools_git:git_stash(Args);
dispatch(<<"git_pull">>, Args) -> openpixie_tools_git:git_pull(Args);
dispatch(<<"git_push">>, Args) -> openpixie_tools_git:git_push(Args);
dispatch(<<"git_remote">>, Args) -> openpixie_tools_git:git_remote(Args);

dispatch(<<"run_command">>, Args) -> openpixie_tools_command:run_command(Args);

dispatch(<<"grep_files">>, Args) -> openpixie_tools_search:grep_files(Args);
dispatch(<<"find_files">>, Args) -> openpixie_tools_search:find_files(Args);

dispatch(<<"search_memories">>, Args) -> openpixie_tools_memory:search_memories(Args);
dispatch(<<"recent_memories">>, Args) -> openpixie_tools_memory:recent_memories(Args);

dispatch(<<"list_skills">>, Args) -> openpixie_tools_skills:list_skills(Args);
dispatch(<<"load_skill">>, Args) -> openpixie_tools_skills:load_skill(Args);

dispatch(<<"reload_module">>, Args) -> openpixie_tools_self:reload_module(Args);
dispatch(<<"get_self_modules">>, Args) -> openpixie_tools_self:get_self_modules(Args);
dispatch(<<"analyze_self">>, Args) -> openpixie_tools_self:analyze_self(Args);
dispatch(<<"list_models">>, Args) -> openpixie_tools_self:list_models(Args);
dispatch(<<"show_model">>, Args) -> openpixie_tools_self:show_model(Args);
dispatch(<<"propose_soul_edit">>, Args) -> openpixie_tools_self:propose_soul_edit(Args);
dispatch(<<"get_soul_proposal">>, Args) -> openpixie_tools_self:get_soul_proposal(Args);
dispatch(<<"apply_soul_proposal">>, Args) -> openpixie_tools_self:apply_soul_proposal(Args);
dispatch(<<"reject_soul_proposal">>, Args) -> openpixie_tools_self:reject_soul_proposal(Args);

dispatch(<<"get_performance_trend">>, Args) -> openpixie_tools_meta:get_performance_trend(Args);
dispatch(<<"get_improvements">>, Args) -> openpixie_tools_meta:get_improvements(Args);
dispatch(<<"save_snapshot">>, Args) -> openpixie_tools_meta:save_snapshot(Args);
dispatch(<<"list_snapshots">>, Args) -> openpixie_tools_meta:list_snapshots(Args);
dispatch(<<"load_snapshot">>, Args) -> openpixie_tools_meta:load_snapshot(Args);

dispatch(<<"ask_user">>, Args) -> openpixie_tools_ask:ask_user(Args);

dispatch(<<"push_message">>, Args) -> openpixie_tools_push:push_message(Args);

dispatch(<<"sync_export">>, Args) -> openpixie_tools_sync:sync_export(Args);
dispatch(<<"sync_import">>, Args) -> openpixie_tools_sync:sync_import(Args);

dispatch(<<"register_tool">>, Args) -> openpixie_tools_self:register_tool(Args);
dispatch(<<"unregister_tool">>, Args) -> openpixie_tools_self:unregister_tool(Args);

dispatch(Other, Args) ->
    case openpixie_tool_registry:lookup(Other) of
        {ok, #{module := Mod, function := Fun}} ->
            catch apply(Mod, Fun, [Args]);
        not_found ->
            #{success => false, error => unknown_tool, tool => Other}
    end.