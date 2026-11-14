%% @private
%% Turns the typed options of erlmark_gleam into the option list erlmark expects.
-module(erlmark_gleam_ffi).
-export([to_html/4]).

to_html(Markdown, Threshold, Parallel, Extensions) ->
    Base = [{spawn_above, threshold(Threshold)}, {parallel, parallel(Parallel)}],
    Opts =
        case Extensions of
            [] -> Base;
            _ -> Base ++ [{extensions, Extensions}]
        end,
    erlmark:to_html(Markdown, Opts).

threshold({bytes, N}) -> N;
threshold(never) -> infinity.

parallel(sequential) -> false;
parallel(auto) -> auto;
parallel({workers, N}) -> N.
