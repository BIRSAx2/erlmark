%% @doc Fast, pure Erlang CommonMark Markdown to HTML converter, with the GFM
%% table, strikethrough and task-list extensions.
%%
%% ```
%% 1> erlmark:to_html(<<"# Hello *world*">>).
%% <<"<h1>Hello <em>world</em></h1>\n">>
%% '''
-module(erlmark).
-include("erlmark.hrl").

-export([to_html/1, to_html/2]).
-export_type([refs/0, option/0]).

-type refs() :: #{binary() => {binary(), binary() | none}}.

-type option() ::
    {spawn_above, non_neg_integer() | infinity}
    | {parallel, false | auto | pos_integer()}
    | {extensions, [autolink | tagfilter]}.
%% `{extensions, [autolink, tagfilter]}': opt-in GFM extended autolinks (bare `www.',
%% `http(s)://' and `ftp://' URLs, e-mail addresses) and the tagfilter (`<script>',
%% `<style>' and similar tags are escaped). Off by default; always sequential.
%% `{spawn_above, Bytes}': inputs larger than `Bytes' are converted in a short-lived
%% helper process with a pre-sized heap, which avoids most garbage collection.
%% `infinity' always converts in the caller. Default 256.
%% `{parallel, auto | N}': split large documents at top-level block boundaries and
%% convert the pieces on `N' schedulers. The output is identical to sequential
%% conversion. Documents under 16 KB are never split.

-define(DEFAULT_SPAWN_ABOVE, 256).
-define(MIN_PARALLEL_CHUNK, 2048).
-define(MIN_PARALLEL_DOC, 16384).
-define(MAX_MERGES, 1).
-define(HEAP_WORDS_PER_BYTE, 16).
-define(MAX_HEAP_WORDS, 4000000).

%% @doc Convert Markdown to an HTML binary. Raw HTML in the input is passed
%% through unchanged; sanitise the result if the input is untrusted.
-spec to_html(iodata()) -> binary().
to_html(Markdown) -> to_html(Markdown, []).

-spec to_html(iodata(), [option()]) -> binary().
to_html(Markdown, []) ->
    Bin = iolist_to_binary(Markdown),
    case byte_size(Bin) > ?DEFAULT_SPAWN_ABOVE of
        true -> convert_in_worker(Bin);
        false -> convert(Bin)
    end;
to_html(Markdown, Opts) ->
    case proplists:get_value(extensions, Opts, []) of
        [] -> to_html_plain(iolist_to_binary(Markdown), Opts);
        Exts -> convert_ext(iolist_to_binary(Markdown), Exts)
    end.

to_html_plain(Bin, Opts) ->
    Limit = proplists:get_value(spawn_above, Opts, ?DEFAULT_SPAWN_ABOVE),
    case parallelism(proplists:get_value(parallel, Opts, false)) of
        1 ->
            case Limit =/= infinity andalso byte_size(Bin) > Limit of
                true -> convert_in_worker(Bin);
                false -> convert(Bin)
            end;
        K ->
            %% Below the document gate, splitting costs more than it saves.
            Parts =
                case byte_size(Bin) >= ?MIN_PARALLEL_DOC of
                    true -> erlmark_split:split(Bin, K, ?MIN_PARALLEL_CHUNK);
                    false -> [Bin]
                end,
            case Parts of
                [One] -> convert_in_worker(One);
                Chunks -> convert_parallel(Chunks, Bin)
            end
    end.

parallelism(false) -> 1;
parallelism(auto) -> erlang:system_info(schedulers_online);
parallelism(N) when is_integer(N), N >= 1 -> N.

%% Convert independent chunks concurrently; concatenation is the document.
convert_parallel(Chunks, Whole) ->
    Self = self(),
    Workers = [spawn_chunk(Self, Chunk) || Chunk <- Chunks],
    Results = [await(W) || W <- Workers],
    %% Every unclean boundary (all chunks but the last) costs at least one merge;
    %% if there are too many, merging cannot win and we convert sequentially.
    Unclean = length([x || {_Html, unclosed} <- lists:droplast(Results)]),
    case Unclean > ?MAX_MERGES of
        true -> convert_in_worker(Whole);
        false -> combine(lists:zip(Chunks, Results), Whole, [], ?MAX_MERGES)
    end.

spawn_chunk(Self, Chunk) ->
    Ref = make_ref(),
    Heap = min(?MAX_HEAP_WORDS, byte_size(Chunk) * ?HEAP_WORDS_PER_BYTE),
    {Pid, Mon} = spawn_opt(
        fun() -> Self ! {Ref, safe(fun() -> convert_chunk(Chunk) end)} end,
        [monitor, {min_heap_size, Heap}]
    ),
    {Ref, Pid, Mon}.

%% Stitch chunk results together. Status is `ok', `unclosed' (the chunk ended
%% inside a fenced code / HTML block, so the cut was not a real block boundary)
%% or `refs' (link reference definitions are document-global).
combine([], _, Acc, _) ->
    iolist_to_binary(lists:reverse(Acc));
combine([{_, {Html, ok}} | T], Whole, Acc, M) ->
    combine(T, Whole, [Html | Acc], M);
combine([{_, {_, refs}} | _], Whole, _, _) ->
    convert_in_worker(Whole);
combine([{_, {Html, unclosed}}], _Whole, Acc, _) ->
    %% The last chunk legitimately runs to the end of the document.
    iolist_to_binary(lists:reverse([Html | Acc]));
combine([{_, {_, unclosed}}, _ | _], Whole, _, 0) ->
    %% Too many cuts fell inside blocks (e.g. a code-heavy document): stop
    %% merging and convert the whole document in one piece.
    convert_in_worker(Whole);
combine([{C1, {_, unclosed}}, {C2, _} | T], Whole, Acc, M) ->
    %% The cut fell inside a block: merge with the next chunk and redo just that.
    Merged = <<C1/binary, C2/binary>>,
    Result = await(spawn_chunk(self(), Merged)),
    combine([{Merged, Result} | T], Whole, Acc, M - 1).

await({Ref, Pid, Mon}) ->
    receive
        {Ref, {ok, Result}} ->
            erlang:demonitor(Mon, [flush]),
            Result;
        {Ref, {error, Class, Reason, Stack}} ->
            erlang:demonitor(Mon, [flush]),
            erlang:raise(Class, Reason, Stack);
        {'DOWN', Mon, process, Pid, Why} ->
            exit(Why)
    end.

safe(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason:Stack -> {error, Class, Reason, Stack}
    end.

convert(Bin) ->
    {Blocks, Refs} = erlmark_block:parse(Bin),
    erase(erlmark_unclosed),
    iolist_to_binary(blocks(Blocks, Refs)).

%% Convert one chunk of a split document and report whether it was independent.
convert_chunk(Bin) ->
    erase(erlmark_unclosed),
    {Blocks, Refs} = erlmark_block:parse(Bin),
    Unclosed = erase(erlmark_unclosed) =/= undefined,
    Status =
        if
            map_size(Refs) > 0 -> refs;
            Unclosed -> unclosed;
            true -> ok
        end,
    {iolist_to_binary(blocks(Blocks, Refs)), Status}.

convert_in_worker(Bin) -> run_in_worker(fun() -> convert(Bin) end, Bin).

%% Conversion with the opt-in GFM extensions (see erlmark_gfm).
convert_ext(Bin, Exts) ->
    run_in_worker(fun() -> convert_exts(Bin, Exts) end, Bin).

convert_exts(Bin, Exts) ->
    {Blocks0, Refs} = erlmark_block:parse(Bin),
    erase(erlmark_unclosed),
    Auto = lists:member(autolink, Exts),
    Blocks =
        case Auto of
            true -> map_src(fun erlmark_gfm:pre/1, Blocks0);
            false -> Blocks0
        end,
    Html0 = iolist_to_binary(blocks(Blocks, Refs)),
    Html1 =
        case Auto of
            true -> erlmark_gfm:post(Html0);
            false -> Html0
        end,
    case lists:member(tagfilter, Exts) of
        true -> erlmark_gfm:tagfilter(Html1);
        false -> Html1
    end.

%% Apply Fun to the inline source of every paragraph, heading and table cell.
map_src(Fun, Blocks) -> [map_src1(Fun, B) || B <- Blocks].

map_src1(Fun, {paragraph, Src}) ->
    {paragraph, Fun(Src)};
map_src1(Fun, {heading, L, Src}) ->
    {heading, L, Fun(Src)};
map_src1(Fun, {blockquote, Bs}) ->
    {blockquote, map_src(Fun, Bs)};
map_src1(Fun, {list, T, Tight, Items}) ->
    {list, T, Tight, [{item, Task, map_src(Fun, Bs)} || {item, Task, Bs} <- Items]};
map_src1(Fun, {table, Aligns, Head, Rows}) ->
    {table, Aligns, [Fun(C) || C <- Head], [[Fun(C) || C <- R] || R <- Rows]};
map_src1(_Fun, Other) ->
    Other.

run_in_worker(Job, Bin) ->
    Self = self(),
    Ref = make_ref(),
    Heap = min(?MAX_HEAP_WORDS, byte_size(Bin) * ?HEAP_WORDS_PER_BYTE),
    {Pid, Mon} = spawn_opt(
        fun() -> Self ! {Ref, safe(Job)} end,
        [monitor, {min_heap_size, Heap}]
    ),
    await({Ref, Pid, Mon}).

%%--------------------------------------------------------------------
%% Rendering
%%--------------------------------------------------------------------

blocks(Blocks, Refs) -> [block(B, Refs) || B <- Blocks].

block({paragraph, Src}, Refs) ->
    [<<"<p>">>, erlmark_inline:render(Src, Refs), <<"</p>\n">>];
block({heading, Level, Src}, Refs) ->
    {Open, Close} = heading_tags(Level),
    [Open, erlmark_inline:render(Src, Refs), Close];
block({code, <<>>, Content}, _Refs) ->
    [<<"<pre><code>">>, erlmark_util:esc(Content), <<"</code></pre>\n">>];
block({code, Info, Content}, _Refs) ->
    [
        <<"<pre><code class=\"language-">>,
        erlmark_util:esc(Info),
        <<"\">">>,
        erlmark_util:esc(Content),
        <<"</code></pre>\n">>
    ];
block({blockquote, Blocks}, Refs) ->
    case Blocks of
        [] -> <<"<blockquote>\n</blockquote>\n">>;
        _ -> [<<"<blockquote>\n">>, blocks(Blocks, Refs), <<"</blockquote>\n">>]
    end;
block(thematic, _Refs) ->
    <<"<hr />\n">>;
block({html, Raw}, _Refs) ->
    [Raw, $\n];
block({list, Type, Tight, Items}, Refs) ->
    {Open, Close} =
        case Type of
            bullet -> {<<"<ul>\n">>, <<"</ul>\n">>};
            {ordered, 1} -> {<<"<ol>\n">>, <<"</ol>\n">>};
            {ordered, N} -> {[<<"<ol start=\"">>, integer_to_binary(N), <<"\">\n">>], <<"</ol>\n">>}
        end,
    [Open, [item(I, Tight, Refs) || I <- Items], Close];
block({table, Aligns, Head, Rows}, Refs) ->
    Body =
        case Rows of
            [] -> [];
            _ -> [<<"<tbody>\n">>, [row(R, Aligns, <<"td">>, Refs) || R <- Rows], <<"</tbody>\n">>]
        end,
    [
        <<"<table>\n<thead>\n">>,
        row(Head, Aligns, <<"th">>, Refs),
        <<"</thead>\n">>,
        Body,
        <<"</table>\n">>
    ].

row(Cells, Aligns, Tag, Refs) ->
    [
        <<"<tr>\n">>,
        [cell(C, A, Tag, Refs) || {C, A} <- lists:zip(Cells, Aligns)],
        <<"</tr>\n">>
    ].

cell(Src, Align, Tag, Refs) ->
    [cell_open(Tag, Align), erlmark_inline:render(Src, Refs), cell_close(Tag)].

cell_open(<<"td">>, none) -> <<"<td>">>;
cell_open(<<"td">>, left) -> <<"<td align=\"left\">">>;
cell_open(<<"td">>, right) -> <<"<td align=\"right\">">>;
cell_open(<<"td">>, center) -> <<"<td align=\"center\">">>;
cell_open(<<"th">>, none) -> <<"<th>">>;
cell_open(<<"th">>, left) -> <<"<th align=\"left\">">>;
cell_open(<<"th">>, right) -> <<"<th align=\"right\">">>;
cell_open(<<"th">>, center) -> <<"<th align=\"center\">">>.

cell_close(<<"td">>) -> <<"</td>\n">>;
cell_close(<<"th">>) -> <<"</th>\n">>.

heading_tags(1) -> {<<"<h1>">>, <<"</h1>\n">>};
heading_tags(2) -> {<<"<h2>">>, <<"</h2>\n">>};
heading_tags(3) -> {<<"<h3>">>, <<"</h3>\n">>};
heading_tags(4) -> {<<"<h4>">>, <<"</h4>\n">>};
heading_tags(5) -> {<<"<h5>">>, <<"</h5>\n">>};
heading_tags(6) -> {<<"<h6>">>, <<"</h6>\n">>}.

item({item, Task, Blocks}, Tight, Refs) ->
    Box =
        case Task of
            none -> [];
            checked -> <<"<input type=\"checkbox\" checked=\"\" disabled=\"\" /> ">>;
            unchecked -> <<"<input type=\"checkbox\" disabled=\"\" /> ">>
        end,
    case Blocks of
        [] -> <<"<li></li>\n">>;
        _ -> [<<"<li>">>, item_children(Blocks, Tight, Refs, Box, start), <<"</li>\n">>]
    end.

item_children([], _Tight, _Refs, _Box, _Prev) ->
    [];
item_children([{paragraph, Src} | T], true, Refs, Box, _Prev) ->
    Sep =
        case T of
            [] -> [];
            _ -> $\n
        end,
    [Box, erlmark_inline:render(Src, Refs), Sep | item_children(T, true, Refs, [], para)];
item_children([{paragraph, Src} | T], false, Refs, Box, Prev) ->
    [
        nl(Prev),
        <<"<p>">>,
        Box,
        erlmark_inline:render(Src, Refs),
        <<"</p>\n">>
        | item_children(T, false, Refs, [], block)
    ];
item_children([B | T], Tight, Refs, Box, Prev) ->
    [Box, nl(Prev), block(B, Refs) | item_children(T, Tight, Refs, [], block)].

nl(start) -> $\n;
nl(_) -> [].
