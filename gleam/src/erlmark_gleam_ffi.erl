%% @private
%% Turns the typed options of erlmark_gleam into the option list erlmark expects. The
%% tuple below is the Gleam `Options` record, so its fields must stay in the order of the
%% type definition in erlmark_gleam.gleam.
-module(erlmark_gleam_ffi).
-export([convert/2]).

convert(
    Markdown,
    {options, Threshold, Parallel, Extensions, Breaks, CodeClassPrefix, Safe, FrontMatter, HeadingIds,
        HeadingAnchors}
) ->
    Opts =
        [{spawn_above, threshold(Threshold)}, {parallel, parallel(Parallel)}] ++
            [{extensions, Extensions} || Extensions =/= []] ++
            [{breaks, true} || Breaks] ++
            [{safe, true} || Safe] ++
            [{front_matter, true} || FrontMatter] ++
            heading_ids(HeadingIds) ++
            [{heading_anchors, true} || HeadingAnchors] ++
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

heading_ids(no_heading_ids) -> [];
heading_ids({heading_ids, <<>>}) -> [{heading_ids, true}];
heading_ids({heading_ids, Prefix}) -> [{heading_ids, {prefix, Prefix}}].
