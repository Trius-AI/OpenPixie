-module(openpixie_log).
-export([start/0, info/2, debug/2, error/2, warn/2]).

start() ->
    case application:start(lager) of
        ok -> ok;
        {error, {already_started, lager}} -> ok;
        _ -> ok
    end.

info(Fmt, Args) ->
    try lager:info(Fmt, Args)
    catch _:_ -> error_logger:info_msg(Fmt ++ "~n", Args)
    end.

debug(Fmt, Args) ->
    try lager:debug(Fmt, Args)
    catch _:_ -> error_logger:info_msg("[DEBUG] " ++ Fmt ++ "~n", Args)
    end.

error(Fmt, Args) ->
    try lager:error(Fmt, Args)
    catch _:_ -> error_logger:error_msg(Fmt ++ "~n", Args)
    end.

warn(Fmt, Args) ->
    try lager:warning(Fmt, Args)
    catch _:_ -> error_logger:warning_msg(Fmt ++ "~n", Args)
    end.