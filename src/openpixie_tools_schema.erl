-module(openpixie_tools_schema).
-export([validate/2]).

validate(ToolName, Args) ->
    Schema = get_schema(ToolName),
    case Schema of
        undefined ->
            case openpixie_tool_registry:lookup(ToolName) of
                {ok, _} -> {ok, coerce_all_binary(Args)};
                not_found -> {ok, Args}
            end;
        RequiredKeys ->
            case check_required(Args, RequiredKeys) of
                ok -> {ok, coerce_types(ToolName, Args)};
                {error, Missing} -> {error, {missing_required, Missing}}
            end
    end.

check_required(Args, Required) ->
    Missing = lists:filter(fun(Key) ->
        maps:is_key(Key, Args) =:= false andalso
        maps:is_key(atom_to_binary(Key, utf8), Args) =:= false
    end, Required),
    case Missing of
        [] -> ok;
        _ -> {error, Missing}
    end.

coerce_types(<<"read_file">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)))};
coerce_types(<<"write_file">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>))),
          content => to_binary(maps:get(<<"content">>, Args, maps:get(content, Args, <<"">>)))};
coerce_types(<<"edit_file">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>))),
          old_string => to_binary(maps:get(<<"old_string">>, Args, maps:get(old_string, Args, <<"">>))),
          new_string => to_binary(maps:get(<<"new_string">>, Args, maps:get(new_string, Args, <<"">>)))};
coerce_types(<<"create_directory">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)))};
coerce_types(<<"list_files">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)))};
coerce_types(<<"file_exists">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)))};
coerce_types(<<"verify_file">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>))),
          type => to_binary(maps:get(<<"type">>, Args, maps:get(type, Args, <<"auto">>)))};
coerce_types(<<"run_command">>, Args) ->
    Args#{command => to_binary(maps:get(<<"command">>, Args, maps:get(command, Args, <<"">>)))};
coerce_types(<<"grep_files">>, Args) ->
    Args#{pattern => to_binary(maps:get(<<"pattern">>, Args, maps:get(pattern, Args, <<"">>))),
          path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)))};
coerce_types(<<"find_files">>, Args) ->
    Args#{pattern => to_binary(maps:get(<<"pattern">>, Args, maps:get(pattern, Args, <<"">>))),
          path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)))};
coerce_types(<<"git_commit">>, Args) ->
    Args#{message => to_binary(maps:get(<<"message">>, Args, maps:get(message, Args, <<"">>)))};
coerce_types(<<"search_memories">>, Args) ->
    Args#{query => to_binary(maps:get(<<"query">>, Args, maps:get(query, Args, <<"">>)))};
coerce_types(<<"load_skill">>, Args) ->
    Args#{name => to_binary(maps:get(<<"name">>, Args, maps:get(name, Args, <<"">>)))};
coerce_types(<<"get_performance_trend">>, Args) ->
    Args#{key => to_binary(maps:get(<<"key">>, Args, maps:get(key, Args, <<"">>))),
          window => to_binary(maps:get(<<"window">>, Args, maps:get(window, Args, <<"5">>)))};
coerce_types(<<"save_snapshot">>, Args) ->
    Args#{label => to_binary(maps:get(<<"label">>, Args, maps:get(label, Args, <<"">>)))};
coerce_types(<<"load_snapshot">>, Args) ->
    Args#{id => to_binary(maps:get(<<"id">>, Args, maps:get(id, Args, <<"">>)))};
coerce_types(<<"propose_soul_edit">>, Args) ->
    Args#{content => to_binary(maps:get(<<"content">>, Args, maps:get(content, Args, <<"">>)))};
coerce_types(<<"apply_soul_proposal">>, Args) ->
    Args#{approval => to_binary(maps:get(<<"approval">>, Args, maps:get(approval, Args, <<"">>)))};
coerce_types(<<"reject_soul_proposal">>, Args) ->
    Args#{reason => to_binary(maps:get(<<"reason">>, Args, maps:get(reason, Args, <<"">>)))};
coerce_types(<<"compile_and_reload">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<"">>)))};
coerce_types(<<"reload_module">>, Args) ->
    Args#{module => to_binary(maps:get(<<"module">>, Args, maps:get(module, Args, <<"">>)))};
coerce_types(<<"show_model">>, Args) ->
    Args#{name => to_binary(maps:get(<<"name">>, Args, maps:get(name, Args, <<"">>)))};
coerce_types(<<"git_diff">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<".">>)))};
coerce_types(<<"git_log">>, Args) ->
    Args#{n => to_binary(maps:get(<<"n">>, Args, maps:get(n, Args, <<"10">>)))};
coerce_types(<<"git_add">>, Args) ->
    Args#{path => to_binary(maps:get(<<"path">>, Args, maps:get(path, Args, <<".">>)))};
coerce_types(<<"git_branch">>, Args) ->
    Args#{name => to_binary(maps:get(<<"name">>, Args, maps:get(name, Args, <<"">>)))};
coerce_types(<<"git_pull">>, Args) ->
    Args#{remote => to_binary(maps:get(<<"remote">>, Args, maps:get(remote, Args, <<"origin">>)))};
coerce_types(<<"git_push">>, Args) ->
    Args#{remote => to_binary(maps:get(<<"remote">>, Args, maps:get(remote, Args, <<"origin">>)))};
coerce_types(<<"git_remote">>, Args) ->
    Args#{action => to_binary(maps:get(<<"action">>, Args, maps:get(action, Args, <<"list">>)))};
coerce_types(<<"list_snapshots">>, Args) ->
    Args#{label => to_binary(maps:get(<<"label">>, Args, maps:get(label, Args, <<"">>)))};
coerce_types(<<"recent_memories">>, Args) ->
    Args#{n => to_binary(maps:get(<<"n">>, Args, maps:get(n, Args, <<"5">>)))};
coerce_types(_, Args) ->
    Args.

get_schema(<<"read_file">>) -> [path];
get_schema(<<"write_file">>) -> [path, content];
get_schema(<<"edit_file">>) -> [path, old_string, new_string];
get_schema(<<"create_directory">>) -> [path];
get_schema(<<"list_files">>) -> [path];
get_schema(<<"file_exists">>) -> [path];
get_schema(<<"verify_file">>) -> [path];
get_schema(<<"run_command">>) -> [command];
get_schema(<<"grep_files">>) -> [pattern];
get_schema(<<"find_files">>) -> [pattern];
get_schema(<<"git_commit">>) -> [message];
get_schema(<<"search_memories">>) -> [query];
get_schema(<<"load_skill">>) -> [name];
get_schema(<<"get_performance_trend">>) -> [key];
get_schema(<<"save_snapshot">>) -> [label];
get_schema(<<"list_snapshots">>) -> [];
get_schema(<<"load_snapshot">>) -> [id];
get_schema(<<"propose_soul_edit">>) -> [content];
get_schema(<<"get_soul_proposal">>) -> [];
get_schema(<<"apply_soul_proposal">>) -> [approval];
get_schema(<<"reject_soul_proposal">>) -> [reason];
get_schema(<<"compile_and_reload">>) -> [path];
get_schema(<<"reload_module">>) -> [module];
get_schema(<<"show_model">>) -> [name];
get_schema(<<"get_self_modules">>) -> [];
get_schema(<<"analyze_self">>) -> [];
get_schema(<<"get_improvements">>) -> [];
get_schema(_) -> undefined.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I).

coerce_all_binary(Args) when is_map(Args) ->
    maps:map(fun(_, V) -> to_binary(V) end, Args);
coerce_all_binary(Args) -> Args.