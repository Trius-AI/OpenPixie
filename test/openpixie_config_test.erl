-module(openpixie_config_test).

-include_lib("eunit/include/eunit.hrl").

ollama_host_default_test() ->
    application:unload(openpixie),
    ?assertEqual("http://localhost:11434", openpixie_config:ollama_host()).

ollama_model_default_test() ->
    application:unload(openpixie),
    ?assertEqual(<<"glm-5:cloud">>, openpixie_config:ollama_model()).

http_port_default_test() ->
    application:unload(openpixie),
    ?assertEqual(8080, openpixie_config:http_port()).

workspace_default_test() ->
    application:unload(openpixie),
    ?assertEqual(".", openpixie_config:workspace()).