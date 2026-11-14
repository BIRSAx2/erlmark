%% @doc Fast, pure Erlang Markdown to HTML converter.
%%
%% Implements CommonMark 0.31.2 plus the GFM tables, strikethrough and task-list
%% extensions. Extended autolinks and the tagfilter are opt-in.
%%
%% ```
%% 1> erlmark:to_html(<<"# Hello *world*">>).
%% <<"<h1>Hello <em>world</em></h1>\n">>
%% '''
%%
%% Raw HTML in the input is passed through unchanged, as CommonMark requires.
%% Sanitise the output if the input is untrusted.
-module(erlmark).
-include("erlmark.hrl").

-export([to_html/1, to_html/2]).
-export_type([refs/0, option/0, extension/0]).

-type refs() :: #{binary() => {binary(), binary() | none}}.

-type extension() :: autolink | tagfilter | alerts.
-type option() ::
    {spawn_above, non_neg_integer() | infinity}
    | {parallel, false | auto | pos_integer()}
    | {extensions, [extension()]}
    | {breaks, boolean()}
    | {safe, boolean()}
    | {front_matter, boolean()}
    | {heading_ids, true | {prefix, iodata()}}
    | {heading_anchors, boolean()}
    | {code_class_prefix, iodata()}.
%% Conversion options:
%% <dl>
%% <dt>`{spawn_above, Bytes | infinity}'</dt>
%% <dd>Inputs larger than `Bytes' are converted in a short-lived helper process with
%% a pre-sized heap, which avoids most garbage collection. `infinity' always converts
%% in the calling process. Default: 256.</dd>
%% <dt>`{parallel, false | auto | N}'</dt>
%% <dd>Split large documents at top-level block boundaries and convert the pieces on
%% `N' schedulers (`auto' is all online ones). The output is identical to sequential
%% conversion. Documents under 16 KB are never split. Default: `false'.</dd>
%% <dt>`{extensions, [autolink | tagfilter]}'</dt>
%% <dd>Opt-in GFM extensions. `autolink' turns bare `www.', `http(s)://' and `ftp://'
%% URLs and e-mail addresses into links. `tagfilter' escapes `&lt;script&gt;',
%% `&lt;style&gt;' and similar tags. `alerts' renders block quotes that start with
%% `[!NOTE]', `[!TIP]', `[!IMPORTANT]', `[!WARNING]' or `[!CAUTION]' as GitHub-style
%% alerts. Conversion with extensions is always sequential. Default: none.</dd>
%% <dt>`{heading_ids, true | {prefix, iodata()}}'</dt>
%% <dd>Give every heading an `id' made from its text, as GitHub does: lowercase, letters,
%% marks, numbers, `_' and `-' kept, spaces turned into hyphens. Repeated headings get
%% `-1', `-2' and so on. A prefix is added to the `id' attribute only. Conversion with
%% heading ids is always sequential. Default: off.</dd>
%% <dt>`{heading_anchors, boolean()}'</dt>
%% <dd>Also add a `&lt;a class="anchor"&gt;' link to each heading (implies `heading_ids').
%% Default: `false'.</dd>
%% <dt>`{front_matter, boolean()}'</dt>
%% <dd>Skip a leading front matter block: a first line of `---' or `+++', then any lines,
%% closed by a line holding the same delimiter (no other characters). The block is not
%% rendered. An empty block, or one without a closing line, is ordinary Markdown.
%% Default: `false'.</dd>
%% <dt>`{safe, boolean()}'</dt>
%% <dd>Safe output for untrusted input. Raw HTML blocks and inline raw HTML are replaced
%% by `&lt;!-- raw HTML omitted --&gt;', and link and image destinations that use the
%% `javascript:', `vbscript:', `file:' or `data:' schemes become empty (`data:' is kept
%% for PNG, GIF, JPEG and WebP images). Default: `false'.</dd>
%% <dt>`{breaks, boolean()}'</dt>
%% <dd>Render a line break inside a paragraph as `&lt;br /&gt;', as chat and comment
%% systems expect. Default: `false'.</dd>
%% <dt>`{code_class_prefix, iodata()}'</dt>
%% <dd>Prefix of the class on fenced code blocks that have an info string. Default:
%% `<<"language-">>'.</dd>
%% </dl>

-define(DEFAULT_SPAWN_ABOVE, 256).
-define(MIN_PARALLEL_CHUNK, 2048).
-define(MIN_PARALLEL_DOC, 16384).
-define(MAX_MERGES, 1).
-define(HEAP_WORDS_PER_BYTE, 16).
-define(MAX_HEAP_WORDS, 4000000).

%% @doc Convert Markdown to an HTML binary, with default options.
%% @equiv to_html(Markdown, [])
-spec to_html(iodata()) -> binary().
to_html(Markdown) -> to_html(Markdown, []).

%% @doc Convert Markdown to an HTML binary.
%% See {@type option()} for the available options. Errors raised while converting in a
%% helper process are re-raised in the caller.
%%
%% ```
%% 1> erlmark:to_html(<<"www.example.com">>, [{extensions, [autolink]}]).
%% <<"<p><a href=\"http://www.example.com\">www.example.com</a></p>\n">>
%% '''
-spec to_html(iodata(), [option()]) -> binary().
to_html(Markdown, []) ->
    Bin = iolist_to_binary(Markdown),
    case byte_size(Bin) > ?DEFAULT_SPAWN_ABOVE of
        true -> convert_in_worker(Bin);
        false -> convert(Bin)
    end;
to_html(Markdown, Opts) ->
    Bin = front_matter(proplists:get_value(front_matter, Opts, false), iolist_to_binary(Markdown)),
    Flags = render_flags(Opts),
    with_flags(Flags, fun() ->
        case proplists:get_value(extensions, Opts, []) of
            [] -> to_html_plain(Bin, Opts);
            Exts -> convert_ext(Bin, Exts)
        end
    end).

%% Drop a leading front matter block (see the `front_matter' option).
front_matter(true, <<16#EF, 16#BB, 16#BF, Rest/binary>>) -> front_matter(true, Rest);
front_matter(true, <<"---", _/binary>> = Bin) -> front_matter_block(Bin, <<"---">>);
front_matter(true, <<"+++", _/binary>> = Bin) -> front_matter_block(Bin, <<"+++">>);
front_matter(_, Bin) -> Bin.

front_matter_block(Bin, Delim) ->
    case binary:split(Bin, <<"\n">>) of
        [First, Rest] ->
            case delimiter_line(First, Delim) of
                true -> front_matter_end(Rest, Delim, Bin, 0);
                false -> Bin
            end;
        [_] ->
            Bin
    end.

front_matter_end(Rest, Delim, Orig, N) ->
    case binary:split(Rest, <<"\n">>) of
        [Line, After] ->
            case delimiter_line(Line, Delim) of
                %% an empty block is not front matter
                true when N =:= 0 -> Orig;
                true -> After;
                false -> front_matter_end(After, Delim, Orig, N + 1)
            end;
        [Last] ->
            case delimiter_line(Last, Delim) of
                true when N > 0 -> <<>>;
                _ -> Orig
            end
    end.

delimiter_line(Line, Delim) -> binary:replace(Line, <<"\r">>, <<>>) =:= Delim.

%% The options that change rendering, kept in the process dictionary for the duration
%% of one conversion and copied into worker processes. Read through erlmark_util:flag/1.
render_flags(Opts) ->
    Flags = lists:append([flag(K, V) || {K, V} <- Opts]),
    case {lists:keymember(heading_anchors, 1, Flags), lists:keymember(heading_ids, 1, Flags)} of
        {true, false} -> [{heading_ids, <<>>} | Flags];
        _ -> Flags
    end.

flag(breaks, true) -> [{breaks, true}];
flag(safe, true) -> [{safe, true}];
flag(heading_ids, true) -> [{heading_ids, <<>>}];
flag(heading_ids, {prefix, P}) -> [{heading_ids, iolist_to_binary(P)}];
flag(heading_anchors, true) -> [{heading_anchors, true}];
flag(code_class_prefix, P) -> [{code_class_prefix, iolist_to_binary(P)}];
flag(_, _) -> [].

with_flags([], Fun) ->
    Fun();
with_flags(Flags, Fun) ->
    Old = put(erlmark_flags, Flags),
    try
        Fun()
    after
        erase(erlmark_slugs),
        case Old of
            undefined -> erase(erlmark_flags);
            _ -> put(erlmark_flags, Old)
        end
    end.

restore_flags(undefined) ->
    ok;
restore_flags(Flags) ->
    put(erlmark_flags, Flags),
    ok.

to_html_plain(Bin, Opts) ->
    Limit = proplists:get_value(spawn_above, Opts, ?DEFAULT_SPAWN_ABOVE),
    Workers =
        case erlmark_util:flag(heading_ids) of
            %% heading ids are numbered over the whole document
            false -> parallelism(proplists:get_value(parallel, Opts, false));
            _ -> 1
        end,
    case Workers of
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
    Flags = get(erlmark_flags),
    {Pid, Mon} = spawn_opt(
        fun() ->
            restore_flags(Flags),
            Self ! {Ref, safe(fun() -> convert_chunk(Chunk) end)}
        end,
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
    {Blocks00, Refs} = erlmark_block:parse(Bin),
    erase(erlmark_unclosed),
    Blocks0 =
        case lists:member(alerts, Exts) of
            true -> erlmark_gfm:alerts(Blocks00);
            false -> Blocks00
        end,
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
map_src1(Fun, {alert, Type, Title, Bs}) ->
    {alert, Type, Title, map_src(Fun, Bs)};
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
    Flags = get(erlmark_flags),
    {Pid, Mon} = spawn_opt(
        fun() ->
            restore_flags(Flags),
            Self ! {Ref, safe(Job)}
        end,
        [monitor, {min_heap_size, Heap}]
    ),
    await({Ref, Pid, Mon}).

%%--------------------------------------------------------------------
%% Rendering
%%--------------------------------------------------------------------

blocks(Blocks, Refs) -> [block(B, Refs) || B <- Blocks].

code_class_prefix() ->
    case erlmark_util:flag(code_class_prefix) of
        false -> <<"language-">>;
        Prefix -> erlmark_util:esc(Prefix)
    end.

block({paragraph, Src}, Refs) ->
    [<<"<p>">>, erlmark_inline:render(Src, Refs), <<"</p>\n">>];
block({heading, Level, Src}, Refs) ->
    case get(erlmark_flags) of
        undefined ->
            {Open, Close} = heading_tags(Level),
            [Open, erlmark_inline:render(Src, Refs), Close];
        _ ->
            heading(Level, Src, Refs)
    end;
block({code, <<>>, Content}, _Refs) ->
    [<<"<pre><code>">>, erlmark_util:esc(Content), <<"</code></pre>\n">>];
block({code, Info, Content}, _Refs) ->
    case get(erlmark_flags) of
        undefined ->
            [
                <<"<pre><code class=\"language-">>,
                erlmark_util:esc(Info),
                <<"\">">>,
                erlmark_util:esc(Content),
                <<"</code></pre>\n">>
            ];
        _ ->
            [
                <<"<pre><code class=\"">>,
                code_class_prefix(),
                erlmark_util:esc(Info),
                <<"\">">>,
                erlmark_util:esc(Content),
                <<"</code></pre>\n">>
            ]
    end;
block({blockquote, Blocks}, Refs) ->
    case Blocks of
        [] -> <<"<blockquote>\n</blockquote>\n">>;
        _ -> [<<"<blockquote>\n">>, blocks(Blocks, Refs), <<"</blockquote>\n">>]
    end;
block({alert, Type, Title, Blocks}, Refs) ->
    Name = atom_to_binary(Type),
    Heading =
        case Title of
            <<>> -> alert_title(Type);
            _ -> erlmark_util:esc(Title)
        end,
    [
        <<"<div class=\"markdown-alert markdown-alert-">>,
        Name,
        <<"\">\n<p class=\"markdown-alert-title\">">>,
        Heading,
        <<"</p>\n">>,
        blocks(Blocks, Refs),
        <<"</div>\n">>
    ];
block(thematic, _Refs) ->
    <<"<hr />\n">>;
block({html, Raw}, _Refs) ->
    case erlmark_util:flag(safe) of
        true -> <<"<!-- raw HTML omitted -->\n">>;
        false -> [Raw, $\n]
    end;
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

%% A heading when conversion options are set: ids and anchors.
heading(Level, Src, Refs) ->
    Inner = erlmark_inline:render(Src, Refs),
    case erlmark_util:flag(heading_ids) of
        false ->
            {Open, Close} = heading_tags(Level),
            [Open, Inner, Close];
        Prefix ->
            Text = heading_text(Inner),
            Slug = unique_slug(erlmark_util:slug(Text)),
            L = integer_to_binary(Level),
            Anchor =
                case erlmark_util:flag(heading_anchors) of
                    true ->
                        [
                            <<"<a href=\"#">>,
                            erlmark_util:esc(Slug),
                            <<"\" aria-label=\"Link to heading '">>,
                            erlmark_util:esc(Text),
                            <<"'\" data-heading-content=\"">>,
                            erlmark_util:esc(Text),
                            <<"\" class=\"anchor\"></a>">>
                        ];
                    false ->
                        []
                end,
            [
                <<"<h">>,
                L,
                <<" id=\"">>,
                erlmark_util:esc(Prefix),
                erlmark_util:esc(Slug),
                <<"\">">>,
                Inner,
                Anchor,
                <<"</h">>,
                L,
                <<">\n">>
            ]
    end.

%% The plain text of rendered inline HTML.
heading_text(Inner) ->
    Plain = iolist_to_binary(erlmark_util:strip_tags(Inner)),
    unescape_text(Plain).

unescape_text(Bin) ->
    lists:foldl(
        fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
        Bin,
        [
            {<<"&lt;">>, <<"<">>},
            {<<"&gt;">>, <<">">>},
            {<<"&quot;">>, <<"\"">>},
            {<<"&amp;">>, <<"&">>}
        ]
    ).

%% Ids are unique over the document; a taken id gets the next free `-N' suffix.
unique_slug(Base) ->
    {Used, Next} =
        case get(erlmark_slugs) of
            undefined -> {#{}, #{}};
            State -> State
        end,
    case maps:is_key(Base, Used) of
        false ->
            put(erlmark_slugs, {Used#{Base => true}, Next}),
            Base;
        true ->
            free_slug(Base, maps:get(Base, Next, 1), Used, Next)
    end.

free_slug(Base, N, Used, Next) ->
    Candidate = <<Base/binary, $-, (integer_to_binary(N))/binary>>,
    case maps:is_key(Candidate, Used) of
        true ->
            free_slug(Base, N + 1, Used, Next);
        false ->
            put(erlmark_slugs, {Used#{Candidate => true}, Next#{Base => N + 1}}),
            Candidate
    end.

alert_title(note) -> <<"Note">>;
alert_title(tip) -> <<"Tip">>;
alert_title(important) -> <<"Important">>;
alert_title(warning) -> <<"Warning">>;
alert_title(caution) -> <<"Caution">>.

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
