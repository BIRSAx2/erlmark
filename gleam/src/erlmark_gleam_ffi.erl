%% @private
%% Turns the typed options of erlmark_gleam into the option list erlmark expects.
-module(erlmark_gleam_ffi).
-export([to_html/8]).

to_html(Markdown, Threshold, Parallel, Extensions, Breaks, CodeClassPrefix, Safe, FrontMatter) ->
    Opts =
        [{spawn_above, threshold(Threshold)}, {parallel, parallel(Parallel)}] ++
            [{extensions, Extensions} || Extensions =/= []] ++
            [{breaks, true} || Breaks] ++
            [{safe, true} || Safe] ++
            [{front_matter, true} || FrontMatter] ++
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
