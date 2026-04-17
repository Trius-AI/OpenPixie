-module(openpixie_soul).
-export([read/0, propose_edit/1, apply_proposal/1, reject_proposal/1, get_proposal/0, init_template/1]).

-define(PROPOSAL_FILE, "SOUL.md.proposed").

read() ->
    Path = openpixie_config:soul_path(),
    case file:read_file(Path) of
        {ok, Content} -> {ok, Content};
        {error, enoent} -> {ok, <<"">>};
        {error, Reason} -> {error, Reason}
    end.

propose_edit(NewContent) when is_binary(NewContent) ->
    Dir = openpixie_config:pixie_dir(),
    ProposalPath = filename:join(Dir, ?PROPOSAL_FILE),
    ok = file:write_file(ProposalPath, NewContent),
    {ok, ProposalPath}.

get_proposal() ->
    Dir = openpixie_config:pixie_dir(),
    ProposalPath = filename:join(Dir, ?PROPOSAL_FILE),
    case file:read_file(ProposalPath) of
        {ok, Content} -> {ok, Content};
        {error, enoent} -> {error, no_proposal};
        {error, Reason} -> {error, Reason}
    end.

apply_proposal(_ApprovalData) ->
    Dir = openpixie_config:pixie_dir(),
    ProposalPath = filename:join(Dir, ?PROPOSAL_FILE),
    TargetPath = openpixie_config:soul_path(),
    case file:read_file(ProposalPath) of
        {ok, Content} ->
            ok = write_atomic(TargetPath, Content),
            ok = file:delete(ProposalPath),
            git_commit_soul(TargetPath, Content),
            {ok, TargetPath};
        {error, Reason} ->
            {error, Reason}
    end.

reject_proposal(_Reason) ->
    Dir = openpixie_config:pixie_dir(),
    ProposalPath = filename:join(Dir, ?PROPOSAL_FILE),
    file:delete(ProposalPath),
    ok.

init_template(UserConfig) when is_map(UserConfig) ->
    Name = maps:get(name, UserConfig, <<"Pixie">>),
    Personality = maps:get(personality, UserConfig, <<"helpful and thoughtful">>),
    Style = maps:get(communication_style, UserConfig, <<"clear and concise">>),
    Template = <<"# Soul Definition\n\n"
                 "I am ", Name/binary, ".\n\n"
                 "## Personality\n"
                 "I am ", Personality/binary, ".\n\n"
                 "## Communication Style\n"
                 "I communicate in a ", Style/binary, " manner.\n\n"
                 "## Core Values\n"
                 "- Be helpful and honest\n"
                 "- Respect the user's preferences\n"
                 "- Learn from conversations\n"
                 "- Reflect on my behavior daily\n">>,
    Path = openpixie_config:soul_path(),
    ok = filelib:ensure_dir(Path),
    ok = write_atomic(Path, Template),
    {ok, Path}.

write_atomic(Path, Content) ->
    TmpPath = Path ++ ".tmp",
    ok = file:write_file(TmpPath, Content),
    file:rename(TmpPath, Path).

git_commit_soul(Path, _Content) ->
    Ws = openpixie_config:workspace(),
    Cmd = lists:flatten(io_lib:format("cd ~s && git add ~s && git commit -m 'Update SOUL.md' 2>&1", [Ws, Path])),
    os:cmd(Cmd),
    ok.