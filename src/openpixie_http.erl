-module(openpixie_http).
-behaviour(supervisor).
-export([start_link/0, init/1, resolve_dashboard_dir/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Port = openpixie_config:http_port(),
    DashboardDir = resolve_dashboard_dir(),
    ApiRoutes = [
        {"/health", openpixie_http_health, []},
        {"/api/v1/login", openpixie_http_login, []},
        {"/api/v1/chat", openpixie_http_chat, []},
        {"/api/v1/topics", openpixie_http_topics, []},
        {"/api/v1/topics/:id", openpixie_http_topics, []},
        {"/api/v1/models", openpixie_http_models, []},
        {"/api/v1/skills", openpixie_http_skills, []},
        {"/api/v1/sync", openpixie_http_sync, []},
        {"/api/v1/config", openpixie_http_config, []},
        {"/api/v1/files", openpixie_http_files, []},
        {"/api/v1/pixie-data/:name", openpixie_http_pixie_data, []},
        {"/api/v1/tools", openpixie_http_tools, []},
        {"/api/v1/metrics/:key/:action", openpixie_http_metrics, []},
        {"/api/v1/metrics/:key", openpixie_http_metrics, []},
        {"/api/v1/metrics", openpixie_http_metrics, []},
        {"/ws", openpixie_ws, []},
        {"/recover", openpixie_http_recover, []}
    ],
    AllRoutes = case DashboardDir of
        undefined ->
            io:format("[openpixie] Dashboard not found, serving API only~n"),
            ApiRoutes;
        DD when is_list(DD) ->
            io:format("[openpixie] Dashboard served from ~s~n", [DD]),
            ApiRoutes ++ [
                {"/", cowboy_static, {file, filename:join(DD, "index.html")}},
                {"/login", openpixie_http_spa, []},
                {"/dashboard", openpixie_http_spa, []},
                {"/chat", openpixie_http_spa, []},
                {"/chat/:topic_id", openpixie_http_spa, []},
                {"/settings", openpixie_http_spa, []},
                {"/guardian", openpixie_http_spa, []},
                {"/files", openpixie_http_spa, []},
                {"/skill2tool", openpixie_http_spa, []},
                {"/metrics", openpixie_http_spa, []},
                {"/[...]", cowboy_static, {dir, DD}}
            ]
    end,
    Dispatch = cowboy_router:compile([{'_', AllRoutes}]),
    case cowboy:start_clear(openpixie_http_listener, [{port, Port}, {ip, {0,0,0,0}}], #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} ->
            io:format("[openpixie] HTTP listener started on port ~p~n", [Port]);
        {error, {listen_error, _, eaddrinuse}} ->
            io:format("[openpixie] WARNING: Port ~p already in use~n", [Port]);
        {error, Reason} ->
            io:format("[openpixie] WARNING: Failed to start HTTP listener: ~p~n", [Reason])
    end,
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 60},
    {ok, {SupFlags, []}}.

resolve_dashboard_dir() ->
    Ws = os:getenv("OPENPIXIE_WORKSPACE", ""),
    WsDash = filename:join(Ws, "priv/dashboard"),
    case Ws =/= "" andalso filelib:is_dir(WsDash) of
        true -> WsDash;
        false ->
            case code:priv_dir(openpixie) of
                {error, _} ->
                    case filelib:is_dir("priv/dashboard") of
                        true -> "priv/dashboard";
                        false -> undefined
                    end;
                PrivDir ->
                    Dir = filename:join(PrivDir, "dashboard"),
                    case filelib:is_dir(Dir) of
                        true -> Dir;
                        false -> undefined
                    end
            end
    end.