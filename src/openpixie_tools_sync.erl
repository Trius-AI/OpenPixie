-module(openpixie_tools_sync).
-export([schema/0, sync_export/1, sync_import/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => sync_export,
                description => <<"Export all instance-local changes (self-modifications) as a unified git patch. Returns the patch content that can be applied to the host repository.">>,
                parameters => #{
                    type => object,
                    properties => #{},
                    required => []
                }
            }
        },
        #{
            type => function,
            function => #{
                name => sync_import,
                description => <<"Import a git patch to apply changes from the host repository into the running instance. Compiles and hot-reloads any changed Erlang modules automatically.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        patch => #{
                            type => string,
                            description => <<"Unified diff patch content to apply">>
                        }
                    },
                    required => [patch]
                }
            }
        }
    ].

sync_export(_Args) ->
    case openpixie_sync:export_patch() of
        {ok, empty} ->
            #{success => true, empty => true, message => <<"No instance-local changes to export">>};
        {ok, Patch} ->
            #{success => true, patch => Patch, message => <<"Instance-local changes exported as patch">>};
        {error, Reason} ->
            ErrBin = iolist_to_binary(io_lib:format("~p", [Reason])),
            #{success => false, error => ErrBin}
    end.

sync_import(Args) ->
    PatchRaw = maps:get(<<"patch">>, Args, maps:get(patch, Args, <<"">>)),
    Result = case is_base64(PatchRaw) of
        true -> openpixie_sync:import_patch(PatchRaw);
        false -> openpixie_sync:import_patch_text(PatchRaw)
    end,
    case Result of
        {ok, Info} ->
            maps:merge(#{success => true, message => <<"Patch applied successfully">>}, Info);
        {error, Reason} ->
            ErrBin = iolist_to_binary(io_lib:format("~p", [Reason])),
            #{success => false, error => ErrBin}
    end.

is_base64(<<>>) -> true;
is_base64(Bin) when byte_size(Bin) > 0 ->
    try base64:decode(Bin), true
    catch error:_ -> false
    end.