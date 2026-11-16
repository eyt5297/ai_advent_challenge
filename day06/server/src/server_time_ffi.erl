%% Форматирование времени в ISO 8601.
%%
%% Отдельный FFI-модуль, потому что в stdlib Gleam нет работы с календарём,
%% а тянуть ради одной строки зависимость неразумно.
-module(server_time_ffi).
-export([format_iso/1]).

format_iso(UnixMs) ->
    Seconds = UnixMs div 1000,
    Millis = UnixMs rem 1000,
    {{Y, Mo, D}, {H, Mi, S}} =
        calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
                      [Y, Mo, D, H, Mi, S, Millis])).
