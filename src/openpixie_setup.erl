-module(openpixie_setup).
-export([is_configured/0, start_wizard/0, run_auto_setup/0, run_setup/1]).

is_configured() ->
    ConfigPath = openpixie_config:config_path(),
    filelib:is_file(ConfigPath).

start_wizard() ->
    io:format("~n========================================~n"),
    io:format("  Welcome to OpenPixie Setup Wizard~n"),
    io:format("========================================~n~n"),
    setup_step(ollama_host),
    setup_step(ollama_model),
    setup_step(workspace),
    setup_step(api_key),
    setup_step(soul),
    finish_setup().

run_auto_setup() ->
    Host = openpixie_config:ollama_host(),
    Model = openpixie_config:ollama_model(),
    Ws = openpixie_config:workspace(),
    PixieDir = openpixie_config:pixie_dir(),
    ok = filelib:ensure_dir(filename:join(PixieDir, "dummy")),
    ok = filelib:ensure_dir(filename:join(Ws, "dummy")),
    {Key, Hash} = openpixie_auth:generate_key(),
    catch init_git_repo(Ws),
    catch openpixie_soul:init_template(#{
        name => <<"Pixie">>,
        personality => <<"helpful and thoughtful">>
    }),
    Config = #{
        ollama_host => list_to_binary(Host),
        ollama_model => Model,
        workspace => list_to_binary(Ws),
        http_port => openpixie_config:http_port(),
        permission_mode => openpixie_config:permission_mode(),
        api_key_hash => Hash
    },
    ok = openpixie_config:save_config(Config),
    application:set_env(openpixie, api_key_hash, Hash),
    KeyFile = filename:join(PixieDir, "API_KEY"),
    ok = file:write_file(KeyFile, Key),
    io:format("~n========================================~n"),
    io:format("  OpenPixie Auto-Setup~n"),
    io:format("========================================~n"),
    io:format("  Ollama host: ~s~n", [Host]),
    io:format("  Ollama model: ~s~n", [binary_to_list(Model)]),
    io:format("  Workspace: ~s~n", [Ws]),
    io:format("  Config dir: ~s~n", [PixieDir]),
    io:format("  API key: ~s~n", [binary_to_list(Key)]),
    io:format("  API key saved to: ~s~n", [KeyFile]),
    io:format("  Save this key! You need it for API/dashboard access.~n"),
    io:format("========================================~n~n"),
    {ok, Key}.

setup_step(ollama_host) ->
    Default = openpixie_config:ollama_host(),
    io:format("Ollama host URL [~s]: ", [Default]),
    Input = read_line(),
    Host = case Input of
        [] -> Default;
        Line -> Line
    end,
    openpixie_config:set_ollama_host(Host),
    ok;

setup_step(ollama_model) ->
    Default = openpixie_config:ollama_model(),
    io:format("Ollama model [~s]: ", [binary_to_list(Default)]),
    Input = read_line(),
    Model = case Input of
        [] -> Default;
        Line -> list_to_binary(Line)
    end,
    openpixie_config:set_ollama_model(Model),
    ok;

setup_step(workspace) ->
    io:format("Workspace directory [~s]: ", [openpixie_config:workspace()]),
    Input = read_line(),
    Ws = case Input of
        [] -> openpixie_config:workspace();
        Line -> Line
    end,
    openpixie_config:set_workspace(Ws),
    catch init_git_repo(Ws),
    ok;

setup_step(api_key) ->
    {Key, Hash} = openpixie_auth:generate_key(),
    application:set_env(openpixie, api_key_hash, Hash),
    KeyFile = filename:join(openpixie_config:pixie_dir(), "API_KEY"),
    catch file:write_file(KeyFile, Key),
    io:format("~nYour API key: ~s~n", [binary_to_list(Key)]),
    io:format("API key saved to: ~s~n", [KeyFile]),
    io:format("Save this key! You will need it to access the API and dashboard.~n~n"),
    ok;

setup_step(soul) ->
    io:format("Assistant name [Pixie]: "),
    NameInput = read_line(),
    Name = case NameInput of
        [] -> <<"Pixie">>;
        NameLine -> list_to_binary(NameLine)
    end,
    io:format("Personality [helpful and thoughtful]: "),
    PersInput = read_line(),
    Personality = case PersInput of
        [] -> <<"helpful and thoughtful">>;
        PersLine -> list_to_binary(PersLine)
    end,
    catch openpixie_soul:init_template(#{name => Name, personality => Personality}),
    ok.

read_line() ->
    case io:get_line("") of
        eof -> [];
        {error, _} -> [];
        Line -> string:trim(Line, trailing, "\n")
    end.

init_git_repo(Ws) ->
    case filelib:is_dir(filename:join(Ws, ".git")) of
        true -> ok;
        false ->
            os:cmd("git init " ++ Ws),
            ok
    end.

finish_setup() ->
    Hash = application:get_env(openpixie, api_key_hash, undefined),
    PixieDir = openpixie_config:pixie_dir(),
    ok = filelib:ensure_dir(filename:join(PixieDir, "dummy")),
    Config = #{
        ollama_host => list_to_binary(openpixie_config:ollama_host()),
        ollama_model => openpixie_config:ollama_model(),
        workspace => list_to_binary(openpixie_config:workspace()),
        http_port => openpixie_config:http_port(),
        permission_mode => openpixie_config:permission_mode()
    },
    ConfigWithKey = case Hash of
        undefined -> Config;
        H when is_binary(H) -> Config#{api_key_hash => H}
    end,
    ok = openpixie_config:save_config(ConfigWithKey),
    io:format("Setup complete!~n~n"),
    ok.

run_setup(ConfigMap) when is_map(ConfigMap) ->
    Host = binary_to_list(maps:get(<<"ollama_host">>, ConfigMap, <<"http://localhost:11434">>)),
    Model = maps:get(<<"ollama_model">>, ConfigMap, <<"glm-5:cloud">>),
    Ws = binary_to_list(maps:get(<<"workspace">>, ConfigMap, <<".">>)),
    {Key, Hash} = openpixie_auth:generate_key(),
    openpixie_config:set_ollama_host(Host),
    openpixie_config:set_ollama_model(Model),
    openpixie_config:set_workspace(Ws),
    application:set_env(openpixie, api_key_hash, Hash),
    catch init_git_repo(Ws),
    catch openpixie_soul:init_template(maps:get(<<"soul">>, ConfigMap, #{})),
    Config = #{
        ollama_host => list_to_binary(Host),
        ollama_model => Model,
        workspace => list_to_binary(Ws),
        http_port => openpixie_config:http_port(),
        permission_mode => openpixie_config:permission_mode(),
        api_key_hash => Hash
    },
    ok = openpixie_config:save_config(Config),
    {ok, #{api_key => Key}}.