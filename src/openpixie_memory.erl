-module(openpixie_memory).
-behaviour(gen_server).

-export([start_link/0, read_memory/0, search_memories/1, recent_memories/1,
         save_typed_memory/3, save_typed_memory/4,
         condense_day/0, condense_month/2, condense_year/1, get_memory_path/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CONDENSE_RETRIES, 3).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    Dir = openpixie_config:memories_dir(),
    catch filelib:ensure_dir(filename:join(Dir, "dummy")),
    {ok, #{dir => Dir}}.

get_memory_path() ->
    filename:join(openpixie_config:memories_dir(), "MEMORY.md").

read_memory() ->
    Path = get_memory_path(),
    case file:read_file(Path) of
        {ok, Content} -> {ok, Content};
        {error, enoent} -> {ok, <<"">>};
        {error, Reason} -> {error, Reason}
    end.

search_memories(Query) when is_binary(Query) ->
    Dir = openpixie_config:memories_dir(),
    Files = find_md_files(Dir),
    Results = lists:filtermap(fun(File) ->
        case file:read_file(File) of
            {ok, Content} ->
                case binary:match(Content, Query) of
                    nomatch -> false;
                    _ -> {true, #{path => list_to_binary(File), excerpt => find_excerpt(Content, Query)}}
                end;
            _ -> false
        end
    end, Files),
    {ok, Results}.

recent_memories(N) when is_integer(N) ->
    Dir = openpixie_config:memories_dir(),
    YearDir = filename:join(Dir, integer_to_list(current_year())),
    case file:list_dir(YearDir) of
        {ok, Months} ->
            Sorted = lists:sort(fun(A, B) -> A >= B end, Months),
            collect_recent_days(YearDir, Sorted, N, []);
        {error, _} ->
            {ok, []}
    end.

condense_day() ->
    do_condense(day, undefined, ?CONDENSE_RETRIES).

condense_month(Year, Month) ->
    do_condense(month, {Year, Month}, ?CONDENSE_RETRIES).

condense_year(Year) ->
    do_condense(year, Year, ?CONDENSE_RETRIES).

do_condense(Type, Args, RetriesLeft) ->
    Model = openpixie_config:ollama_model(),
    case gather_condensation_input(Type, Args) of
        {ok, Input} ->
            Prompt = condensation_prompt(Type, Input),
            Messages = [
                #{role => system, content => <<"You are a memory condensation assistant. You take raw memories and extract the most important facts, preserving specific entities (people, projects, preferences) and dropping conversational filler.">>},
                #{role => user, content => Prompt}
            ],
            case openpixie_ollama:chat(Model, Messages) of
                {ok, #{message := #{content := Content}}} ->
                    OutputPath = condensation_output_path(Type, Args),
                    write_atomic(OutputPath, Content);
                {error, _Reason} when RetriesLeft > 0 ->
                    timer:sleep(1000 * (4 - RetriesLeft)),
                    do_condense(Type, Args, RetriesLeft - 1);
                {error, Reason} ->
                    openpixie_log:error("Memory condensation failed after retries: ~p", [Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

gather_condensation_input(day, _Args) ->
    TopicsDir = openpixie_config:topics_dir(),
    case file:list_dir(TopicsDir) of
        {ok, Topics} ->
            Contents = lists:filtermap(fun(T) ->
                MemFile = filename:join([TopicsDir, T, "memory.md"]),
                case file:read_file(MemFile) of
                    {ok, C} -> {true, C};
                    _ -> false
                end
            end, Topics),
            {ok, iolist_to_binary(Contents)};
        {error, Reason} ->
            {error, Reason}
    end;

gather_condensation_input(month, {Year, Month}) ->
    Dir = filename:join([openpixie_config:memories_dir(), integer_to_list(Year), "month", integer_to_list(Month)]),
    gather_files_in_dir(Dir);

gather_condensation_input(year, Year) ->
    Dir = filename:join([openpixie_config:memories_dir(), integer_to_list(Year)]),
    gather_files_in_dir(Dir).

gather_files_in_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            Contents = lists:filtermap(fun(F) ->
                Full = filename:join(Dir, F),
                case file:read_file(Full) of
                    {ok, C} -> {true, C};
                    _ -> false
                end
            end, Files),
            {ok, iolist_to_binary(Contents)};
        {error, Reason} ->
            {error, Reason}
    end.

condensation_prompt(day, Input) ->
    <<"Given these day memories, extract and merge the most important information.\n"
      "Preserve all critical facts, especially those referencing specific entities "
      "(people, projects, preferences). Drop conversational filler.\n\n"
      "Input memories:\n", Input/binary>>;

condensation_prompt(month, Input) ->
    <<"Given these daily memory summaries for this month, condense them into a monthly summary.\n"
      "Preserve all critical facts. Drop redundant or transient details.\n\n"
      "Input:\n", Input/binary>>;

condensation_prompt(year, Input) ->
    <<"Given these monthly memory summaries for this year, condense them into a yearly summary.\n"
      "Preserve all critical facts. Drop redundant or transient details.\n\n"
      "Input:\n", Input/binary>>.

condensation_output_path(day, _Args) ->
    {Year, Month, Day} = erlang:date(),
    filename:join([openpixie_config:memories_dir(), integer_to_list(Year),
                   "month", integer_to_list(Month),
                   integer_to_list(Day) ++ ".md"]);

condensation_output_path(month, {Year, Month}) ->
    filename:join([openpixie_config:memories_dir(), integer_to_list(Year),
                   "month", integer_to_list(Month), "INDEX.md"]);

condensation_output_path(year, Year) ->
    filename:join([openpixie_config:memories_dir(), integer_to_list(Year), "INDEX.md"]).

write_atomic(Path, Content) ->
    ok = filelib:ensure_dir(Path),
    TmpPath = Path ++ ".tmp",
    ok = file:write_file(TmpPath, Content),
    ok = file:rename(TmpPath, Path),
    {ok, Path}.

find_excerpt(Content, Query) ->
    case binary:match(Content, Query) of
        {Pos, _Len} ->
            Start = max(0, Pos - 50),
            End = min(byte_size(Content), Pos + byte_size(Query) + 50),
            binary:part(Content, Start, End - Start);
        nomatch ->
            <<"">>
    end.

collect_recent_days(_BaseDir, _Months, 0, Acc) -> {ok, Acc};
collect_recent_days(_BaseDir, [], _N, Acc) -> {ok, Acc};
collect_recent_days(BaseDir, [Month | Rest], N, Acc) ->
    MonthDir = filename:join(BaseDir, Month),
    case file:list_dir(MonthDir) of
        {ok, Days} ->
            SortedDays = lists:sort(fun(A, B) -> A >= B end, Days),
            {NewAcc, Remaining} = take_n(SortedDays, N, fun(D) ->
                filename:join(MonthDir, D)
            end, Acc),
            collect_recent_days(BaseDir, Rest, Remaining, NewAcc);
        {error, _} ->
            collect_recent_days(BaseDir, Rest, N, Acc)
    end.

take_n([], N, _Fun, Acc) -> {Acc, N};
take_n(_List, 0, _Fun, Acc) -> {Acc, 0};
take_n([H | T], N, Fun, Acc) ->
    take_n(T, N - 1, Fun, [Fun(H) | Acc]).

current_year() ->
    {Y, _, _} = erlang:date(),
    Y.

save_typed_memory(Type, Content, Confidence) ->
    save_typed_memory(Type, Content, Confidence, undefined).

save_typed_memory(Type, Content, Confidence, _SessionId) ->
    Dir = openpixie_config:memories_dir(),
    {Year, Month, Day} = erlang:date(),
    {Hour, Min, Sec} = erlang:time(),
    Timestamp = io_lib:format("~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0b",
                               [Year, Month, Day, Hour, Min, Sec]),
    Entry = iolist_to_binary([
        <<"[">>, Type, <<"] ">>,
        list_to_binary(Timestamp), <<" ">>,
        Content,
        <<" (confidence: ">>, float_to_binary(Confidence, [{decimals, 2}]), <<")\n">>
    ]),
    DayFile = filename:join([Dir, integer_to_list(Year),
                             "month", integer_to_list(Month),
                             integer_to_list(Day) ++ ".md"]),
    ok = filelib:ensure_dir(DayFile),
    file:write_file(DayFile, Entry, [append]).

find_md_files(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foldl(fun(Entry, Acc) ->
                Path = filename:join(Dir, Entry),
                case filelib:is_dir(Path) of
                    true -> Acc ++ find_md_files(Path);
                    false ->
                        case filename:extension(Path) of
                            ".md" -> [Path | Acc];
                            _ -> Acc
                        end
                end
            end, [], Entries);
        {error, _} -> []
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