-module(openpixie_http_tools).
-export([init/2]).

init(Req, State) ->
    case openpixie_auth:authenticate_request(Req) of
        {ok, _} ->
            Method = cowboy_req:method(Req),
            case Method of
                <<"GET">> -> handle_list(Req, State);
                _ -> reply_json(Req, State, 405, #{error => method_not_allowed})
            end;
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

handle_list(Req, State) ->
    Schemas = openpixie_tools:tool_schema(),
    Mode = openpixie_permissions:get_mode(),
    Tools = lists:map(fun(Schema) ->
        FuncMap = maps:get(function, Schema, #{}),
        Name = maps:get(name, FuncMap, unknown),
        NameBin = case is_atom(Name) of true -> atom_to_binary(Name, utf8); false -> Name end,
        Desc = maps:get(description, FuncMap, <<"">>),
        Params = maps:get(parameters, FuncMap, #{}),
        Props = maps:get(properties, Params, #{}),
        Required = maps:get(required, Params, []),
        Perm = tool_permission(NameBin, Mode),
        #{
            name => NameBin,
            description => Desc,
            parameters => format_props(Props),
            required => [case is_atom(R) of true -> atom_to_binary(R, utf8); false -> R end || R <- Required],
            permission => Perm,
            category => tool_category(NameBin)
        }
    end, Schemas),
    reply_json(Req, State, 200, #{tools => Tools, mode => atom_to_binary(Mode, utf8)}).

format_props(Props) when is_map(Props) ->
    maps:map(fun(_K, V) when is_map(V) ->
        Desc = maps:get(description, V, <<"">>),
        Type = maps:get(type, V, string),
        TypeBin = case is_atom(Type) of true -> atom_to_binary(Type, utf8); false -> Type end,
        #{description => Desc, type => TypeBin};
    (_K, V) -> V
    end, Props);
format_props(_) -> #{}.

tool_permission(Name, Mode) ->
    IsSelfMod = is_self_modification(Name),
    IsReadonly = is_readonly_tool(Name),
    case Mode of
        trust -> <<"allow">>;
        plan ->
            case IsReadonly of true -> <<"allow">>; false -> <<"deny">> end;
        sandbox ->
            case IsSelfMod of
                true -> <<"deny">>;
                false ->
                    case IsReadonly of true -> <<"allow">>; false -> <<"ask">> end
            end;
        auto_noselfmod ->
            case IsSelfMod of
                true -> <<"ask">>;
                false -> <<"allow">>
            end;
        ask ->
            case IsSelfMod of
                true -> <<"ask">>;
                false ->
                    case IsReadonly of true -> <<"allow">>; false -> <<"ask">> end
            end
    end.

is_self_modification(Name) ->
    lists:member(Name, [
        <<"reload_module">>, <<"deploy_module">>, <<"compile_and_reload">>,
        <<"edit_file">>, <<"write_file">>,
        <<"propose_soul_edit">>, <<"apply_soul_proposal">>, <<"reject_soul_proposal">>,
        <<"register_tool">>, <<"unregister_tool">>,
        <<"sync_import">>
    ]).

is_readonly_tool(Name) ->
    lists:member(Name, [
        <<"read_file">>, <<"list_files">>, <<"file_exists">>,
        <<"grep_files">>, <<"find_files">>,
        <<"git_status">>, <<"git_log">>, <<"git_diff">>,
        <<"list_models">>, <<"show_model">>,
        <<"list_skills">>, <<"load_skill">>,
        <<"search_memories">>, <<"recent_memories">>,
        <<"get_self_modules">>, <<"analyze_self">>,
        <<"get_soul_proposal">>,
        <<"ask_user">>,
        <<"list_snapshots">>,
        <<"health">>,
        <<"get_performance_trend">>, <<"get_improvements">>,
        <<"sync_export">>
    ]).

tool_category(Name) ->
    CatMap = #{
        <<"read_file">> => <<"file">>, <<"write_file">> => <<"file">>,
        <<"edit_file">> => <<"file">>, <<"create_directory">> => <<"file">>,
        <<"list_files">> => <<"file">>, <<"file_exists">> => <<"file">>,
        <<"verify_file">> => <<"file">>,
        <<"git_status">> => <<"git">>, <<"git_diff">> => <<"git">>,
        <<"git_log">> => <<"git">>, <<"git_add">> => <<"git">>,
        <<"git_commit">> => <<"git">>, <<"git_branch">> => <<"git">>,
        <<"git_stash">> => <<"git">>, <<"git_pull">> => <<"git">>,
        <<"git_push">> => <<"git">>, <<"git_remote">> => <<"git">>,
        <<"run_command">> => <<"command">>,
        <<"grep_files">> => <<"search">>, <<"find_files">> => <<"search">>,
        <<"search_memories">> => <<"memory">>, <<"recent_memories">> => <<"memory">>,
        <<"list_skills">> => <<"skills">>, <<"load_skill">> => <<"skills">>,
        <<"reload_module">> => <<"self-modification">>, <<"compile_and_reload">> => <<"self-modification">>,
        <<"get_self_modules">> => <<"self-modification">>, <<"analyze_self">> => <<"self-modification">>,
        <<"list_models">> => <<"self-modification">>, <<"show_model">> => <<"self-modification">>,
        <<"propose_soul_edit">> => <<"self-modification">>, <<"apply_soul_proposal">> => <<"self-modification">>,
        <<"reject_soul_proposal">> => <<"self-modification">>,
        <<"register_tool">> => <<"self-modification">>, <<"unregister_tool">> => <<"self-modification">>,
        <<"ask_user">> => <<"interaction">>,
        <<"sync_export">> => <<"sync">>, <<"sync_import">> => <<"sync">>,
        <<"get_performance_trend">> => <<"metacognitive">>,
        <<"get_improvements">> => <<"metacognitive">>,
        <<"save_snapshot">> => <<"metacognitive">>,
        <<"list_snapshots">> => <<"metacognitive">>,
        <<"load_snapshot">> => <<"metacognitive">>,
        <<"health">> => <<"system">>
    },
    maps:get(Name, CatMap, <<"general">>).

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.