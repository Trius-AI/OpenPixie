-module(openpixie_config).
-export([
    init_config/0,
    pixie_dir/0,
    config_path/0,
    ollama_host/0,
    ollama_model/0,
    set_ollama_host/1,
    set_ollama_model/1,
    http_port/0,
    workspace/0,
    set_workspace/1,
    idle_timeout_minutes/0,
    permission_mode/0,
    set_permission_mode/1,
    max_llm_concurrency/0,
    circuit_breaker_failures/0,
    circuit_breaker_cooldown_ms/0,
    llm_timeout_ms/0,
    max_context_tokens/0,
    soul_path/0,
    memories_dir/0,
    topics_dir/0,
    channels_dir/0,
    skills_dir/0,
    archive_dir/0,
    improvements_path/0,
    reflection_hour/0,
    heartbeat_interval_ms/0,
    idle_evict_minutes/0,
    load_config/0,
    save_config/1
]).

init_config() ->
    case os:getenv("OPENPIXIE_DIR") of
        false -> ok;
        Dir -> application:set_env(openpixie, pixie_dir, Dir)
    end,
    case filelib:is_file(config_path()) of
        true -> load_config();
        false -> ok
    end,
    apply_env_overrides(),
    ok.

apply_env_overrides() ->
    apply_env("OLLAMA_HOST", ollama_host, fun id/1),
    apply_env("OLLAMA_MODEL", ollama_model, fun list_to_binary/1),
    apply_env("OPENPIXIE_WORKSPACE", workspace, fun id/1),
    apply_env("OPENPIXIE_PORT", http_port, fun list_to_integer/1),
    ok.

apply_env(EnvKey, AppConfigKey, Convert) ->
    case os:getenv(EnvKey) of
        false -> ok;
        Val -> application:set_env(openpixie, AppConfigKey, Convert(Val))
    end.

pixie_dir() ->
    application:get_env(openpixie, pixie_dir, ".pixie").

config_path() ->
    filename:join(pixie_dir(), "config.json").

ollama_host() ->
    application:get_env(openpixie, ollama_host, "http://localhost:11434").

ollama_model() ->
    application:get_env(openpixie, ollama_model, <<"glm-5:cloud">>).

set_ollama_host(Host) when is_list(Host) ->
    application:set_env(openpixie, ollama_host, Host).

set_ollama_model(Model) when is_binary(Model) ->
    application:set_env(openpixie, ollama_model, Model).

http_port() ->
    application:get_env(openpixie, http_port, 8080).

workspace() ->
    application:get_env(openpixie, workspace, ".").

set_workspace(Ws) when is_list(Ws) ->
    application:set_env(openpixie, workspace, Ws).

idle_timeout_minutes() ->
    application:get_env(openpixie, idle_timeout_minutes, 30).

permission_mode() ->
    case application:get_env(openpixie, permission_mode, ask) of
        Mode when is_binary(Mode) -> binary_to_existing_atom(Mode, utf8);
        Mode when is_atom(Mode) -> Mode
    end.

set_permission_mode(Mode) ->
    application:set_env(openpixie, permission_mode, Mode).

max_llm_concurrency() ->
    application:get_env(openpixie, max_llm_concurrency, 1).

circuit_breaker_failures() ->
    application:get_env(openpixie, circuit_breaker_failures, 5).

circuit_breaker_cooldown_ms() ->
    application:get_env(openpixie, circuit_breaker_cooldown_ms, 30000).

llm_timeout_ms() ->
    application:get_env(openpixie, llm_timeout_ms, 600000).

max_context_tokens() ->
    application:get_env(openpixie, max_context_tokens, 32768).

soul_path() ->
    filename:join(pixie_dir(), "SOUL.md").

memories_dir() ->
    filename:join(pixie_dir(), "memories").

topics_dir() ->
    filename:join(pixie_dir(), "topics").

channels_dir() ->
    filename:join(pixie_dir(), "channels").

skills_dir() ->
    filename:join(pixie_dir(), "skills").

archive_dir() ->
    filename:join(pixie_dir(), "archive").

improvements_path() ->
    filename:join(pixie_dir(), "IMPROVEMENTS.md").

reflection_hour() ->
    application:get_env(openpixie, reflection_hour, 22).

heartbeat_interval_ms() ->
    application:get_env(openpixie, heartbeat_interval_ms, 30000).

idle_evict_minutes() ->
    application:get_env(openpixie, idle_evict_minutes, 1440).

load_config() ->
    case file:read_file(config_path()) of
        {ok, Content} ->
            case jsx:is_json(Content) of
                true ->
                    Decoded = jsx:decode(Content, [return_maps]),
                    maps:fold(fun(K, V, _Acc) ->
                        try
                            Atom = binary_to_atom(K, utf8),
                            application:set_env(openpixie, Atom, V)
                        catch _:_ -> ok
                        end
                    end, ok, Decoded);
                false -> ok
            end;
        {error, _} -> ok
    end.

save_config(ConfigMap) when is_map(ConfigMap) ->
    Dir = pixie_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Encoded = jsx:encode(maps:map(fun(_K, V) when is_atom(V) -> atom_to_binary(V, utf8);
                                    (_K, V) -> V
                                 end, ConfigMap)),
    TmpPath = config_path() ++ ".tmp",
    ok = file:write_file(TmpPath, Encoded),
    ok = file:rename(TmpPath, config_path()),
    ok.

id(X) -> X.