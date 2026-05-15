-module(openpixie_skills).
-behaviour(gen_server).

-export([start_link/0, list_skills/0, load_skill/1, build_skills_summary/0,
          rescan/0, create_skill/2, update_skill/2, delete_skill/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(SKILLS_TABLE, openpixie_skills_cache).

-record(skill, {
    name :: binary(),
    description :: binary(),
    always = false :: boolean(),
    path :: string(),
    tags = [] :: [binary()],
    loaded_content = undefined :: binary() | undefined
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ets:new(?SKILLS_TABLE, [named_table, public, set]),
    scan_skills(),
    {ok, #{}}.

list_skills() ->
    ets:tab2list(?SKILLS_TABLE).

load_skill(Name) when is_binary(Name) ->
    load_skill(binary_to_list(Name));
load_skill(Name) ->
    case ets:lookup(?SKILLS_TABLE, Name) of
        [{Name, #skill{path = Path}}] ->
            case file:read_file(filename:join(Path, "SKILL.md")) of
                {ok, Content} -> {ok, Content};
                {error, Reason} -> {error, {read_failed, Reason}}
            end;
        [] ->
            {error, not_found}
    end.

build_skills_summary() ->
    Skills = ets:tab2list(?SKILLS_TABLE),
    Entries = lists:map(fun({Name, #skill{description = Desc, path = Path}}) ->
        {list_to_binary(Name), [
            {<<"name">>, list_to_binary(Name)},
            {<<"description">>, Desc},
            {<<"location">>, list_to_binary(filename:join(Path, "SKILL.md"))}
        ]}
    end, Skills),
    jsx:encode(#{skills => Entries}).

rescan() ->
    ets:delete_all_objects(?SKILLS_TABLE),
    scan_skills(),
    ok.

create_skill(Name, Content) when is_binary(Name), is_binary(Content) ->
    SkillsDir = openpixie_config:skills_dir(),
    SkillDir = filename:join(SkillsDir, binary_to_list(Name)),
    SkillFile = filename:join(SkillDir, "SKILL.md"),
    case filelib:is_file(SkillFile) of
        true -> {error, already_exists};
        false ->
            ok = filelib:ensure_dir(SkillFile),
            case file:write_file(SkillFile, Content) of
                ok ->
                    Skill = parse_skill(binary_to_list(Name), SkillDir, Content),
                    ets:insert(?SKILLS_TABLE, {binary_to_list(Name), Skill}),
                    {ok, Skill};
                {error, Reason} -> {error, {write_failed, Reason}}
            end
    end.

update_skill(Name, Content) when is_binary(Name), is_binary(Content) ->
    case ets:lookup(?SKILLS_TABLE, binary_to_list(Name)) of
        [{Key, #skill{path = Path}}] ->
            SkillFile = filename:join(Path, "SKILL.md"),
            case file:write_file(SkillFile, Content) of
                ok ->
                    Skill = parse_skill(Key, Path, Content),
                    ets:insert(?SKILLS_TABLE, {Key, Skill}),
                    {ok, Skill};
                {error, Reason} -> {error, {write_failed, Reason}}
            end;
        [] ->
            SkillsDir = openpixie_config:skills_dir(),
            SkillDir = filename:join(SkillsDir, binary_to_list(Name)),
            SkillFile = filename:join(SkillDir, "SKILL.md"),
            ok = filelib:ensure_dir(SkillFile),
            case file:write_file(SkillFile, Content) of
                ok ->
                    Skill = parse_skill(binary_to_list(Name), SkillDir, Content),
                    ets:insert(?SKILLS_TABLE, {binary_to_list(Name), Skill}),
                    {ok, Skill};
                {error, Reason} -> {error, {write_failed, Reason}}
            end
    end.

delete_skill(Name) when is_binary(Name) ->
    case ets:lookup(?SKILLS_TABLE, binary_to_list(Name)) of
        [{Key, #skill{path = Path}}] ->
            SkillFile = filename:join(Path, "SKILL.md"),
            file:delete(SkillFile),
            del_dir(Path),
            ets:delete(?SKILLS_TABLE, Key),
            ok;
        [] ->
            {error, not_found}
    end.

del_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, []} -> file:del_dir(Dir);
        _ -> ok
    end.

scan_skills() ->
    UserSkillsDir = openpixie_config:skills_dir(),
    BuiltinSkillsDir = case code:priv_dir(openpixie) of
        {error, _} -> "";
        Dir -> filename:join(Dir, "skills")
    end,
    scan_dir(BuiltinSkillsDir),
    scan_dir(UserSkillsDir).

scan_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(fun(Entry) ->
                Path = filename:join(Dir, Entry),
                SkillFile = filename:join(Path, "SKILL.md"),
                case filelib:is_file(SkillFile) of
                    true ->
                        case file:read_file(SkillFile) of
                            {ok, Content} ->
                                Skill = parse_skill(Entry, Path, Content),
                                ets:insert(?SKILLS_TABLE, {Entry, Skill});
                            {error, _} -> ok
                        end;
                    false -> ok
                end
            end, Entries);
        {error, _} -> ok
    end.

parse_skill(Name, Path, Content) ->
    {Frontmatter, _Body} = parse_frontmatter(Content),
    Desc = maps:get(<<"description">>, Frontmatter, <<"">>),
    Always = maps:get(<<"always">>, Frontmatter, false),
    Tags = maps:get(<<"tags">>, Frontmatter, []),
    #skill{name = list_to_binary(Name), description = Desc,
           always = Always, path = Path, tags = Tags}.

parse_frontmatter(Content) ->
    case binary:split(Content, <<"---">>, []) of
        [_, Rest] ->
            case binary:split(Rest, <<"---">>, []) of
                [FmBin, Body] ->
                    {parse_yaml_simple(FmBin), Body};
                _ ->
                    {#{}, Content}
            end;
        _ ->
            {#{}, Content}
    end.

parse_yaml_simple(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim]),
    lists:foldl(fun(Line, Acc) ->
        case binary:split(string:trim(Line), <<":">>) of
            [Key, Val] ->
                K = string:trim(Key),
                V = string:trim(Val),
                Acc#{K => parse_yaml_val(V)};
            _ -> Acc
        end
    end, #{}, Lines).

parse_yaml_val(<<"true">>) -> true;
parse_yaml_val(<<"false">>) -> false;
parse_yaml_val(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> V
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.