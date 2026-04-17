-module(openpixie_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ensure_dirs(),
    add_workspace_code_path(),
    openpixie_config:init_config(),
    case openpixie_setup:is_configured() of
        true ->
            openpixie_sup:start_link();
        false ->
            case has_env_config() of
                true ->
                    openpixie_setup:run_auto_setup(),
                    openpixie_sup:start_link();
                false ->
                    io:format("[openpixie] Not configured.~n"),
                    io:format("[openpixie] Set env vars and restart:~n"),
                    io:format("[openpixie]   OLLAMA_HOST=http://host.docker.internal:11434~n"),
                    io:format("[openpixie]   OLLAMA_MODEL=glm-5:cloud~n"),
                    io:format("[openpixie]   OPENPIXIE_WORKSPACE=/data/workspace~n"),
                    {error, not_configured}
            end
    end.

stop(_State) ->
    ok.

has_env_config() ->
    os:getenv("OLLAMA_HOST") =/= false orelse
    os:getenv("OLLAMA_MODEL") =/= false orelse
    os:getenv("OPENPIXIE_WORKSPACE") =/= false.

ensure_dirs() ->
    PixieDir = case os:getenv("OPENPIXIE_DIR") of
        false -> ".pixie";
        Dir -> Dir
    end,
    application:set_env(openpixie, pixie_dir, PixieDir),
    ok = filelib:ensure_dir(filename:join(PixieDir, "dummy")),
    Ws = case os:getenv("OPENPIXIE_WORKSPACE") of
        false -> ".";
        W -> W
    end,
    ok = filelib:ensure_dir(filename:join(Ws, "dummy")),
    ok = filelib:ensure_dir(filename:join(PixieDir, "memories/dummy")),
    ok = filelib:ensure_dir(filename:join(PixieDir, "topics/dummy")),
    ok = filelib:ensure_dir(filename:join(PixieDir, "channels/dummy")),
    ok = filelib:ensure_dir(filename:join(PixieDir, "skills/dummy")),
    ok = filelib:ensure_dir(filename:join(PixieDir, "archive/dummy")),
    ok.

add_workspace_code_path() ->
    Ws = case os:getenv("OPENPIXIE_WORKSPACE") of
        false -> ".";
        W -> W
    end,
    EbinDir = filename:join(Ws, "ebin"),
    case filelib:is_dir(EbinDir) of
        true ->
            code:add_patha(EbinDir);
        false ->
            ok = filelib:ensure_dir(filename:join(EbinDir, "dummy")),
            code:add_patha(EbinDir)
    end.