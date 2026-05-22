-module(openpixie_code_graph).
-behaviour(gen_server).

-export([
    start_link/0,
    refresh/0,
    refresh_async/0,
    lookup/1,
    lookup/2,
    get_module_info/1,
    get_function_info/2,
    dependents/1,
    dependencies/1,
    search/1,
    summary/0,
    prompt_index/0,
    status/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(STATE_FILE, "code_graph.json").

-record(state, {
    modules = #{} :: map(),
    functions = #{} :: map(),
    calls = #{} :: map(),
    last_refresh = 0 :: integer()
}).

%%===================================================================
%% API
%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

refresh() ->
    gen_server:call(?SERVER, refresh, 60000).

refresh_async() ->
    gen_server:cast(?SERVER, refresh_async).

lookup(Query) ->
    lookup(Query, #{}).
lookup(Query, Opts) ->
    gen_server:call(?SERVER, {lookup, Query, Opts}, 10000).

get_module_info(Module) ->
    gen_server:call(?SERVER, {module_info, Module}, 5000).

get_function_info(Module, Function) ->
    gen_server:call(?SERVER, {function_info, Module, Function}, 5000).

dependents(Module) ->
    gen_server:call(?SERVER, {dependents, Module}, 5000).

dependencies(Module) ->
    gen_server:call(?SERVER, {dependencies, Module}, 5000).

search(Query) ->
    gen_server:call(?SERVER, {search, Query}, 5000).

summary() ->
    gen_server:call(?SERVER, summary, 5000).

prompt_index() ->
    gen_server:call(?SERVER, prompt_index, 5000).

status() ->
    gen_server:call(?SERVER, status, 5000).

%%===================================================================
%% gen_server callbacks
%%===================================================================

init([]) ->
    State = case load_state_file() of
        {ok, SavedModules, SavedFunctions, SavedCalls} ->
            #state{
                modules = SavedModules,
                functions = SavedFunctions,
                calls = SavedCalls,
                last_refresh = erlang:system_time(millisecond)
            };
        {error, _} ->
            case catch do_refresh() of
                {ok, Modules, Functions, Calls} ->
                    spawn(fun() -> catch save_state_file(Modules, Functions, Calls) end),
                    #state{
                        modules = Modules,
                        functions = Functions,
                        calls = Calls,
                        last_refresh = erlang:system_time(millisecond)
                    };
                _ ->
                    #state{}
            end
    end,
    {ok, State}.

handle_call(refresh, _From, State) ->
    case catch do_refresh() of
        {ok, Modules, Functions, Calls} ->
            spawn(fun() -> catch save_state_file(Modules, Functions, Calls) end),
            NewTs = erlang:system_time(millisecond),
            {reply, ok, State#state{modules = Modules, functions = Functions, calls = Calls, last_refresh = NewTs}};
        Error ->
            {reply, {error, Error}, State}
    end;

handle_call({lookup, Query, Opts}, _From, State = #state{modules = Modules, functions = Functions}) ->
    Result = do_lookup(Query, Opts, Modules, Functions),
    {reply, Result, State};

handle_call({module_info, Module}, _From, State = #state{modules = Modules}) ->
    ModuleAtom = normalize_module(Module),
    Result = case maps:get(ModuleAtom, Modules, undefined) of
        undefined -> {error, not_found};
        Info -> {ok, Info}
    end,
    {reply, Result, State};

handle_call({function_info, Module, Function}, _From, State = #state{functions = Functions}) ->
    ModuleAtom = normalize_module(Module),
    FunctionAtom = normalize_function(Function),
    Key = {ModuleAtom, FunctionAtom},
    Result = case maps:get(Key, Functions, undefined) of
        undefined ->
            %% Try to find by iterating
            FuzzyKey = find_function_key(ModuleAtom, FunctionAtom, Functions),
            case FuzzyKey of
                undefined -> {error, not_found};
                K -> {ok, maps:get(K, Functions)}
            end;
        Info -> {ok, Info}
    end,
    {reply, Result, State};

handle_call({dependents, Module}, _From, State = #state{modules = Modules}) ->
    ModuleAtom = normalize_module(Module),
    Result = case maps:get(ModuleAtom, Modules, undefined) of
        undefined -> {ok, []};
        _Info ->
            Deps = maps:fold(fun(Mod, ModInfo, Acc) ->
                case lists:member(ModuleAtom, maps:get(calls, ModInfo, [])) of
                    true -> [Mod | Acc];
                    false -> Acc
                end
            end, [], Modules),
            {ok, lists:sort(Deps)}
    end,
    {reply, Result, State};

handle_call({dependencies, Module}, _From, State = #state{modules = Modules}) ->
    ModuleAtom = normalize_module(Module),
    Result = case maps:get(ModuleAtom, Modules, undefined) of
        undefined -> {ok, []};
        Info -> {ok, maps:get(calls, Info, [])}
    end,
    {reply, Result, State};

handle_call({search, Query}, _From, State = #state{modules = Modules, functions = Functions}) ->
    QueryLower = string:lowercase(binary_to_list(case is_binary(Query) of true -> Query; _ -> list_to_binary(io_lib:format("~p", [Query])) end)),
    MatchingMods = maps:fold(fun(Mod, Info, Acc) ->
        ModStr = string:lowercase(atom_to_list(Mod)),
        Desc = string:lowercase(binary_to_list(maps:get(description, Info, <<"">>))),
        case string:find(ModStr, QueryLower) =/= nomatch orelse string:find(Desc, QueryLower) =/= nomatch of
            true -> [{module, Mod, Info} | Acc];
            false -> Acc
        end
    end, [], Modules),
    MatchingFuns = maps:fold(fun({M, F}, Info, Acc) ->
        FunStr = string:lowercase(atom_to_list(F)),
        Desc = string:lowercase(binary_to_list(maps:get(description, Info, <<"">>))),
        case string:find(FunStr, QueryLower) =/= nomatch orelse string:find(Desc, QueryLower) =/= nomatch of
            true -> [{function, M, F, Info} | Acc];
            false -> Acc
        end
    end, [], Functions),
    {reply, {ok, #{modules => MatchingMods, functions => MatchingFuns}}, State};

handle_call(summary, _From, State = #state{modules = Modules, functions = Functions, last_refresh = Ts}) ->
    Result = #{
        module_count => maps:size(Modules),
        function_count => maps:size(Functions),
        last_refresh => Ts,
        modules => lists:sort(maps:keys(Modules))
    },
    {reply, {ok, Result}, State};

handle_call(prompt_index, _From, State = #state{modules = Modules}) ->
    Result = build_prompt_index(Modules),
    {reply, Result, State};

handle_call(status, _From, State = #state{modules = Modules, last_refresh = Ts}) ->
    {reply, #{
        module_count => maps:size(Modules),
        function_count => maps:size(State#state.functions),
        last_refresh => Ts
    }, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(refresh_async, State) ->
    case catch do_refresh() of
        {ok, Modules, Functions, Calls} ->
            spawn(fun() -> catch save_state_file(Modules, Functions, Calls) end),
            NewTs = erlang:system_time(millisecond),
            {noreply, State#state{modules = Modules, functions = Functions, calls = Calls, last_refresh = NewTs}};
        _ ->
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal: Graph Building
%%===================================================================

do_refresh() ->
    Ws = openpixie_config:workspace(),
    SrcDir = filename:join(Ws, "src"),
    ErlFiles = filelib:wildcard("*.erl", SrcDir),
    AllLoaded = code:all_loaded(),
    PixieLoaded = [M || {M, _} <- AllLoaded, is_openpixie_mod(M)],
    PixiePaths = [filename:join(SrcDir, atom_to_list(M) ++ ".erl") || M <- PixieLoaded],
    AllPaths = lists:usort(PixiePaths ++ [filename:join(SrcDir, F) || F <- ErlFiles]),
    {Modules, Functions, Calls} = lists:foldl(fun(Path, {MAcc, FAcc, CAcc}) ->
        case scan_file(Path) of
            {ok, Mod, ModInfo, FunInfos} ->
                {MAcc#{Mod => ModInfo}, maps:merge(FAcc, FunInfos), CAcc};
            {error, _, _} ->
                {MAcc, FAcc, CAcc}
        end
    end, {#{}, #{}, #{}}, AllPaths),
    {ok, Modules, Functions, Calls}.

scan_file(Path) ->
    case file:read_file(Path) of
        {ok, Content} ->
            ModuleName = filename:basename(Path, ".erl"),
            ModAtom = list_to_atom(ModuleName),
            Lines = binary:split(Content, <<"\n">>, [global]),
            {Exports, ExportedFuns} = parse_exports(Lines),
            {ModDesc, FunDefs} = parse_functions(ModAtom, Lines, ExportedFuns),
            CalledModules = parse_module_calls(Content),
            ModInfo = #{
                description => ModDesc,
                exports => [atom_to_binary(E, utf8) || E <- Exports],
                file => list_to_binary(ModuleName ++ ".erl"),
                line_count => length(Lines),
                calls => CalledModules
            },
            {ok, ModAtom, ModInfo, FunDefs};
        {error, Reason} ->
            {error, Reason, Path}
    end.

parse_exports(Lines) ->
    case find_export_lines(Lines) of
        [] -> {[], []};
        ExportLines ->
            Combined = iolist_to_binary(lists:join(<<" ">>, ExportLines)),
            parse_export_terms(Combined)
    end.

find_export_lines(Lines) ->
    find_export_lines(Lines, false, []).

find_export_lines([], _InExport, Acc) -> lists:reverse(Acc);
find_export_lines([Line | Rest], InExport, Acc) ->
    Trimmed = binary:replace(Line, <<"\t">>, <<" ">>, [global]),
    case InExport of
        false ->
            case binary:match(Trimmed, <<"-export(">>) of
                {MatchPos, _} ->
                    AfterExport = binary:part(Trimmed, MatchPos, byte_size(Trimmed) - MatchPos),
                    case binary:match(AfterExport, <<").">>) of
                        {EndPos, _} ->
                            SingleLine = binary:part(AfterExport, 0, EndPos + 2),
                            find_export_lines(Rest, false, [SingleLine | Acc]);
                        _ ->
                            find_export_lines(Rest, true, [AfterExport | Acc])
                    end;
                nomatch ->
                    find_export_lines(Rest, false, Acc)
            end;
        true ->
            case binary:match(Trimmed, <<").">>) of
                {_, _} ->
                    find_export_lines(Rest, false, [Trimmed | Acc]);
                nomatch ->
                    find_export_lines(Rest, true, [Trimmed | Acc])
            end
    end.

parse_export_terms(Combined) ->
    Stripped = case binary:match(Combined, <<"(">>) of
        {Pos, _} ->
            Inner1 = binary:part(Combined, Pos + 1, byte_size(Combined) - Pos - 1),
            case binary:match(Inner1, <<")">>) of
                {EndPos, _} -> binary:part(Inner1, 0, EndPos);
                _ -> Inner1
            end;
        _ -> Combined
    end,
    Terms = binary:split(Stripped, <<",">>, [global]),
    {Exports, ExportedFuns} = lists:foldl(fun(Term, {EAcc, FAcc}) ->
        Trimmed = trim_ws(Term),
        case binary:match(Trimmed, <<"/">>) of
            {SlashPos, _} ->
                Name = trim_ws(binary:part(Trimmed, 0, SlashPos)),
                ArityBin = trim_ws(binary:part(Trimmed, SlashPos + 1, byte_size(Trimmed) - SlashPos - 1)),
                Arity = case catch binary_to_integer(ArityBin) of
                    N when is_integer(N) -> N;
                    _ -> 0
                end,
                NameAtom = case catch binary_to_existing_atom(Name, utf8) of
                    A when is_atom(A) -> A;
                    _ -> list_to_atom(binary_to_list(Name))
                end,
                {[{NameAtom, Arity} | EAcc], [{NameAtom, Arity} | FAcc]};
            nomatch ->
                {EAcc, FAcc}
        end
    end, {[], []}, Terms),
    {Exports, ExportedFuns}.

parse_functions(ModAtom, Lines, ExportedFuns) ->
    ModDesc = extract_module_desc(Lines),
    {FunDefs, _} = lists:foldl(fun(Line, {Acc, LineNum}) ->
        case parse_function_line(ModAtom, Line, LineNum, ExportedFuns) of
            {ok, Key, Info} -> {Acc#{Key => Info}, LineNum + 1};
            skip -> {Acc, LineNum + 1}
        end
    end, {#{}, 1}, Lines),
    {ModDesc, FunDefs}.

extract_module_desc([]) -> <<"">>;
extract_module_desc([<<"%%", _/binary>> | _] = Lines) ->
    CommentLines = take_comment_lines(Lines, []),
    Desc = iolist_to_binary(lists:join(<<" ">>, CommentLines)),
    case byte_size(Desc) > 200 of
        true -> binary:part(Desc, 0, 200);
        false -> Desc
    end;
extract_module_desc(_) -> <<"">>.

take_comment_lines([], Acc) -> lists:reverse(Acc);
take_comment_lines([<<"%%", Rest/binary>> | T], Acc) ->
    take_comment_lines(T, [trim_ws(Rest) | Acc]);
take_comment_lines([<<"%", _/binary>> | T], Acc) when Acc =/= [] ->
    take_comment_lines(T, Acc);
take_comment_lines([_ | _], Acc) -> lists:reverse(Acc).

parse_function_line(ModAtom, Line, LineNum, ExportedFuns) ->
    case re:run(Line, <<"^([a-z_][a-zA-Z0-9_]*)\\s*\\(">>, [{capture, [1], binary}]) of
        {match, [NameBin]} ->
            Name = try binary_to_existing_atom(NameBin, utf8) catch _:_ -> list_to_atom(binary_to_list(NameBin)) end,
            Arity = count_args_in_line(Line),
            Key = {ModAtom, Name},
            IsExported = lists:member({Name, Arity}, ExportedFuns),
            Doc = extract_preceding_comment(Line),
            Info = #{
                arity => Arity,
                exported => IsExported,
                line => LineNum,
                description => Doc
            },
            {ok, Key, Info};
        nomatch ->
            skip
    end.

count_args_in_line(Line) ->
    case binary:match(Line, <<"(">>) of
        {Pos, _} when Pos < byte_size(Line) ->
            Rest = binary:part(Line, Pos, byte_size(Line) - Pos),
            count_commas(Rest, 0, 0);
        _ -> 0
    end.

count_commas(<<>>, _Depth, Count) -> Count;
count_commas(<<$(, Rest/binary>>, Depth, Count) -> count_commas(Rest, Depth + 1, Count);
count_commas(<<$), _/binary>>, 1, Count) -> Count;
count_commas(<<$), Rest/binary>>, Depth, Count) -> count_commas(Rest, Depth - 1, Count);
count_commas(<<$,, Rest/binary>>, 1, Count) -> count_commas(Rest, 1, Count + 1);
count_commas(<<$,, Rest/binary>>, Depth, Count) -> count_commas(Rest, Depth, Count);
count_commas(<<_, Rest/binary>>, Depth, Count) -> count_commas(Rest, Depth, Count).

extract_preceding_comment(Line) ->
    case binary:match(Line, <<"->">>) of
        {ArrowPos, _} when ArrowPos + 2 < byte_size(Line) ->
            AfterArrow = binary:part(Line, ArrowPos + 2, byte_size(Line) - ArrowPos - 2),
            AfterArrow2 = trim_ws(AfterArrow),
            case AfterArrow2 of
                <<"%%", Desc/binary>> -> trim_ws(Desc);
                <<"%", Desc/binary>> -> trim_ws(Desc);
                _ -> <<"">>
            end;
        _ -> <<"">>
    end.

parse_module_calls(Content) ->
    Pattern = <<"openpixie_">>,
    Positions = binary:matches(Content, Pattern),
    lists:usort(lists:filtermap(fun({Pos, _}) ->
        Remaining = binary:part(Content, Pos, min(byte_size(Content) - Pos, 60)),
        case re:run(Remaining, <<"openpixie_[a-z_]+">>, [{capture, [0], binary}]) of
            {match, [Match]} ->
                try binary_to_existing_atom(Match, utf8) of
                    Atom -> {true, Atom}
                catch _:_ -> {true, list_to_atom(binary_to_list(Match))}
                end;
            nomatch -> false
        end
    end, Positions)).

%%===================================================================
%% Internal: Lookup
%%===================================================================

do_lookup(Query, Opts, Modules, Functions) ->
    QueryBin = case is_binary(Query) of true -> Query; _ -> list_to_binary(io_lib:format("~p", [Query])) end,
    QueryLower = string:lowercase(binary_to_list(QueryBin)),
    Kind = maps:get(<<"kind">>, Opts, <<"all">>),
    ModResults = case Kind of
        <<"function">> -> [];
        _ -> search_modules(QueryLower, Modules)
    end,
    FunResults = case Kind of
        <<"module">> -> [];
        _ -> search_functions(QueryLower, Functions)
    end,
    {ok, #{modules => ModResults, functions => FunResults}}.

search_modules(QueryLower, Modules) ->
    maps:fold(fun(Mod, Info, Acc) ->
        ModStr = string:lowercase(atom_to_list(Mod)),
        Desc = string:lowercase(binary_to_list(maps:get(description, Info, <<"">>))),
        case string:find(ModStr, QueryLower) =/= nomatch orelse string:find(Desc, QueryLower) =/= nomatch of
            true -> [{Mod, Info} | Acc];
            false -> Acc
        end
    end, [], Modules).

search_functions(QueryLower, Functions) ->
    maps:fold(fun({M, F}, Info, Acc) ->
        FunStr = string:lowercase(atom_to_list(F)),
        Desc = string:lowercase(binary_to_list(maps:get(description, Info, <<"">>))),
        case string:find(FunStr, QueryLower) =/= nomatch orelse string:find(Desc, QueryLower) =/= nomatch of
            true -> [{M, F, Info} | Acc];
            false -> Acc
        end
    end, [], Functions).

%%===================================================================
%% Internal: Prompt Index
%%===================================================================

build_prompt_index(Modules) ->
    SortedMods = lists:sort(maps:keys(Modules)),
    Lines = lists:foldl(fun(Mod, Acc) ->
        Info = maps:get(Mod, Modules, #{}),
        Desc = maps:get(description, Info, <<"">>),
        Exports = maps:get(exports, Info, []),
        File = maps:get(file, Info, <<"">>),
        Calls = maps:get(calls, Info, []),
        CallsBin = case Calls of
            [] -> <<"">>;
            _ ->
                CallBins = [atom_to_binary(C, utf8) || C <- Calls],
                <<" calls: ", (iolist_to_binary(lists:join(<<", ">>, CallBins)))/binary>>
        end,
        DescPart = case Desc of
            <<>> -> <<"">>;
            _ -> <<" — ", Desc/binary>>
        end,
        ExportStr = iolist_to_binary(lists:join(<<", ">>, lists:sublist(Exports, 30))),
        Line = <<"`", (atom_to_binary(Mod, utf8))/binary, "` (", File/binary, ")", DescPart/binary,
                 CallsBin/binary, "\n  exports: ", ExportStr/binary>>,
        [Line, <<"\n">> | Acc]
    end, [], SortedMods),
    iolist_to_binary([<<"## Code Graph\n\nModule index (file, description, calls, exports):\n\n">> | Lines]).

%%===================================================================
%% Internal: Helpers
%%===================================================================

normalize_module(Module) when is_atom(Module) -> Module;
normalize_module(Module) when is_binary(Module) ->
    try binary_to_existing_atom(Module, utf8) catch _:_ -> list_to_atom(binary_to_list(Module)) end;
normalize_module(Module) when is_list(Module) -> list_to_atom(Module).

normalize_function(Function) when is_atom(Function) -> Function;
normalize_function(Function) when is_binary(Function) ->
    try binary_to_existing_atom(Function, utf8) catch _:_ -> list_to_atom(binary_to_list(Function)) end;
normalize_function(Function) when is_list(Function) -> list_to_atom(Function).

find_function_key(ModuleAtom, FunctionAtom, Functions) ->
    Keys = maps:keys(Functions),
    Pred = fun({M, F}) -> M =:= ModuleAtom andalso F =:= FunctionAtom end,
    case lists:filter(Pred, Keys) of
        [K | _] -> K;
        [] -> undefined
    end.

trim_ws(Bin) when is_binary(Bin) ->
    re:replace(Bin, <<"^\\s+|\\s+$">>, <<"">>, [{return, binary}]);
trim_ws(List) when is_list(List) ->
    trim_ws(list_to_binary(List)).

is_openpixie_mod(M) when is_atom(M) ->
    Name = atom_to_binary(M, utf8),
    case byte_size(Name) >= 10 of
        true -> binary:part(Name, 0, 10) =:= <<"openpixie_">>;
        false -> false
    end;
is_openpixie_mod(_) -> false.

%%===================================================================
%% Internal: Persistence
%%===================================================================

save_state_file(Modules, Functions, Calls) ->
    PixieDir = openpixie_config:pixie_dir(),
    Path = filename:join(PixieDir, ?STATE_FILE),
    ok = filelib:ensure_dir(filename:join(PixieDir, "dummy")),
    Serialized = #{
        <<"modules">> => serialize_modules(Modules),
        <<"functions">> => serialize_functions(Functions),
        <<"calls">> => serialize_calls(Calls)
    },
    Encoded = jsx:encode(Serialized),
    TmpPath = Path ++ ".tmp",
    ok = file:write_file(TmpPath, Encoded),
    ok = file:rename(TmpPath, Path),
    ok.

load_state_file() ->
    PixieDir = openpixie_config:pixie_dir(),
    Path = filename:join(PixieDir, ?STATE_FILE),
    case file:read_file(Path) of
        {ok, Content} ->
            try
                Decoded = jsx:decode(Content, [return_maps]),
                Modules = deserialize_modules(maps:get(<<"modules">>, Decoded, #{})),
                Functions = deserialize_functions(maps:get(<<"functions">>, Decoded, #{})),
                Calls = deserialize_calls(maps:get(<<"calls">>, Decoded, #{})),
                {ok, Modules, Functions, Calls}
            catch
                _:_ -> {error, parse_error}
            end;
        {error, _} ->
            {error, not_found}
    end.

serialize_modules(Modules) ->
    maps:fold(fun(Mod, Info, Acc) ->
        ModBin = atom_to_binary(Mod, utf8),
        Acc#{ModBin => #{
            <<"description">> => maps:get(description, Info, <<"">>),
            <<"exports">> => maps:get(exports, Info, []),
            <<"file">> => maps:get(file, Info, <<"">>),
            <<"line_count">> => maps:get(line_count, Info, 0),
            <<"calls">> => [atom_to_binary(C, utf8) || C <- maps:get(calls, Info, [])]
        }}
    end, #{}, Modules).

serialize_functions(Functions) ->
    maps:fold(fun({M, F}, Info, Acc) ->
        Key = <<(atom_to_binary(M, utf8))/binary, "::", (atom_to_binary(F, utf8))/binary>>,
        Acc#{Key => #{
            <<"arity">> => maps:get(arity, Info, 0),
            <<"exported">> => maps:get(exported, Info, false),
            <<"line">> => maps:get(line, Info, 0),
            <<"description">> => maps:get(description, Info, <<"">>)
        }}
    end, #{}, Functions).

serialize_calls(_Calls) ->
    #{}.

deserialize_modules(Data) when is_map(Data) ->
    maps:fold(fun(ModBin, Info, Acc) ->
        Mod = try binary_to_existing_atom(ModBin, utf8) catch _:_ -> list_to_atom(binary_to_list(ModBin)) end,
        CallsList = [try binary_to_existing_atom(C, utf8) catch _:_ -> list_to_atom(binary_to_list(C)) end
                     || C <- maps:get(<<"calls">>, Info, [])],
        Acc#{Mod => #{
            description => maps:get(<<"description">>, Info, <<"">>),
            exports => maps:get(<<"exports">>, Info, []),
            file => maps:get(<<"file">>, Info, <<"">>),
            line_count => maps:get(<<"line_count">>, Info, 0),
            calls => CallsList
        }}
    end, #{}, Data);
deserialize_modules(_) -> #{}.

deserialize_functions(Data) when is_map(Data) ->
    maps:fold(fun(Key, Info, Acc) ->
        case binary:split(Key, <<"::">>) of
            [ModBin, FunBin] ->
                M = try binary_to_existing_atom(ModBin, utf8) catch _:_ -> list_to_atom(binary_to_list(ModBin)) end,
                F = try binary_to_existing_atom(FunBin, utf8) catch _:_ -> list_to_atom(binary_to_list(FunBin)) end,
                Acc#{{M, F} => #{
                    arity => maps:get(<<"arity">>, Info, 0),
                    exported => maps:get(<<"exported">>, Info, false),
                    line => maps:get(<<"line">>, Info, 0),
                    description => maps:get(<<"description">>, Info, <<"">>)
                }};
            _ -> Acc
        end
    end, #{}, Data);
deserialize_functions(_) -> #{}.

deserialize_calls(_Data) ->
    #{}.
