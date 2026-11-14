%% @private
%% Turns the typed options of erlmark_gleam into the option list erlmark expects.
-module(erlmark_gleam_ffi).
-export([to_html/7]).

to_html(Markdown, Threshold, Parallel, Extensions, Breaks, CodeClassPrefix, Safe) ->
    Opts =
        [{spawn_above, threshold(Threshold)}, {parallel, parallel(Parallel)}] ++
            [{extensions, Extensions} || Extensions =/= []] ++
            [{breaks, true} || Breaks] ++
            [{safe, true} || Safe] ++
            case CodeClassPrefix of
                {some, Prefix} -> [{code_class_prefix, Prefix}];
                none -> []
            end,
    erlmark:to_html(Markdown, Opts).

threshold({bytes, N}) -> N;
threshold(never) -> infinity.

parallel(sequential) -> false;
parallel(auto) -> auto;
parallel({workers, N}) -> N.
