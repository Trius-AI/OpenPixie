-module(openpixie_http_recover).
-export([init/2]).

init(Req, State) ->
    case authenticate(Req) of
        {ok, _} ->
            Method = cowboy_req:method(Req),
            case Method of
                <<"GET">> -> handle_get(Req, State);
                <<"POST">> -> handle_post(Req, State);
                _ -> reply_json(Req, State, 405, #{error => method_not_allowed})
            end;
        {error, _} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req2, State}
    end.

authenticate(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Key/binary>> -> openpixie_auth:authenticate(Key);
        _ ->
            Qs = cowboy_req:parse_qs(Req),
            case proplists:get_value(<<"key">>, Qs) of
                undefined -> {error, no_key};
                Key -> openpixie_auth:authenticate(Key)
            end
    end.

handle_post(Req, State) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    Msg = jsx:decode(Body, [return_maps]),
    Action = maps:get(<<"action">>, Msg, undefined),
    Result = case Action of
        <<"reset_source">> -> reset_source();
        <<"reset_config">> -> reset_config();
        <<"clear_topics">> -> clear_topics();
        <<"reset_all">> -> reset_all();
        <<"backup_data">> -> backup_data();
        <<"download_backup">> -> download_backup(Req, State);
        <<"reload_module">> ->
            ModuleBin = maps:get(<<"module">>, Msg, undefined),
            reload_single_module(ModuleBin);
        _ -> #{success => false, error => unknown_action}
    end,
    reply_json(Req2, State, 200, Result).

download_backup(Req, State) ->
    PixieDir = openpixie_config:pixie_dir(),
    WsDir = openpixie_config:workspace(),
    {{Y,Mo,D},{H,Mi,S}} = calendar:now_to_datetime(erlang:timestamp()),
    Stamp = lists:flatten(io_lib:format("~4..0B~2..0B~2..0B_~2..0B~2..0B~2..0B", [Y,Mo,D,H,Mi,S])),
    ArchiveName = "openpixie_backup_" ++ Stamp ++ ".tar.gz",
    TmpArchive = "/tmp/" ++ ArchiveName,
    TopicsDir = openpixie_config:topics_dir(),
    ConfigFile = openpixie_config:config_path(),
    Incl = lists:filter(fun(P) -> filelib:is_file(P) orelse filelib:is_dir(P) end,
        [ConfigFile, TopicsDir, WsDir]),
    FilesArg = string:join(Incl, " "),
    os:cmd("tar czf " ++ TmpArchive ++ " -C / " ++ FilesArg ++ " 2>/dev/null"),
    case file:read_file(TmpArchive) of
        {ok, Bin} ->
            file:delete(TmpArchive),
            Req2 = cowboy_req:reply(200, #{
                <<"content-type">> => <<"application/gzip">>,
                <<"content-disposition">> => list_to_binary("attachment; filename=" ++ ArchiveName)
            }, Bin, Req),
            {ok, Req2, State};
        {error, Reason} ->
            file:delete(TmpArchive),
            reply_json(Req, State, 500, #{success => false, error => iolist_to_binary(io_lib:format("Archive failed: ~p", [Reason]))})
    end.

handle_get(Req, State) ->
    Status = get_status(),
    HTML = build_page(Status),
    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"text/html">>}, HTML, Req),
    {ok, Req2, State}.

reply_json(Req, State, Code, Data) ->
    Body = iolist_to_binary(jsx:encode(Data)),
    Req2 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State}.

get_status() ->
    #{
        modules => get_loaded_modules(),
        topic_count => get_topic_count(),
        config => get_config_summary(),
        workspace_src_ok => check_workspace_src()
    }.

get_loaded_modules() ->
    AppModules = [M || {M, _} <- code:all_loaded(), is_openpixie_module(M)],
    lists:map(fun(M) ->
        Path = code:which(M),
        #{module => atom_to_binary(M, utf8), path => iolist_to_binary(io_lib:format("~p", [Path]))}
    end, AppModules).

is_openpixie_module(M) ->
    Name = atom_to_binary(M, utf8),
    binary:part(Name, 0, min(10, byte_size(Name))) =:= <<"openpixie_">>.

get_topic_count() ->
    try length(openpixie_topic_store:list())
    catch _:_ -> -1
    end.

get_config_summary() ->
    try
        #{
            ollama_host => list_to_binary(openpixie_config:ollama_host()),
            ollama_model => openpixie_config:ollama_model(),
            permission_mode => atom_to_binary(openpixie_config:permission_mode(), utf8),
            llm_timeout_ms => openpixie_config:llm_timeout_ms(),
            max_context_tokens => openpixie_config:max_context_tokens()
        }
    catch _:_ -> #{error => unavailable}
    end.

check_workspace_src() ->
    Ws = openpixie_config:workspace(),
    SrcDir = filename:join(Ws, "src"),
    case file:list_dir(SrcDir) of
        {ok, Files} ->
            ErlFiles = [F || F <- Files, filename:extension(F) =:= ".erl"],
            length(ErlFiles) > 0;
        _ -> false
    end.

reset_source() ->
    Ws = openpixie_config:workspace(),
    SrcDir = filename:join(Ws, "src"),
    EbinDir = filename:join(Ws, "ebin"),
    ReleaseSrc = "/opt/openpixie/src",
    ReleaseDash = case code:priv_dir(openpixie) of
        {error, _} -> "/opt/openpixie/lib/openpixie-0.1.0/priv/dashboard";
        PrivDir -> filename:join(PrivDir, "dashboard")
    end,
    case file:list_dir(ReleaseSrc) of
        {ok, Files} ->
            ErlFiles = [F || F <- Files, filename:extension(F) =:= ".erl"],
            lists:foreach(fun(F) ->
                file:copy(filename:join(ReleaseSrc, F), filename:join(SrcDir, F))
            end, ErlFiles),
            DashSrc = filename:join(ReleaseDash, "index.html"),
            DashDst = filename:join(Ws, "priv/dashboard/index.html"),
            filelib:ensure_dir(DashDst),
            file:copy(DashSrc, DashDst),
            Beams = filelib:wildcard("*.beam", EbinDir),
            lists:foreach(fun(B) -> file:delete(filename:join(EbinDir, B)) end, Beams),
            ReloadResults = reload_all_modules(),
            git_commit(Ws, "reset: restored source from release baseline"),
            #{success => true, message => <<"Source files restored from release baseline. All modules recompiled and reloaded.">>, files_restored => length(ErlFiles), reload_results => ReloadResults};
        {error, Reason} ->
            #{success => false, error => iolist_to_binary(io_lib:format("Cannot read release source: ~p", [Reason]))}
    end.

reset_config() ->
    SavedKeyHash = case openpixie_auth:get_key_hash() of
        undefined -> undefined;
        {ok, H} -> {ok, H}
    end,
    ConfigPath = openpixie_config:config_path(),
    file:delete(ConfigPath),
    openpixie_config:init_config(),
    case SavedKeyHash of
        {ok, H2} ->
            application:set_env(openpixie, api_key_hash, H2),
            openpixie_auth:setup_key_from_hash(H2);
        undefined -> ok
    end,
    #{success => true, message => <<"Config reset to defaults. API key preserved.">>}.

clear_topics() ->
    TopicsDir = openpixie_config:topics_dir(),
    Topics = try openpixie_topic_store:list() catch _:_ -> [] end,
    lists:foreach(fun({Id, Pid, _Status, _ChId, _Title}) ->
        catch openpixie_topic:stop_topic(Pid),
        openpixie_topic_store:delete(Id),
        del_dir(filename:join(TopicsDir, binary_to_list(Id)))
    end, Topics),
    #{success => true, message => <<"All topics cleared and stopped.">>}.

reset_all() ->
    R1 = reset_source(),
    R2 = reset_config(),
    R3 = clear_topics(),
    #{success => true, message => <<"Full reset completed.">>, source => R1, config => R2, topics => R3}.

backup_data() ->
    PixieDir = openpixie_config:pixie_dir(),
    TopicsDir = openpixie_config:topics_dir(),
    WsDir = openpixie_config:workspace(),
    {{Y,Mo,D},{H,Mi,S}} = calendar:now_to_datetime(erlang:timestamp()),
    Stamp = io_lib:format("~4..0B~2..0B~2..0B_~2..0B~2..0B~2..0B", [Y,Mo,D,H,Mi,S]),
    BackupDir = filename:join(PixieDir, "backups/" ++ lists:flatten(Stamp)),
    ok = filelib:ensure_dir(filename:join(BackupDir, "dummy")),
    TopicsBackup = filename:join(BackupDir, "topics"),
    WsBackup = filename:join(BackupDir, "workspace"),
    ConfigBackup = filename:join(BackupDir, "config.json"),
    GitBackup = filename:join(BackupDir, "workspace.git.tar"),
    ConfigSrc = openpixie_config:config_path(),
    {ok, _} = file:copy(ConfigSrc, ConfigBackup),
    copy_dir(TopicsDir, TopicsBackup),
    copy_dir(WsDir, WsBackup),
    git_archive(WsDir, GitBackup),
    #{success => true, message => iolist_to_binary(["Backup created at ", BackupDir]),
      backup_dir => list_to_binary(BackupDir), timestamp => iolist_to_binary(Stamp)}.

reload_single_module(undefined) ->
    #{success => false, error => module_required};
reload_single_module(ModuleBin) ->
    Module = try binary_to_existing_atom(ModuleBin, utf8) catch _:_ -> undefined end,
    case Module of
        undefined -> #{success => false, error => unknown_module};
        _ ->
            Ws = openpixie_config:workspace(),
            EbinDir = filename:join(Ws, "ebin"),
            SrcFile = filename:join([Ws, "src", atom_to_list(Module) ++ ".erl"]),
            case filelib:is_file(SrcFile) of
                true ->
                    case compile:file(SrcFile, [{outdir, EbinDir}, return_errors]) of
                        {ok, Module} ->
                            code:load_abs(filename:join(EbinDir, atom_to_list(Module))),
                            #{success => true, message => iolist_to_binary(["Module ", ModuleBin, " recompiled and reloaded"])};
                        {error, Errors, _Warnings} ->
                            #{success => false, error => iolist_to_binary(io_lib:format("Compile errors: ~p", [Errors]))}
                    end;
                false ->
                    case code:which(Module) of
                        non_existing -> #{success => false, error => <<"Module not found">>};
                        Path ->
                            code:load_abs(filename:rootname(Path)),
                            #{success => true, message => iolist_to_binary(["Module ", ModuleBin, " reloaded from release"])}
                    end
            end
    end.

reload_all_modules() ->
    Ws = openpixie_config:workspace(),
    EbinDir = filename:join(Ws, "ebin"),
    SrcDir = filename:join(Ws, "src"),
    case file:list_dir(SrcDir) of
        {ok, Files} ->
            ErlFiles = [F || F <- Files, filename:extension(F) =:= ".erl"],
            lists:filtermap(fun(F) ->
                ModuleStr = filename:rootname(F),
                Module = try list_to_existing_atom(ModuleStr) catch _:_ -> undefined end,
                case Module of
                    undefined -> false;
                    _ ->
                        SrcFile = filename:join(SrcDir, F),
                        case compile:file(SrcFile, [{outdir, EbinDir}, return_errors]) of
                            {ok, Module} ->
                                code:load_abs(filename:join(EbinDir, ModuleStr)),
                                {true, list_to_binary(ModuleStr)};
                            {error, _Errors, _Warnings} ->
                                false
                        end
                end
            end, ErlFiles);
        {error, _} -> []
    end.

git_commit(Dir, Msg) ->
    os:cmd("cd " ++ Dir ++ " && git add -A && git commit -m '" ++ Msg ++ "' 2>/dev/null"),
    ok.

git_archive(Dir, OutFile) ->
    os:cmd("cd " ++ Dir ++ " && git archive --format=tar HEAD > " ++ OutFile ++ " 2>/dev/null"),
    ok.

copy_dir(Src, Dst) ->
    case filelib:is_dir(Src) of
        true ->
            os:cmd("cp -a " ++ Src ++ " " ++ Dst ++ " 2>/dev/null"),
            ok;
        false -> ok
    end.

del_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(fun(E) ->
                Path = filename:join(Dir, E),
                case filelib:is_dir(Path) of true -> del_dir(Path); false -> file:delete(Path) end
            end, Entries),
            file:del_dir(Dir);
        {error, _} -> ok
    end.

build_page(Status) ->
    ModuleRows = build_module_rows(maps:get(modules, Status, [])),
    ConfigRows = build_config_rows(maps:get(config, Status, #{})),
    TopicCount = maps:get(topic_count, Status, 0),
    SrcOk = maps:get(workspace_src_ok, Status, false),
    iolist_to_binary([<<"<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='UTF-8'>
<meta name='viewport' content='width=device-width, initial-scale=1.0'>
<title>OpenPixie Recovery</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f3f3f3; color: #1a1a1a; padding: 40px; max-width: 900px; margin: 0 auto; }
h1 { color: #0078d4; margin-bottom: 8px; font-weight: 300; letter-spacing: 0.3px; }
p.sub { color: #666; margin-bottom: 24px; }
h2 { color: #0078d4; margin: 24px 0 12px; font-size: 1.1rem; font-weight: 400; }
.section { background: #fff; border: 1px solid #e0e0e0; padding: 20px; margin-bottom: 16px; }
.btn-row { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 16px; }
.btn { padding: 8px 20px; border: none; cursor: pointer; font-weight: 600; font-size: 14px; }
.btn-danger { background: #e81123; color: #fff; }
.btn-danger:hover { background: #c50f1f; }
.btn-warn { background: #fcb900; color: #1a1a1a; }
.btn-warn:hover { background: #e6a800; }
.btn-safe { background: #107c10; color: #fff; }
.btn-safe:hover { background: #0b660d; }
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #e0e0e0; font-size: 13px; }
th { color: #666; font-weight: 600; background: #fafafa; }
#result { margin-top: 16px; padding: 12px; display: none; font-size: 14px; white-space: pre-wrap; }
.result-ok { background: #dff6dd; color: #107c10; border: 2px solid #107c10; }
.result-err { background: #fde7e9; color: #e81123; border: 2px solid #e81123; }
.reload-input { padding: 8px 12px; border: 2px solid #ccc; background: #fff; color: #1a1a1a; font-size: 14px; width: 300px; outline: none; }
.reload-input:focus { border-color: #0078d4; }
#chat-messages { font-size: 13px; height: 320px; overflow-y: auto; background: #fff; border: 1px solid #e0e0e0; padding: 12px; margin-bottom: 12px; }
.chat-msg { margin-bottom: 8px; padding: 8px 12px; white-space: pre-wrap; overflow-wrap: break-word; }
.chat-user { background: #0078d4; color: #fff; margin-left: 20%; }
.chat-assistant { background: #f0f0f0; color: #1a1a1a; margin-right: 20%; }
.chat-error { background: #fde7e9; color: #e81123; border: 2px solid #e81123; }
.chat-tool-step { padding: 4px 8px; font-size: 11px; color: #0078d4; border-left: 3px solid #0078d4; margin: 4px 0; white-space: pre-wrap; overflow-wrap: break-word; }
.chat-tool-result { padding: 4px 8px; font-size: 11px; color: #555; border-left: 3px solid #107c10; margin: 2px 0; max-height: 80px; overflow-y: auto; white-space: pre-wrap; overflow-wrap: break-word; }
</style>
</head>
<body>
<h1>OpenPixie Recovery</h1>
<p class='sub'>Emergency recovery console for self-modification issues</p>
<div class='section'>
<h2>System Status</h2>
<table>
<tr><th>Property</th><th>Value</th></tr>
<tr><td>Workspace source intact</td><td>">>,
if SrcOk -> <<"Yes">>; true -> <<"No">> end,
<<"</td></tr>
<tr><td>Active topics</td><td>">>,
integer_to_binary(TopicCount),
<<"</td></tr>
</table>
<h2>Configuration</h2>
<table><tr><th>Key</th><th>Value</th></tr>">>,
ConfigRows,
<<"</table>
<h2>Loaded Modules</h2>
<table><tr><th>Module</th><th>Path</th></tr>">>,
ModuleRows,
<<"</table></div>
<div class='section'>
<h2>Reload Single Module</h2>
<p>Recompile and hot-reload a module from workspace source (or reload from release).</p>
<div class='btn-row'>
<input type='text' id='mod' class='reload-input' placeholder='e.g. openpixie_ws' />
<button class='btn btn-safe' onclick='reloadModule()'>Reload Module</button>
</div></div>
<div class='section'>
<h2>Sync Instance Changes</h2>
<p><b>Export Changes:</b> Download a git patch of all changes the agent has made to its own source code (self-modifications). Apply this patch to your host repository to persist changes.</p>
<p><b>Import Changes:</b> Upload a git patch (from your host repo) and apply it to the running instance. Changed Erlang modules are automatically compiled and hot-reloaded.</p>
<div class='btn-row'>
<button class='btn btn-safe' onclick='exportChanges()'>Export Changes</button>
</div>
<div style='margin-top:12px'>
<textarea id='import-patch' class='reload-input' style='height:120px;width:100%;font-family:monospace;font-size:12px' placeholder='Paste unified diff patch here...'></textarea>
</div>
<div class='btn-row' style='margin-top:8px'>
<button class='btn btn-safe' onclick='importChanges()'>Import Changes</button>
<button class='btn btn-safe' style='position:relative'>
<span>Upload Patch File</span>
<input type='file' id='patch-file' accept='.patch,.diff,.txt' onchange='handlePatchFile(event)' style='position:absolute;opacity:0;top:0;left:0;width:100%;height:100%;cursor:pointer'>
</button>
</div>
</div>
<div class='section'>
<h2>Reset Operations</h2>
<p><b>Reset Source:</b> Restore all source files from the original release baseline. Clears stale beams.</p>
<p><b>Backup All Data:</b> Create a timestamped backup of config, topics, workspace source, and git history.</p>
<p><b>Download Backup:</b> Download a tar.gz of all data (config, topics, workspace) to your machine.</p>
<p><b>Reset Config:</b> Restore config.json to defaults (permission_mode=ask, etc).</p>
<p><b>Clear Topics:</b> Delete all conversation topics.</p>
<p><b>Reset All:</b> All of the above combined.</p>
<div class='btn-row'>
<button class='btn btn-safe' onclick='act(\"reset_source\")'>Reset Source</button>
<button class='btn btn-safe' onclick='act(\"backup_data\")'>Backup All Data</button>
<button class='btn btn-safe' onclick='downloadBackup()'>Download Backup</button>
<button class='btn btn-warn' onclick='act(\"reset_config\")'>Reset Config</button>
<button class='btn btn-warn' onclick='act(\"clear_topics\")'>Clear Topics</button>
<button class='btn btn-danger' onclick='act(\"reset_all\")'>Reset All</button>
</div></div>
<div class='section'>
<h2>Chat with Agent</h2>
<p>Send messages to the agent even when the main dashboard is unavailable. Tool confirmations are auto-approved in recovery mode.</p>
<div id='chat-messages'></div>
<div class='btn-row' style='margin-top:0'>
<input type='text' id='chat-input' class='reload-input' style='flex:1;width:auto' placeholder='Type a message...' />
<button class='btn btn-safe' id='chat-send' onclick='chatSend()'>Send</button>
<button class='btn btn-danger' id='chat-cancel' onclick='chatCancel()' style='display:none'>Cancel</button>
</div>
<div id='chat-status' style='font-size:12px;color:#888;margin-top:8px;'></div>
</div>
<div id='result'></div>
<script>
var API_KEY = new URLSearchParams(window.location.search).get('key') || '';
function showResult(data, ok) {
    var el = document.getElementById('result');
    el.className = ok ? 'result-ok' : 'result-err';
    el.style.display = 'block';
    el.textContent = JSON.stringify(data, null, 2);
}
async function downloadBackup() {
    try {
        var r = await fetch('/recover?key=' + encodeURIComponent(API_KEY), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({action:'download_backup'})});
        if (r.ok) {
            var blob = await r.blob();
            var url = URL.createObjectURL(blob);
            var a = document.createElement('a');
            a.href = url;
            a.download = 'openpixie_backup.tar.gz';
            document.body.appendChild(a);
            a.click();
            a.remove();
            URL.revokeObjectURL(url);
            showResult({success:true, message:'Download started'}, true);
        } else {
            showResult({error:'Download failed: ' + r.status}, false);
        }
    } catch(e) { showResult({error:e.message}, false); }
}
async function act(a) {
    if (a === 'reset_all' || a === 'clear_topics') { if (!confirm('This will delete data. Proceed?')) return; }
    try {
        var r = await fetch('/recover?key=' + encodeURIComponent(API_KEY), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({action:a})});
        var d = await r.json();
        showResult(d, d.success);
    } catch(e) { showResult({error:e.message}, false); }
}
async function reloadModule() {
    var m = document.getElementById('mod').value.trim();
    if (!m) { alert('Enter a module name'); return; }
    try {
        var r = await fetch('/recover?key=' + encodeURIComponent(API_KEY), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({action:'reload_module', module:m})});
        var d = await r.json();
        showResult(d, d.success);
    } catch(e) { showResult({error:e.message}, false); }
}
var chatTopicId = null;
var chatAbortCtrl = null;
document.getElementById('chat-input').addEventListener('keydown', function(e) { if (e.key === 'Enter') chatSend(); });
async function chatSend() {
    var input = document.getElementById('chat-input');
    var msg = input.value.trim();
    if (!msg) return;
    input.value = '';
    addChatMsg('user', msg);
    document.getElementById('chat-send').disabled = true;
    document.getElementById('chat-cancel').style.display = 'inline-block';
    document.getElementById('chat-status').textContent = 'Agent is thinking...';
    chatAbortCtrl = new AbortController();
    try {
        var body = {content: msg};
        if (chatTopicId) body.topic_id = chatTopicId;
        var r = await fetch('/api/v1/chat?key=' + encodeURIComponent(API_KEY), {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(body),
            signal: chatAbortCtrl.signal
        });
        var d = await r.json();
        if (d.topic_id) chatTopicId = d.topic_id;
        if (d.tool_steps && d.tool_steps.length > 0) {
            d.tool_steps.forEach(function(step) {
                if (step.tool_calls) {
                    step.tool_calls.forEach(function(tc) { addToolStep(tc.tool, tc.args); });
                } else if (step.tool) {
                    addToolResult(step.tool, step.result);
                }
            });
        }
        if (d.type === 'response' && d.message && d.message.content) {
            addChatMsg('assistant', d.message.content);
        } else if (d.type === 'error') {
            addChatMsg('error', d.message || 'An error occurred');
        }
    } catch(e) {
        if (e.name === 'AbortError') {
            addChatMsg('error', 'Request cancelled');
        } else {
            addChatMsg('error', 'Request failed: ' + e.message);
        }
    }
    document.getElementById('chat-send').disabled = false;
    document.getElementById('chat-cancel').style.display = 'none';
    document.getElementById('chat-status').textContent = '';
    chatAbortCtrl = null;
    input.focus();
}
function chatCancel() {
    if (chatAbortCtrl) chatAbortCtrl.abort();
}
function addChatMsg(role, content) {
    var el = document.createElement('div');
    el.className = 'chat-msg chat-' + role;
    el.textContent = content;
    var c = document.getElementById('chat-messages');
    c.appendChild(el);
    c.scrollTop = c.scrollHeight;
}
function addToolStep(toolName, args) {
    var el = document.createElement('div');
    el.className = 'chat-tool-step';
    var s = typeof args === 'object' ? JSON.stringify(args) : String(args);
    if (s.length > 300) s = s.substring(0, 300) + '...';
    el.textContent = 'Tool: ' + toolName + ' — ' + s;
    var c = document.getElementById('chat-messages');
    c.appendChild(el);
    c.scrollTop = c.scrollHeight;
}
function addToolResult(toolName, result) {
    var el = document.createElement('div');
    el.className = 'chat-tool-result';
    var s = typeof result === 'string' ? result : JSON.stringify(result);
    if (s.length > 500) s = s.substring(0, 500) + '...[truncated]';
    el.textContent = 'Result: ' + toolName + ' — ' + s;
    var c = document.getElementById('chat-messages');
    c.appendChild(el);
    c.scrollTop = c.scrollHeight;
}
async function exportChanges() {
    try {
        var r = await fetch('/api/v1/sync?action=export&key=' + encodeURIComponent(API_KEY));
        if (r.headers.get('content-type') && r.headers.get('content-type').indexOf('json') !== -1) {
            var d = await r.json();
            showResult(d, d.success || d.empty);
        } else {
            var blob = await r.blob();
            var url = URL.createObjectURL(blob);
            var a = document.createElement('a');
            a.href = url;
            a.download = 'openpixie_changes.patch';
            document.body.appendChild(a);
            a.click();
            a.remove();
            URL.revokeObjectURL(url);
            showResult({success: true, message: 'Patch file downloaded'}, true);
        }
    } catch(e) { showResult({error: e.message}, false); }
}
async function importChanges() {
    var patchText = document.getElementById('import-patch').value.trim();
    if (!patchText) { alert('Paste a patch or use Upload Patch File'); return; }
    try {
        var b64 = btoa(patchText);
        var r = await fetch('/api/v1/sync?key=' + encodeURIComponent(API_KEY), {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({action: 'import', patch: b64})
        });
        var d = await r.json();
        showResult(d, d.success);
    } catch(e) { showResult({error: e.message}, false); }
}
function handlePatchFile(event) {
    var file = event.target.files[0];
    if (!file) return;
    var reader = new FileReader();
    reader.onload = function(e) {
        var b64 = btoa(e.target.result);
        fetch('/api/v1/sync?key=' + encodeURIComponent(API_KEY), {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({action: 'import', patch: b64})
        }).then(r => r.json()).then(d => showResult(d, d.success)).catch(err => showResult({error: err.message}, false));
    };
    reader.readAsBinaryString(file);
}
</script>
</body></html>">>]).

build_module_rows([]) -> <<"<tr><td colspan='2'>No modules loaded</td></tr>">>;
build_module_rows(Modules) ->
    iolist_to_binary(lists:map(fun(#{module := M, path := P}) ->
        [<<"<tr><td>">>, M, <<"</td><td>">>, P, <<"</td></tr>">>]
    end, Modules)).

build_config_rows(#{error := _}) -> <<"<tr><td colspan='2'>Unavailable</td></tr>">>;
build_config_rows(Config) ->
    iolist_to_binary(lists:map(fun({K, V}) ->
        KBin = if is_binary(K) -> K; true -> atom_to_binary(K, utf8) end,
        VBin = if is_binary(V) -> V; true -> iolist_to_binary(io_lib:format("~p", [V])) end,
        [<<"<tr><td>">>, KBin, <<"</td><td>">>, VBin, <<"</td></tr>">>]
    end, maps:to_list(Config))).