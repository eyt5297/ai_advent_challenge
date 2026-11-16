%% Канонический путь: развёрнутые `..`, `.` и символические ссылки.
%%
%% Отдельный FFI-модуль, потому что в simplifile нет ни того, ни другого,
%% а без этого проверка «путь внутри песочницы» обходится двумя способами:
%% через `..` и через символическую ссылку наружу.
%%
%% Порядок важен: ссылки разворачиваются посегментно, сверху вниз, и `..`
%% схлопывается уже после них. Иначе `link/..` увёл бы не туда, куда
%% показывает ссылка, а туда, где она лежит.
-module(server_path_ffi).
-export([canonical/1]).

canonical(Path) when is_binary(Path) ->
    Absolute = filename:absname(binary_to_list(Path)),
    [Root | Segments] = filename:split(Absolute),
    Resolved = walk(Root, Segments, 0),
    list_to_binary(Resolved).

%% Идём по сегментам, разворачивая ссылки и схлопывая `..` на ходу.
%% Depth страхует от циклических ссылок: a -> b -> a.
walk(Current, [], _Depth) ->
    Current;
walk(_Current, _Segments, Depth) when Depth > 32 ->
    "/";
walk(Current, ["." | Rest], Depth) ->
    walk(Current, Rest, Depth);
walk(Current, [".." | Rest], Depth) ->
    walk(filename:dirname(Current), Rest, Depth);
walk(Current, [Segment | Rest], Depth) ->
    Next = filename:join(Current, Segment),
    case file:read_link_all(Next) of
        {ok, Target} ->
            %% Относительная ссылка считается от каталога, где лежит.
            Absolute = filename:absname(Target, Current),
            [Root | Parts] = filename:split(Absolute),
            Expanded = walk(Root, Parts, Depth + 1),
            walk(Expanded, Rest, Depth + 1);
        {error, _} ->
            walk(Next, Rest, Depth)
    end.
