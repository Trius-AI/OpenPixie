-module(openpixie_tool_registry).
-behaviour(gen_server).
-export([
    start_link/0,
    register/5,
    register/6,
    unregister/1,
    lookup/1,
    list_tools/0,
    list_schemas/0,
    clear_all/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TOOLS_TABLE, openpixie_dynamic_tools).

-record(tool_entry, {
    name :: binary(),
    description :: binary(),
    parameters :: map(),
    handler_module :: atom(),
    handler_function :: atom(),
    category :: binary()
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

register(Name, Description, Parameters, HandlerModule, HandlerFunction) ->
    register(Name, Description, Parameters, HandlerModule, HandlerFunction, <<"general">>).

register(Name, Description, Parameters, HandlerModule, HandlerFunction, Category) ->
    gen_server:call(?SERVER, {register, #tool_entry{
        name = Name,
        description = Description,
        parameters = Parameters,
        handler_module = HandlerModule,
        handler_function = HandlerFunction,
        category = Category
    }}).

unregister(Name) ->
    gen_server:call(?SERVER, {unregister, Name}).

lookup(Name) ->
    case ets:lookup(?TOOLS_TABLE, Name) of
        [#tool_entry{handler_module = Mod, handler_function = Fun, category = Cat}] ->
            {ok, #{module => Mod, function => Fun, category => Cat}};
        [] -> not_found
    end.

list_tools() ->
    ets:tab2list(?TOOLS_TABLE).

list_schemas() ->
    lists:map(fun(#tool_entry{name = Name, description = Desc, parameters = Params}) ->
        #{
            type => function,
            function => #{
                name => Name,
                description => Desc,
                parameters => Params
            }
        }
    end, ets:tab2list(?TOOLS_TABLE)).

clear_all() ->
    gen_server:call(?SERVER, clear_all).

init([]) ->
    ets:new(?TOOLS_TABLE, [named_table, ordered_set, public, {keypos, #tool_entry.name}]),
    load_from_disk(),
    {ok, #{}}.

handle_call({register, #tool_entry{} = Entry}, _From, State) ->
    ets:insert(?TOOLS_TABLE, Entry),
    save_to_disk(),
    {reply, ok, State};

handle_call({unregister, Name}, _From, State) ->
    ets:delete(?TOOLS_TABLE, Name),
    save_to_disk(),
    {reply, ok, State};

handle_call(clear_all, _From, State) ->
    ets:delete_all_objects(?TOOLS_TABLE),
    save_to_disk(),
    {reply, ok, State};

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

save_to_disk() ->
    Ws = openpixie_config:workspace(),
    Dir = filename:join(Ws, ".tool_registry"),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Path = filename:join(Dir, "tools.json"),
    Entries = ets:tab2list(?TOOLS_TABLE),
    JsonList = lists:map(fun(#tool_entry{name = N, description = D, parameters = P,
                                          handler_module = M, handler_function = F, category = C}) ->
        #{
            name => N,
            description => D,
            parameters => jsx:encode(P),
            handler_module => atom_to_binary(M, utf8),
            handler_function => atom_to_binary(F, utf8),
            category => C
        }
    end, Entries),
    Json = jsx:encode(JsonList),
    TmpPath = Path ++ ".tmp",
    case file:write_file(TmpPath, Json) of
        ok -> file:rename(TmpPath, Path);
        {error, _} -> file:delete(TmpPath)
    end,
    ok.

load_from_disk() ->
    Ws = openpixie_config:workspace(),
    Path = filename:join([Ws, ".tool_registry", "tools.json"]),
    case file:read_file(Path) of
        {ok, Content} ->
            case jsx:is_json(Content) of
                true ->
                    Entries = jsx:decode(Content, [return_maps]),
                    lists:foreach(fun(Entry) ->
                        try
                            Name = maps:get(<<"name">>, Entry),
                            Desc = maps:get(<<"description">>, Entry, <<"">>),
                            ParamsJson = maps:get(<<"parameters">>, Entry, <<"{}">>),
                            Params = jsx:decode(ParamsJson, [return_maps]),
                            ModBin = maps:get(<<"handler_module">>, Entry),
                            FunBin = maps:get(<<"handler_function">>, Entry),
                            Cat = maps:get(<<"category">>, Entry, <<"general">>),
                            HandlerModule = try binary_to_existing_atom(ModBin, utf8)
                                catch _:_ -> binary_to_atom(ModBin, utf8) end,
                            HandlerFunction = try binary_to_existing_atom(FunBin, utf8)
                                catch _:_ -> binary_to_atom(FunBin, utf8) end,
                            Record = #tool_entry{
                                name = Name,
                                description = Desc,
                                parameters = Params,
                                handler_module = HandlerModule,
                                handler_function = HandlerFunction,
                                category = Cat
                            },
                            case code:ensure_loaded(HandlerModule) of
                                {module, HandlerModule} ->
                                    case erlang:function_exported(HandlerModule, HandlerFunction, 1) of
                                        true -> ets:insert(?TOOLS_TABLE, Record);
                                        false -> ok
                                    end;
                                _ -> ok
                            end
                        catch _:_ -> ok
                        end
                    end, Entries);
                false -> ok
            end;
        {error, _} -> ok
    end.