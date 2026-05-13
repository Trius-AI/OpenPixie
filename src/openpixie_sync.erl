-module(openpixie_sync).
-export([
    export_patch/0,
    import_patch/1,
    import_patch_text/1,
    get_diff/0,
    get_baseline_hash/0,
    auto_compile_changed/0
]).

-define(SYNC_TIMEOUT, 30000).

export_patch() ->
    Ws = openpixie_config:workspace(),
    case ensure_git_repo(Ws) of
        {error, Reason} -> {error, {git_init_failed, Reason}};
        ok ->
            commit_dirty(Ws),
            case get_baseline_hash() of
                {error, no_baseline} ->
                    {error, no_baseline};
                {ok, Baseline} ->
                    DiffCmd = git_cmd(Ws, "git diff --binary " ++ binary_to_list(Baseline) ++ "..HEAD"),
                    case run_cmd(DiffCmd) of
                        {ok, Patch} ->
                            case byte_size(Patch) of
                                0 -> {ok, empty};
                                _ -> {ok, Patch}
                            end;
                        {error, _} = Err -> Err
                    end
            end
    end.

import_patch(PatchBase64) ->
    case base64_to_binary(PatchBase64) of
        {error, _} = Err -> Err;
        PatchBin ->
            import_patch_text(PatchBin)
    end.

import_patch_text(PatchBin) when is_binary(PatchBin) ->
    Ws = openpixie_config:workspace(),
    case ensure_git_repo(Ws) of
        {error, Reason} -> {error, {git_init_failed, Reason}};
        ok ->
            TmpFile = filename:join(Ws, ".sync_import.patch"),
            case file:write_file(TmpFile, PatchBin) of
                {error, Reason} -> {error, {write_patch_failed, Reason}};
                ok ->
                    ApplyCmd = git_cmd(Ws, "git apply --3way " ++ shell_escape(TmpFile)),
                    case run_cmd(ApplyCmd) of
                        {ok, Output} ->
                            file:delete(TmpFile),
                            commit_dirty(Ws),
                            CompileResult = auto_compile_changed(),
                            {ok, #{compiled_modules => CompileResult, apply_output => Output}};
                        {error, ApplyErr} ->
                            file:delete(TmpFile),
                            {error, {apply_failed, ApplyErr}}
                    end
            end
    end.

get_diff() ->
    Ws = openpixie_config:workspace(),
    case ensure_git_repo(Ws) of
        {error, Reason} -> {error, {git_init_failed, Reason}};
        ok ->
            commit_dirty(Ws),
            case get_baseline_hash() of
                {error, no_baseline} ->
                    StatusCmd = git_cmd(Ws, "git status --short"),
                    run_cmd(StatusCmd);
                {ok, Baseline} ->
                    DiffCmd = git_cmd(Ws, "git diff --stat " ++ binary_to_list(Baseline) ++ "..HEAD"),
                    run_cmd(DiffCmd)
            end
    end.

get_baseline_hash() ->
    Ws = openpixie_config:workspace(),
    Cmd = git_cmd(Ws, "git log --format=%H -1 --grep=\"Baseline:\""),
    case run_cmd(Cmd) of
        {ok, Output} ->
            Lines = binary:split(Output, <<"\n">>, [global]),
            case [L || L <- Lines, byte_size(L) > 0] of
                [Hash | _] when byte_size(Hash) >= 7 ->
                    {ok, binary:part(Hash, 0, min(40, byte_size(Hash)))};
                _ ->
                    {error, no_baseline}
            end;
        {error, _} ->
            {error, no_baseline}
    end.

auto_compile_changed() ->
    Ws = openpixie_config:workspace(),
    case get_baseline_hash() of
        {error, _} -> [];
        {ok, Baseline} ->
            DiffCmd = git_cmd(Ws, "git diff --name-only --diff-filter=ACMR " ++ binary_to_list(Baseline) ++ "..HEAD"),
            case run_cmd(DiffCmd) of
                {ok, Output} ->
                    Files = binary:split(Output, <<"\n">>, [global]),
                    ErlFiles = [F || F <- Files, filename:extension(F) =:= <<".erl">>],
                    lists:filtermap(fun(F) ->
                        compile_and_reload(F, Ws)
                    end, ErlFiles);
                {error, _} -> []
            end
    end.

compile_and_reload(ErlPath, Ws) ->
    SrcPath = filename:join(Ws, binary_to_list(ErlPath)),
    ModuleName = list_to_atom(filename:basename(binary_to_list(ErlPath), ".erl")),
    EbinDir = filename:join(Ws, "ebin"),
    case compile:file(SrcPath, [{outdir, EbinDir}, return_errors]) of
        {ok, ModuleName} ->
            code:load_abs(filename:join(EbinDir, atom_to_list(ModuleName))),
            {true, atom_to_binary(ModuleName, utf8)};
        _ ->
            false
    end.

ensure_git_repo(Ws) ->
    Dir = filename:join(Ws, ".git"),
    case filelib:is_dir(Dir) of
        true -> ok;
        false ->
            Cmd = git_cmd(Ws, "git init"),
            case run_cmd(Cmd) of
                {ok, _} -> ok;
                {error, _} = Err -> Err
            end
    end.

commit_dirty(Ws) ->
    AddCmd = git_cmd(Ws, "git add -A"),
    case run_cmd(AddCmd) of
        {ok, _} ->
            CommitCmd = git_cmd(Ws, "git diff --cached --quiet || git commit -m 'sync: auto-commit pending changes'"),
            run_cmd(CommitCmd);
        {error, _} -> ok
    end.

git_cmd(Ws, GitCmd) ->
    "sh -c " ++ shell_escape("cd " ++ shell_escape_raw(Ws) ++ " && " ++ GitCmd).

run_cmd(Cmd) ->
    case openpixie_tools_command:run_command_with_port(Cmd, ?SYNC_TIMEOUT) of
        #{success := true, output := Output} ->
            {ok, Output};
        #{success := true} ->
            {ok, <<>>};
        #{success := false, error := Error} ->
            ErrBin = if is_binary(Error) -> Error; true -> iolist_to_binary(io_lib:format("~p", [Error])) end,
            {error, ErrBin};
        #{output := Output} ->
            {ok, Output};
        _ ->
            {error, unknown}
    end.

base64_to_binary(B64) when is_binary(B64) ->
    try base64:decode(B64)
    catch error:_ -> {error, invalid_base64}
    end;
base64_to_binary(_) ->
    {error, invalid_input}.

shell_escape(Str) when is_binary(Str) ->
    shell_escape(binary_to_list(Str));
shell_escape(Str) when is_list(Str) ->
    lists:flatten("'" ++ string:replace(Str, "'", "'\\''", all) ++ "'").

shell_escape_raw(Str) when is_binary(Str) ->
    shell_escape_raw(binary_to_list(Str));
shell_escape_raw(Str) when is_list(Str) ->
    lists:flatten(string:replace(Str, "'", "'\\''")).