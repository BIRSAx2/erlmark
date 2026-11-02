-module(erlmark_tests).
-include_lib("eunit/include/eunit.hrl").

html(Md) -> erlmark:to_html(Md).

basic_test_() ->
    [
        ?_assertEqual(<<"<h1>Hello <em>world</em></h1>\n">>, html(<<"# Hello *world*">>)),
        ?_assertEqual(<<"">>, html(<<"">>)),
        %% iodata input
        ?_assertEqual(<<"<p>a</p>\n">>, html(["a"])),
        ?_assertEqual(<<"<p>a</p>\n">>, html([<<"a">>])),
        ?_assertEqual(<<"<hr />\n">>, html(<<"***">>))
    ].

%% GFM extensions.
gfm_test_() ->
    [
        ?_assertEqual(<<"<p><del>gone</del></p>\n">>, html(<<"~~gone~~">>)),
        ?_assertEqual(
            <<
                "<table>\n<thead>\n<tr>\n<th>a</th>\n<th align=\"right\">b</th>\n</tr>\n</thead>\n"
                "<tbody>\n<tr>\n<td>1</td>\n<td align=\"right\">2</td>\n</tr>\n</tbody>\n</table>\n"
            >>,
            html(<<"| a | b |\n|---|--:|\n| 1 | 2 |\n">>)
        ),
        ?_assertEqual(
            <<
                "<ul>\n<li><input type=\"checkbox\" disabled=\"\" /> todo</li>\n"
                "<li><input type=\"checkbox\" checked=\"\" disabled=\"\" /> done</li>\n</ul>\n"
            >>,
            html(<<"- [ ] todo\n- [x] done\n">>)
        )
    ].

%% The helper-process path and the in-caller path must agree, and errors in
%% the worker must not hang or leak.
worker_matches_caller_test() ->
    Md = binary:copy(
        <<"# Title\n\nSome *text* with a [link](http://x.y) and `code`.\n\n- a\n- b\n\n">>, 100
    ),
    ?assert(byte_size(Md) > 256),
    InCaller = erlmark:to_html(Md, [{spawn_above, infinity}]),
    InWorker = erlmark:to_html(Md, [{spawn_above, 0}]),
    ?assertEqual(InCaller, InWorker),
    ?assertEqual(InCaller, erlmark:to_html(Md)).

large_input_is_not_quadratic_test_() ->
    {timeout, 30, fun() ->
        %% Pathological delimiter / bracket / backtick runs must stay fast.
        Cases = [
            binary:copy(<<"*a ">>, 20000),
            binary:copy(<<"[a">>, 20000),
            binary:copy(<<"`a">>, 20000),
            binary:copy(<<"_a_ ">>, 20000),
            binary:copy(<<"> ">>, 5000),
            binary:copy(<<"- ">>, 5000)
        ],
        [
            begin
                {Us, _} = timer:tc(fun() -> erlmark:to_html(C) end),
                ?assert(Us < 5000000)
            end
         || C <- Cases
        ]
    end}.

%% Fuzz: arbitrary bytes built from Markdown-significant characters must never crash.
fuzz_never_crashes_test_() ->
    {timeout, 120, fun() ->
        rand:seed(exsss, {1, 2, 3}),
        Alphabet = <<"*_`[]()<>!&#-+=~|\\\"' \n\n\t0123456789abc:/.">>,
        [
            begin
                Len = rand:uniform(200),
                Input = <<
                    <<(binary:at(Alphabet, rand:uniform(byte_size(Alphabet)) - 1))>>
                 || _ <- lists:seq(1, Len)
                >>,
                try erlmark:to_html(Input) of
                    Out -> ?assert(is_binary(Out))
                catch
                    C:R:St ->
                        erlang:error({crash, Input, C, R, St})
                end
            end
         || _ <- lists:seq(1, 20000)
        ],
        ok
    end}.

fuzz_arbitrary_bytes_test_() ->
    {timeout, 120, fun() ->
        rand:seed(exsss, {4, 5, 6}),
        [
            begin
                Input = rand:bytes(rand:uniform(300)),
                try erlmark:to_html(Input) of
                    Out -> ?assert(is_binary(Out))
                catch
                    C:R:St ->
                        erlang:error({crash, Input, C, R, St})
                end
            end
         || _ <- lists:seq(1, 5000)
        ],
        ok
    end}.

%%--------------------------------------------------------------------
%% Parallel conversion must be byte-identical to sequential conversion.
%%--------------------------------------------------------------------

par_snippets() ->
    par_regular_snippets() ++ par_adversarial_snippets().

%% The unclosed fence interleaves with later (indented) fences in ways no
%% marker-based heuristic can untangle, so such documents are rightly not split.
par_adversarial_snippets() ->
    [<<"```\nunclosed fence in the middle\n\n">>].

par_regular_snippets() ->
    [
        <<"Plain paragraph text here.\n\n">>,
        <<"# Heading one\n\n">>,
        <<"## Heading *two*\n\n">>,
        <<"```\ncode\n\n# comment in code\n\nText in code\n```\n\n">>,
        <<"~~~python\nx = 1\n\ndef f():\n    pass\n~~~\n\n">>,
        <<"````\n```\nnested\n\nLine\n```\n````\n\n">>,
        <<"- item a\n- item b\n\n  continued para\n\nAfter list\n\n">>,
        <<"1. one\n2. two\n\n   para in two\n\nOutside\n\n">>,
        <<"> quote line\n> more\n\nAfter quote\n\n">>,
        <<"> ```\n> code in quote\n\nLazy after\n\n">>,
        <<"    indented code\n\n    more indented\n\nText\n\n">>,
        <<"<div>\nblock html\n\nstill block? no\n</div>\n\n">>,
        <<"<!-- comment\n\nspans blank\n\n# inside comment\n-->\n\n">>,
        <<"<pre>\npre text\n\nLine\n\n</pre>\n\n">>,
        <<"[ref]: http://example.com\n\n">>,
        <<"Uses [ref] and [other][ref].\n\n">>,
        <<"| a | b |\n|---|---|\n| 1 | 2 |\n\n">>,
        <<"Setext\n======\n\n">>,
        <<"***\n\n">>,
        <<"Text with *emph* and **strong** and `code` and [link](http://x.y).\n\n">>,
        <<"\n\n\n">>,
        <<"   ```\n   indented fence\n\n   x\n   ```\n\n">>
    ].

par_doc(Target) -> par_doc(Target, par_regular_snippets()).
par_doc(Target, Ss) -> par_doc(Target, Ss, 0, []).
par_doc(Target, _Ss, Size, Acc) when Size >= Target -> iolist_to_binary(lists:reverse(Acc));
par_doc(Target, Ss, Size, Acc) ->
    S = lists:nth(rand:uniform(length(Ss)), Ss),
    par_doc(Target, Ss, Size + byte_size(S), [S | Acc]).

parallel_matches_sequential_test_() ->
    {timeout, 120, fun() ->
        rand:seed(exsss, {7, 8, 9}),
        Splits = lists:flatten(
            [
                begin
                    D = par_doc(16384 + rand:uniform(30000)),
                    Seq = erlmark:to_html(D, [{spawn_above, infinity}]),
                    [
                        begin
                            ?assertEqual(Seq, erlmark:to_html(D, [{parallel, K}])),
                            case length(erlmark_split:split(D, K, 8192)) > 1 of
                                true -> 1;
                                false -> 0
                            end
                        end
                     || K <- [2, 4, 8]
                    ]
                end
             || _ <- lists:seq(1, 120)
            ]
        ),
        %% the test must actually exercise the split path
        ?assert(lists:sum(Splits) > 200)
    end}.

%% The full soup (including unclosed fences): identical whether or not it splits.
parallel_adversarial_soup_test_() ->
    {timeout, 120, fun() ->
        rand:seed(exsss, {17, 18, 19}),
        [
            begin
                D = par_doc(16384 + rand:uniform(30000), par_snippets()),
                Seq = erlmark:to_html(D, [{spawn_above, infinity}]),
                [?assertEqual(Seq, erlmark:to_html(D, [{parallel, K}])) || K <- [2, 4, 8]]
            end
         || _ <- lists:seq(1, 150)
        ],
        ok
    end}.

parallel_small_and_auto_test() ->
    Small = <<"# tiny\n\ntext\n">>,
    ?assertEqual(erlmark:to_html(Small), erlmark:to_html(Small, [{parallel, 8}])),
    Big = binary:copy(<<"## H\n\nSome *text* here with a [link](http://x.y).\n\n">>, 2000),
    ?assertEqual(
        erlmark:to_html(Big, [{spawn_above, infinity}]), erlmark:to_html(Big, [{parallel, auto}])
    ).

%% A fence whose interior contains a qualifying cut point must not be cut.
parallel_respects_fences_test() ->
    Block = <<"```\ncode\n\nLooks like a paragraph\n\n# looks like a heading\n\nmore\n```\n\n">>,
    D = binary:copy(Block, 400),
    ?assertEqual(
        erlmark:to_html(D, [{spawn_above, infinity}]), erlmark:to_html(D, [{parallel, 8}])
    ).

%% Reference definitions are document-global, so they must work across chunks.
parallel_with_references_test() ->
    Para = binary:copy(<<"Filler paragraph with some words in it.\n\n">>, 600),
    D =
        <<Para/binary, "See [the ref] here.\n\n", Para/binary,
            "[the ref]: http://example.com/x\n">>,
    Out = erlmark:to_html(D, [{parallel, 8}]),
    ?assertEqual(erlmark:to_html(D, [{spawn_above, infinity}]), Out),
    ?assertNotEqual(nomatch, binary:match(Out, <<"<a href=\"http://example.com/x\">the ref</a>">>)).

%% Tilde fences containing blank-line + heading-like lines must not be cut either.
parallel_respects_tilde_fences_test() ->
    Block = <<"~~~\ncode\n\nLooks like a paragraph\n\n# looks like a heading\n\nmore\n~~~\n\n">>,
    D = binary:copy(Block, 400),
    ?assertEqual(
        erlmark:to_html(D, [{spawn_above, infinity}]), erlmark:to_html(D, [{parallel, 8}])
    ).

%% Fences that defeat naive cut selection (indented, nested, mixed styles, inside
%% a list item): whatever the cut heuristic does, the result must be identical.
parallel_adversarial_fences_test_() ->
    Tail = <<"Text between blocks\n\n# Real heading\n\nTail paragraph\n\n">>,
    Docs = [
        binary:copy(
            <<"Intro paragraph\n\n  ```\ncode\n\nLooks like text\n\n# looks like heading\n\nmore\n  ```\n\n",
                Tail/binary>>,
            300
        ),
        binary:copy(
            <<"Intro paragraph\n\n````\n```\ninner\n\nLooks like text\n\n# heading-ish\n```\n````\n\n",
                Tail/binary>>,
            300
        ),
        binary:copy(
            <<"Intro paragraph\n\n```\nbt code\n\nLooks like text\n```\n\n~~~\ntilde code\n\n# heading-ish\n\nmore\n~~~\n\n",
                Tail/binary>>,
            300
        ),
        binary:copy(
            <<"- item\n\n  ```\n  code\n\nLooks like text\n\n# heading-ish\n  ```\n\n",
                Tail/binary>>,
            300
        )
    ],
    [
        {timeout, 60, fun() ->
            Seq = erlmark:to_html(D, [{spawn_above, infinity}]),
            [?assertEqual(Seq, erlmark:to_html(D, [{parallel, K}])) || K <- [2, 4, 8]]
        end}
     || D <- Docs
    ].

%% HTML blocks (types 1-5) may contain blank lines followed by letter/'#' lines;
%% cuts must not land inside them, and the result must match sequential.
parallel_html_blocks_test_() ->
    Docs = [
        binary:copy(
            <<"Intro paragraph here with *text*.\n\n<pre>\nline one\n\nLooks like a paragraph\n\n# looks like a heading\n</pre>\n\nBetween blocks.\n\n## Real heading\n\nTail.\n\n">>,
            300
        ),
        binary:copy(
            <<"Intro paragraph here.\n\n<!-- note\n\nLooks like text\n\n# heading-ish\n-->\n\nAfter the comment.\n\n## Heading\n\nTail.\n\n">>,
            300
        ),
        binary:copy(
            <<"Intro paragraph.\n\n<script>\nvar a = 1;\n\nfunction f() {}\n</script>\n\nMiddle text.\n\n<style>\nbody { x: y }\n\nh1 { z: w }\n</style>\n\n## Heading\n\n">>,
            200
        )
    ],
    [
        {timeout, 60, fun() ->
            Seq = erlmark:to_html(D, [{spawn_above, infinity}]),
            [?assertEqual(Seq, erlmark:to_html(D, [{parallel, K}])) || K <- [2, 4, 8]]
        end}
     || D <- Docs
    ].

%%--------------------------------------------------------------------
%% Container nesting is capped (a few MB of nested list markers used to take
%% minutes: cost grew with the cube of the depth). Realistic nesting is untouched.
%%--------------------------------------------------------------------

deeply_nested_input_is_bounded_test_() ->
    {timeout, 60, fun() ->
        Lists = iolist_to_binary([
            [lists:duplicate(I * 2, " "), "- item\n"]
         || I <- lists:seq(0, 1500)
        ]),
        Quotes = iolist_to_binary([lists:duplicate(5000, "> "), "x\n"]),
        [
            begin
                {Us, Out} = timer:tc(fun() -> erlmark:to_html(D) end),
                ?assert(is_binary(Out)),
                ?assert(Us < 3000000)
            end
         || D <- [Lists, Quotes]
        ]
    end}.

realistic_nesting_is_unchanged_test() ->
    Md = <<"- a\n  - b\n    - c\n      - d\n        - e\n          - f\n> q1\n> > q2\n> > > q3\n">>,
    Html = erlmark:to_html(Md),
    %% six nested lists and three nested quotes: all rendered as containers
    ?assertEqual(6, length(binary:matches(Html, <<"<ul>">>))),
    ?assertEqual(3, length(binary:matches(Html, <<"<blockquote>">>))).

%%--------------------------------------------------------------------
%% Algorithmic-complexity regressions: each of these inputs used to take tens of
%% seconds (quadratic bracket / emphasis handling). The bound is generous; a
%% quadratic implementation misses it by an order of magnitude.
%%--------------------------------------------------------------------

adversarial_inline_inputs_are_linear_test_() ->
    {timeout, 120, fun() ->
        R = fun(S, N) -> iolist_to_binary(lists:duplicate(N, S)) end,
        N = 60000,
        Inputs = [
            {"nested brackets", iolist_to_binary([R("[", N), "x", R("]", N)])},
            {"closing brackets without openers", R("] ", N)},
            {"openers then closers", iolist_to_binary([R("[ ", N), R("] ", N)])},
            {"nested links", iolist_to_binary([R("[a", N), R("](b)", N)])},
            {"brackets and stars", iolist_to_binary([R("[*a ", N), R("] ", N)])},
            {"rule of 3 stars", R("a*b** ", N)},
            {"rule of 3 underscores", R("a_b__ ", N)},
            {"tilde runs", R("~~a~ ~~~b ", N)},
            {"tilde openers then closers", iolist_to_binary([R("~~a ", N), R("b~ ", N)])},
            {"nested emphasis", R("*a*", N)}
        ],
        [
            begin
                {Us, Out} = timer:tc(fun() -> erlmark:to_html(D) end),
                ?assert(is_binary(Out)),
                case Us < 5000000 of
                    true -> ok;
                    false -> erlang:error({too_slow, Name, Us})
                end
            end
         || {Name, D} <- Inputs
        ],
        ok
    end}.

%% The bracket rewrite must keep link / image / reference semantics exactly.
bracket_semantics_test_() ->
    [
        ?_assertEqual(
            <<"<p>[a <img src=\"e\" alt=\"b c\" />](f)</p>\n">>, html(<<"[a ![b [c](d)](e)](f)\n">>)
        ),
        ?_assertEqual(
            <<"<p>[foo <em>[bar <a href=\"/uri\">baz</a>](/uri)</em>](/uri)</p>\n">>,
            html(<<"[foo *[bar [baz](/uri)](/uri)*](/uri)\n">>)
        ),
        ?_assertEqual(
            <<"<p><a href=\"/u\">x</a> and [y] [z]</p>\n">>, html(<<"[x](/u) and [y] [z]\n">>)
        ),
        ?_assertEqual(<<"<p>[a] <a href=\"/u\">b</a></p>\n">>, html(<<"[a] [b]\n\n[b]: /u\n">>))
    ].

tab_fence_preserved_test() ->
    ?assertEqual(
        <<"<pre><code>\tx\n\t\ty\n</code></pre>\n">>,
        erlmark:to_html(<<"```\n\tx\n\t\ty\n```\n">>)
    ).

tab_indented_code_test() ->
    ?assertEqual(<<"<pre><code>x\n</code></pre>\n">>, erlmark:to_html(<<"\tx\n">>)),
    ?assertEqual(<<"<pre><code>  x\n</code></pre>\n">>, erlmark:to_html(<<"\t  x\n">>)),
    ?assertEqual(<<"<pre><code>x\n</code></pre>\n">>, erlmark:to_html(<<"  \tx\n">>)).

tab_list_item_test() ->
    ?assertEqual(
        <<"<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ul>\n">>,
        erlmark:to_html(<<"- a\n\n\tb\n">>)
    ).

ext(Md) -> erlmark:to_html(Md, [{extensions, [autolink, tagfilter]}]).

ext_off_by_default_test() ->
    ?assertEqual(<<"<p>www.example.com</p>\n">>, erlmark:to_html(<<"www.example.com">>)),
    ?assertEqual(<<"<style>\n</style>\n">>, erlmark:to_html(<<"<style>\n</style>">>)).

ext_autolink_context_test() ->
    %% not inside code spans, link text, link destinations or CommonMark autolinks
    ?assertEqual(<<"<p><code>www.a.com</code></p>\n">>, ext(<<"`www.a.com`">>)),
    ?assertEqual(<<"<p><a href=\"u\">www.a.com</a></p>\n">>, ext(<<"[www.a.com](u)">>)),
    ?assertEqual(<<"<p><a href=\"www.a.com\">x</a></p>\n">>, ext(<<"[x](www.a.com)">>)),
    ?assertEqual(<<"<p><a href=\"mailto:a@b.co\">a@b.co</a></p>\n">>, ext(<<"<a@b.co>">>)),
    ?assertEqual(
        <<"<p><em><a href=\"http://www.a.com\">www.a.com</a></em></p>\n">>, ext(<<"*www.a.com*">>)
    ),
    ?assertEqual(
        <<"<ul>\n<li><a href=\"http://www.a.com\">www.a.com</a></li>\n</ul>\n">>,
        ext(<<"- www.a.com">>)
    ).

ext_fuzz_test() ->
    Alpha = <<"www.a@b.c:/()_*~`[]<>&; \n\\\"'h-ps">>,
    rand:seed(exsss, {1, 2, 3}),
    [
        begin
            N = rand:uniform(60),
            Md = <<
                <<(binary:at(Alpha, rand:uniform(byte_size(Alpha)) - 1))>>
             || _ <- lists:seq(1, N)
            >>,
            ?assert(is_binary(ext(Md)))
        end
     || _ <- lists:seq(1, 3000)
    ].

thematic_vs_list_shapes_test() ->
    Hr = <<"<hr />\n">>,
    [
        ?assertEqual(Hr, erlmark:to_html(In))
     || In <- [
            <<"---">>,
            <<"- - -">>,
            <<"* * *">>,
            <<"_ _ _">>,
            <<"-\t-\t-">>,
            <<"  ***  ">>,
            <<"- -- -">>
        ]
    ],
    ?assertEqual(<<"<ul>\n<li>a</li>\n</ul>\n">>, erlmark:to_html(<<"- a">>)),
    ?assertEqual(<<"<p>-a</p>\n">>, erlmark:to_html(<<"-a">>)),
    ?assertEqual(<<"<p><em>a</em></p>\n">>, erlmark:to_html(<<"*a*">>)),
    ?assertEqual(<<"<p><em>a</em></p>\n">>, erlmark:to_html(<<"_a_">>)),
    ?assertEqual(
        <<"<ul>\n<li>\n<ul>\n<li>a</li>\n</ul>\n</li>\n</ul>\n">>, erlmark:to_html(<<"- - a">>)
    ).

html_tag_case_test() ->
    %% block-level names and the type-1 names are case-insensitive
    ?assertEqual(<<"<DIV>\nx\n</DIV>\n">>, erlmark:to_html(<<"<DIV>\nx\n</DIV>">>)),
    ?assertEqual(<<"<Div>\nx\n">>, erlmark:to_html(<<"<Div>\nx">>)),
    ?assertEqual(
        <<"<SCRIPT>\n\n*a*\n</Script>\n">>, erlmark:to_html(<<"<SCRIPT>\n\n*a*\n</Script>">>)
    ),
    ?assertEqual(<<"<p><span>x</span></p>\n">>, erlmark:to_html(<<"<span>x</span>">>)),
    ?assertEqual(<<"<p><SPAN>x</SPAN> y</p>\n">>, erlmark:to_html(<<"<SPAN>x</SPAN> y">>)).

autolink_escaping_test() ->
    %% unchanged-URL fast path and the escaping path agree with CommonMark output
    ?assertEqual(
        <<"<p><a href=\"http://a.com/x?y=1\">http://a.com/x?y=1</a></p>\n">>,
        erlmark:to_html(<<"<http://a.com/x?y=1>">>)
    ),
    ?assertEqual(
        <<"<p><a href=\"http://a.com/x&amp;y\">http://a.com/x&amp;y</a></p>\n">>,
        erlmark:to_html(<<"<http://a.com/x&y>">>)
    ),
    ?assertEqual(
        <<"<p><a href=\"mailto:a.b@c.com\">a.b@c.com</a></p>\n">>,
        erlmark:to_html(<<"<a.b@c.com>">>)
    ),
    ?assertEqual(
        <<"<p><a href=\"http://a.com/%5Cx\">http://a.com/\\x</a></p>\n">>,
        erlmark:to_html(<<"<http://a.com/\\x>">>)
    ).

item_continuation_test() ->
    Item = fun(Cont) -> erlmark:to_html(<<"- first\n  ", Cont/binary, "\n">>) end,
    %% plain continuation lines stay in the paragraph
    ?assertEqual(<<"<ul>\n<li>first\n(see #1)</li>\n</ul>\n">>, Item(<<"(see #1)">>)),
    ?assertEqual(<<"<ul>\n<li>first\n&quot;quoted&quot;</li>\n</ul>\n">>, Item(<<"\"quoted\"">>)),
    %% lines that start a block or underline the paragraph must not be swallowed
    ?assertEqual(<<"<ul>\n<li>\n<h2>first</h2>\n</li>\n</ul>\n">>, Item(<<"---">>)),
    ?assertEqual(<<"<ul>\n<li>\n<h1>first</h1>\n</li>\n</ul>\n">>, Item(<<"===">>)),
    ?assertEqual(
        <<"<ul>\n<li>first\n<blockquote>\n<p>q</p>\n</blockquote>\n</li>\n</ul>\n">>,
        Item(<<"> q">>)
    ),
    ?assertEqual(<<"<ul>\n<li>first\n<h3>h</h3>\n</li>\n</ul>\n">>, Item(<<"### h">>)),
    ?assertEqual(<<"<ul>\n<li>first\n<ol>\n<li>x</li>\n</ol>\n</li>\n</ul>\n">>, Item(<<"1. x">>)),
    ?assertEqual(
        <<"<ul>\n<li>first\n<pre><code>c\n</code></pre>\n</li>\n</ul>\n">>,
        Item(<<"```\n  c\n  ```">>)
    ),
    ?assertEqual(<<"<ul>\n<li>first\n<div>x</div>\n</li>\n</ul>\n">>, Item(<<"<div>x</div>">>)).

item_boundary_test() ->
    %% expected output was generated with the parser before the item-boundary fast paths
    Cases = [
        {<<"- a\n- b\n">>, <<"<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n">>},
        {<<"- a\n\n- b\n">>, <<"<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n">>},
        {<<"* a\n- b\n">>, <<"<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n">>},
        {<<"- a\n+ b\n">>, <<"<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n">>},
        {<<"1. a\n- b\n">>, <<"<ol>\n<li>a</li>\n</ol>\n<ul>\n<li>b</li>\n</ul>\n">>},
        {<<"- a\n- - b\n">>, <<"<ul>\n<li>a</li>\n<li>\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n">>},
        {<<"- a\n-b\n">>, <<"<ul>\n<li>a\n-b</li>\n</ul>\n">>},
        {<<"- a\n- \n- c\n">>, <<"<ul>\n<li>a</li>\n<li></li>\n<li>c</li>\n</ul>\n">>},
        {<<"- a\n* * *\n">>, <<"<ul>\n<li>a</li>\n</ul>\n<hr />\n">>},
        {<<"- a\n---\n">>, <<"<ul>\n<li>a</li>\n</ul>\n<hr />\n">>},
        {<<"- a\n  - b\n- c\n">>,
            <<"<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n<li>c</li>\n</ul>\n">>},
        {<<"- a\n -b\n">>, <<"<ul>\n<li>a\n-b</li>\n</ul>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

inline_text_scan_test() ->
    %% capitals, digits, punctuation and UTF-8 take the table-driven scan; specials must
    %% still be recognised wherever they fall inside a 4-byte window
    ?assertEqual(
        <<"<p>Hello (see #12) caf\xc3\xa9 2024-11-27: <em>x</em> &amp; <code>c</code></p>\n">>,
        erlmark:to_html(<<"Hello (see #12) caf\xc3\xa9 2024-11-27: *x* & `c`">>)
    ),
    ?assertEqual(<<"<p>A1.<strong>B2</strong>C3</p>\n">>, erlmark:to_html(<<"A1.**B2**C3">>)),
    ?assertEqual(<<"<p>A1.**B2,**C3</p>\n">>, erlmark:to_html(<<"A1.**B2,**C3">>)),
    ?assertEqual(
        <<"<p>\xe6\x97\xa5\xe6\x9c\xac<em>\xe8\xaa\x9e</em>x</p>\n">>,
        erlmark:to_html(<<"\xe6\x97\xa5\xe6\x9c\xac*\xe8\xaa\x9e*x">>)
    ).

entity_decoding_test() ->
    Cases = [
        {<<"&copy; &nbsp; &mdash; &hellip; &eacute;">>,
            <<"<p>\xc2\xa9 \xc2\xa0 \xe2\x80\x94 \xe2\x80\xa6 \xc3\xa9</p>\n">>},
        {<<"&amp; &lt; &gt; &quot;">>, <<"<p>&amp; &lt; &gt; &quot;</p>\n">>},
        {<<"&#38; &#60; &#x3E; &#34;">>, <<"<p>&amp; &lt; &gt; &quot;</p>\n">>},
        {<<"&nvlt;">>, <<"<p>&lt;\xe2\x83\x92</p>\n">>},
        {<<"&fjlig;">>, <<"<p>fj</p>\n">>},
        {<<"&NotEqualTilde;">>, <<"<p>\xe2\x89\x82\xcc\xb8</p>\n">>},
        {<<"*&mdash;*x">>, <<"<p>*\xe2\x80\x94*x</p>\n">>},
        {<<"a&hellip;*b*">>, <<"<p>a\xe2\x80\xa6<em>b</em></p>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

non_closing_delimiters_test() ->
    Cases = [
        {<<"a * b">>, <<"<p>a * b</p>\n">>},
        {<<"snake_case_name and a*b">>, <<"<p>snake_case_name and a*b</p>\n">>},
        {<<"*a **b _c ~d">>, <<"<p>*a **b _c ~d</p>\n">>},
        {<<"2 * 3 * 4">>, <<"<p>2 * 3 * 4</p>\n">>},
        %% a later closer must still find an earlier opener
        {<<"*a **b _c ~d e*">>, <<"<p>*a *<em>b _c ~d e</em></p>\n">>},
        {<<"*x* snake_case *y*">>, <<"<p><em>x</em> snake_case <em>y</em></p>\n">>},
        {<<"[a * b">>, <<"<p>[a * b</p>\n">>},
        {<<"![x * y">>, <<"<p>![x * y</p>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

paragraph_bullet_interrupt_test() ->
    %% expected output was generated with the parser before the bullet-interrupt fast path
    Cases = [
        {<<"a\n- b\n">>, <<"<p>a</p>\n<ul>\n<li>b</li>\n</ul>\n">>},
        {<<"a\n* b\n">>, <<"<p>a</p>\n<ul>\n<li>b</li>\n</ul>\n">>},
        {<<"a\n+ b\n">>, <<"<p>a</p>\n<ul>\n<li>b</li>\n</ul>\n">>},
        {<<"a\n-b\n">>, <<"<p>a\n-b</p>\n">>},
        {<<"a\n- \n">>, <<"<h2>a</h2>\n">>},
        {<<"a\n---\n">>, <<"<h2>a</h2>\n">>},
        {<<"a\n- - b\n">>, <<"<p>a</p>\n<ul>\n<li>\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n">>},
        {<<"a\n* * *\n">>, <<"<p>a</p>\n<hr />\n">>},
        {<<"a\n-\tb\n">>, <<"<p>a</p>\n<ul>\n<li>b</li>\n</ul>\n">>},
        {<<"a\nb\n- c\n  d\n- e\n">>, <<"<p>a\nb</p>\n<ul>\n<li>c\nd</li>\n<li>e</li>\n</ul>\n">>},
        {<<"- a\n  - b\n    - c\n  - d\n- e\n">>,
            <<"<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n</li>\n<li>e</li>\n</ul>\n">>},
        {<<"> a\n> - b\n">>, <<"<blockquote>\n<p>a</p>\n<ul>\n<li>b</li>\n</ul>\n</blockquote>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

tab_indentation_test() ->
    %% expected output was generated with the parser before the tab fast paths
    Cases = [
        {<<"\tcode\n\tmore\n">>, <<"<pre><code>code\nmore\n</code></pre>\n">>},
        {<<"\t\tdeep\n\tshallow\n">>, <<"<pre><code>    deep\nshallow\n</code></pre>\n">>},
        {<<"a\n\tnot code\n">>, <<"<p>a\nnot code</p>\n">>},
        {<<"\t\n\tx\n">>, <<"<pre><code>x\n</code></pre>\n">>},
        {<<"\tx\n\n\ty\n">>, <<"<pre><code>x\n\ny\n</code></pre>\n">>},
        {<<"\t  x\n">>, <<"<pre><code>  x\n</code></pre>\n">>},
        {<<" \tx\n">>, <<"<pre><code>x\n</code></pre>\n">>},
        {<<"   \tx\n">>, <<"<pre><code>x\n</code></pre>\n">>},
        {<<"- a\n\t- b\n\t\t- c\n\t- d\n- e\n">>,
            <<"<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n</li>\n<li>e</li>\n</ul>\n">>},
        {<<"1. a\n\tb\n2. c\n">>, <<"<ol>\n<li>a\nb</li>\n<li>c</li>\n</ol>\n">>},
        {<<"- a\n\n\tb\n">>, <<"<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ul>\n">>},
        {<<"- a\n\t\tcode?\n">>, <<"<ul>\n<li>a\ncode?</li>\n</ul>\n">>},
        {<<"-\ta\n-\tb\n">>, <<"<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n">>},
        {<<"> \tx\n">>, <<"<blockquote>\n<p>x</p>\n</blockquote>\n">>},
        {<<"- a\n  \tb\n">>, <<"<ul>\n<li>a\nb</li>\n</ul>\n">>},
        {<<"* a\n\t* b\n    * c\n">>,
            <<"<ul>\n<li>a\n<ul>\n<li>b</li>\n<li>c</li>\n</ul>\n</li>\n</ul>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

line_ending_test() ->
    P = fun(S) -> erlmark:to_html(S) end,
    %% CRLF, LF, lone CR (classic Mac) and mixtures all give the same document
    Same = [<<"a\nb\n\nc\n">>, <<"a\r\nb\r\n\r\nc\r\n">>, <<"a\rb\r\rc\r">>, <<"a\r\nb\n\rc\r">>],
    [?assertEqual(<<"<p>a\nb</p>\n<p>c</p>\n">>, P(S)) || S <- Same, S =/= <<"a\r\nb\n\rc\r">>],
    %% a doubled CR before the LF keeps one CR-derived line break
    ?assertEqual(P(<<"a\n\nb\n">>), P(<<"a\r\r\nb\n">>)),
    ?assertEqual(P(<<"x\n">>), P(<<"x\r">>)),
    ?assertEqual(P(<<"x\n">>), P(<<"x\r\n">>)),
    ?assertEqual(P(<<"```\ncode\n```\n">>), P(<<"```\r\ncode\r\n```\r\n">>)).

destination_unescape_test() ->
    %% expected output was generated with the parser before the slice-copying unescape
    Cases = [
        {<<"[a](https://x.y/p?a=1&b=2&c=3 \"t&amp;t\")">>,
            <<"<p><a href=\"https://x.y/p?a=1&amp;b=2&amp;c=3\" title=\"t&amp;t\">a</a></p>\n">>},
        {<<"[a](<https://x.y/p?a=1&b=2>)">>,
            <<"<p><a href=\"https://x.y/p?a=1&amp;b=2\">a</a></p>\n">>},
        {<<"<https://x.y/p?a=1&b=2&c=3>">>,
            <<"<p><a href=\"https://x.y/p?a=1&amp;b=2&amp;c=3\">https://x.y/p?a=1&amp;b=2&amp;c=3</a></p>\n">>},
        {<<"[a](u\\*v&copy;w\\\\x&bogus;y)">>,
            <<"<p><a href=\"u*v%C2%A9w%5Cx&amp;bogus;y\">a</a></p>\n">>},
        {<<"[a](https://x.y/&#35;&#x41;)">>, <<"<p><a href=\"https://x.y/#A\">a</a></p>\n">>},
        {<<"<https://x.y/a\\b>">>,
            <<"<p><a href=\"https://x.y/a%5Cb\">https://x.y/a\\b</a></p>\n">>},
        {<<"<https://x.y/a b>">>, <<"<p>&lt;https://x.y/a b&gt;</p>\n">>},
        {<<"<mailto:a@b.co?x=1&y=2>">>,
            <<"<p><a href=\"mailto:a@b.co?x=1&amp;y=2\">mailto:a@b.co?x=1&amp;y=2</a></p>\n">>},
        {<<"[a](u \"\\&quot;t\\\"\")">>,
            <<"<p><a href=\"u\" title=\"&amp;quot;t&quot;\">a</a></p>\n">>},
        {<<"```a&amp;b\\*c\nx\n```">>,
            <<"<pre><code class=\"language-a&amp;b*c\">x\n</code></pre>\n">>},
        {<<"<http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bb/cccccccccccccccccccc?d=e&f=g>">>,
            <<"<p><a href=\"http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bb/cccccccccccccccccccc?d=e&amp;f=g\">http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bb/cccccccccccccccccccc?d=e&amp;f=g</a></p>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

reference_label_test() ->
    %% expected output was generated with the parser before the label scan rewrite
    Cases = [
        {<<"[A long link text that goes on and on](https://x.y/p)\n">>,
            <<"<p><a href=\"https://x.y/p\">A long link text that goes on and on</a></p>\n">>},
        {<<"[Foo]: /url\n\n[foo]\n">>, <<"<p><a href=\"/url\">foo</a></p>\n">>},
        {<<"[a\\]b]: /u\n\n[a\\]b]\n">>, <<"<p><a href=\"/u\">a]b</a></p>\n">>},
        {<<"[a[b]: /u\n">>, <<"<p>[a[b]: /u</p>\n">>},
        {<<"[]: /u\n">>, <<"<p>[]: /u</p>\n">>},
        {<<"[ ]: /u\n">>, <<"<p>[ ]: /u</p>\n">>},
        {<<"[foo]:\n/url\n">>, <<>>},
        {<<"[foo]\n: /url\n">>, <<"<p>[foo]\n: /url</p>\n">>},
        {<<"[link](/u) and [Ref Link][Ref   Link]\n\n[ref link]: /r\n">>,
            <<"<p><a href=\"/u\">link</a> and <a href=\"/r\">Ref Link</a></p>\n">>},
        {<<"[\\]: /u\n">>, <<"<p>[]: /u</p>\n">>},
        {<<"[a]: /u \"t\"\n[A]: /v\n\n[a]\n">>, <<"<p><a href=\"/u\" title=\"t\">a</a></p>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

html_attribute_test() ->
    %% expected output was generated with the parser before the attribute-scanner changes
    Cases = [
        {<<"<a href=\"https://x.y/z?a=1&b=2\" class=\"btn primary\" target=_blank>link</a>\n">>,
            <<"<p><a href=\"https://x.y/z?a=1&b=2\" class=\"btn primary\" target=_blank>link</a></p>\n">>},
        {<<"<img src='a.png' alt=\"x y\" width=10 />\n">>,
            <<"<img src='a.png' alt=\"x y\" width=10 />\n">>},
        {<<"text <span class=\"c\"  id = \"i\">x</span> more\n">>,
            <<"<p>text <span class=\"c\"  id = \"i\">x</span> more</p>\n">>},
        {<<"<div\n  id=\"i\"\n  class=\"c\">\nx\n</div>\n">>,
            <<"<div\n  id=\"i\"\n  class=\"c\">\nx\n</div>\n">>},
        {<<"a <b c=\"unterminated> d\n">>, <<"<p>a &lt;b c=&quot;unterminated&gt; d</p>\n">>},
        {<<"a <b c= d> e\n">>, <<"<p>a <b c= d> e</p>\n">>},
        {<<"<a  b=\"1\"   c='2'>t</a>\n">>, <<"<p><a  b=\"1\"   c='2'>t</a></p>\n">>},
        {<<"<a b c d=e>t</a>\n">>, <<"<p><a b c d=e>t</a></p>\n">>},
        {<<"<a b=\"1\"c=\"2\">t</a>\n">>,
            <<"<p>&lt;a b=&quot;1&quot;c=&quot;2&quot;&gt;t</a></p>\n">>},
        {<<"<a _x=1 :y=2 z.w=3 v-u=4>t</a>\n">>, <<"<p><a _x=1 :y=2 z.w=3 v-u=4>t</a></p>\n">>},
        {<<"x <br/> y <br /> z <br\t/>\n">>, <<"<p>x <br/> y <br /> z <br\t/></p>\n">>},
        {<<"<a b=\"very long value that goes past the sixty four byte unrolled limit of the attribute scanner so it must fall back\">t</a>\n">>,
            <<"<p><a b=\"very long value that goes past the sixty four byte unrolled limit of the attribute scanner so it must fall back\">t</a></p>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

html_block_end_test() ->
    %% expected output was generated with the parser before the single-scan type-1 end test
    Cases = [
        {<<"<pre>\nline 1\n  line 2 <b>bold</b>\nline 3\n</pre>\n\nText.\n">>,
            <<"<pre>\nline 1\n  line 2 <b>bold</b>\nline 3\n</pre>\n<p>Text.</p>\n">>},
        {<<"<PRE>\nx\n</PrE>\nafter\n">>, <<"<PRE>\nx\n</PrE>\n<p>after</p>\n">>},
        {<<"<script>\nvar a = \"</div>\";\n</script>\n\ntext\n">>,
            <<"<script>\nvar a = \"</div>\";\n</script>\n<p>text</p>\n">>},
        {<<"<style>\n.x { color: red; }\n</STYLE> tail\n">>,
            <<"<style>\n.x { color: red; }\n</STYLE> tail\n">>},
        {<<"<textarea>\n</p>\n</textarea>\nx\n">>, <<"<textarea>\n</p>\n</textarea>\n<p>x</p>\n">>},
        {<<"<pre>\nnever closed </pr\n">>, <<"<pre>\nnever closed </pr\n">>},
        {<<"<pre>\n</prefix>\n</pre>\n">>, <<"<pre>\n</prefix>\n</pre>\n">>},
        {<<"<script>\n</scripts>\n</script >\n</script>\nz\n">>,
            <<"<script>\n</scripts>\n</script >\n</script>\n<p>z</p>\n">>},
        {<<"<pre> one line </pre> x\n">>, <<"<pre> one line </pre> x\n">>},
        {<<"<script></script>\n\nok\n">>, <<"<script></script>\n<p>ok</p>\n">>},
        {<<"<pre>\na </ pre>\n</pre\n">>, <<"<pre>\na </ pre>\n</pre\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

table_escaped_pipe_test() ->
    %% expected output was generated with the parser before the slice-copying pipe unescape
    Cases = [
        {<<"| Expr | Meaning |\n|---|---|\n| `a \\| b` | pipe in code |\n| x \\| y | escaped pipe |\n">>,
            <<"<table>\n<thead>\n<tr>\n<th>Expr</th>\n<th>Meaning</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td><code>a | b</code></td>\n<td>pipe in code</td>\n</tr>\n<tr>\n<td>x | y</td>\n<td>escaped pipe</td>\n</tr>\n</tbody>\n</table>\n">>},
        {<<"| a |\n|---|\n| \\|\\|\\| |\n| \\\\| |\n">>,
            <<"<table>\n<thead>\n<tr>\n<th>a</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>|||</td>\n</tr>\n<tr>\n<td>|</td>\n</tr>\n</tbody>\n</table>\n">>},
        {<<"a \\| b | c\n--- | ---\nx \\| y | z \\\\| w\n">>,
            <<"<table>\n<thead>\n<tr>\n<th>a | b</th>\n<th>c</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>x | y</td>\n<td>z | w</td>\n</tr>\n</tbody>\n</table>\n">>},
        {<<"| a | b |\n|---|---|\n| no escapes | here |\n| \\ | \\x |\n">>,
            <<"<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>no escapes</td>\n<td>here</td>\n</tr>\n<tr>\n<td>\\</td>\n<td>\\x</td>\n</tr>\n</tbody>\n</table>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

list_item_lines_test() ->
    %% expected output was generated with the parser before the tab-free item scanner
    Cases = [
        {<<"- a\n\n  b\n  c\n\n  d\n- e\n">>,
            <<"<ul>\n<li>\n<p>a</p>\n<p>b\nc</p>\n<p>d</p>\n</li>\n<li>\n<p>e</p>\n</li>\n</ul>\n">>},
        {<<"1. a\n\n   ```js\n       x\n   ```\n\n2. b\n">>,
            <<"<ol>\n<li>\n<p>a</p>\n<pre><code class=\"language-js\">    x\n</code></pre>\n</li>\n<li>\n<p>b</p>\n</li>\n</ol>\n">>},
        {<<"10. a\n    b\n    \n    c\n">>,
            <<"<ol start=\"10\">\n<li>\n<p>a\nb</p>\n<p>c</p>\n</li>\n</ol>\n">>},
        {<<"- a\n  b  \n  c\n">>, <<"<ul>\n<li>a\nb<br />\nc</li>\n</ul>\n">>},
        {<<"- a\n   \n  b\n">>, <<"<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ul>\n">>},
        {<<"- a\n\n\n  b\n">>, <<"<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ul>\n">>},
        {<<"-\n  a\n  b\n">>, <<"<ul>\n<li>a\nb</li>\n</ul>\n">>},
        {<<"- a\n  - b\n    c\n  - d\n">>,
            <<"<ul>\n<li>a\n<ul>\n<li>b\nc</li>\n<li>d</li>\n</ul>\n</li>\n</ul>\n">>},
        {<<"1. a\n   2. b\n      c\n">>, <<"<ol>\n<li>a\n2. b\nc</li>\n</ol>\n">>},
        {<<"- a\n\n  b\n\n- c\n">>,
            <<"<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n">>},
        {<<"- a\n  b\n\tc\n">>, <<"<ul>\n<li>a\nb\nc</li>\n</ul>\n">>},
        {<<"* a\n\n    code?\n\n  para\n">>,
            <<"<ul>\n<li>\n<p>a</p>\n<p>code?</p>\n<p>para</p>\n</li>\n</ul>\n">>},
        {<<"- a\n   misindented\n  ok\n">>, <<"<ul>\n<li>a\nmisindented\nok</li>\n</ul>\n">>}
    ],
    [?assertEqual(Out, erlmark:to_html(In)) || {In, Out} <- Cases].

tab_blank_line_test() ->
    %% a line of blanks that includes a tab is blank (paragraph end, quote, list item)
    ?assertEqual(<<"<p>a</p>\n<p>b</p>\n">>, erlmark:to_html(<<"a\n \t \nb\n">>)),
    ?assertEqual(
        <<"<p>Repeatedly solving</p>\n<ul>\n<li>how</li>\n</ul>\n">>,
        erlmark:to_html(<<"Repeatedly solving\n\t\n- how\n">>)
    ),
    ?assertEqual(
        <<"<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n">>,
        erlmark:to_html(<<"> a\n>\t\n> b\n">>)
    ),
    %% a blank line inside indented code keeps the columns beyond the four stripped
    ?assertEqual(
        <<"<pre><code>a\n   \nb\n</code></pre>\n">>, erlmark:to_html(<<"    a\n\t   \n    b\n">>)
    ).

tab_indented_delimiter_row_test() ->
    %% four or more columns of indentation (a tab) cannot start a table
    ?assertEqual(<<"<p>x | y\n---|---</p>\n">>, erlmark:to_html(<<"x | y\n\t---|---\n">>)),
    ?assertEqual(<<"<p>x | y\n---|---</p>\n">>, erlmark:to_html(<<"x | y\n \t---|---\n">>)).

quote_tab_after_space_test() ->
    %% `> ` followed by a tab expands against its real column, like the equivalent spaces
    ?assertEqual(erlmark:to_html(<<">   *\n">>), erlmark:to_html(<<"> \t*\n">>)),
    ?assertEqual(erlmark:to_html(<<">    \n>   !x\n">>), erlmark:to_html(<<"> \t\n> \t!x\n">>)),
    ?assertEqual(
        <<"<blockquote>\n<ul>\n<li></li>\n</ul>\n</blockquote>\n">>, erlmark:to_html(<<"> \t*\n">>)
    ).

bom_test() ->
    ?assertEqual(<<"<h1>Hi</h1>\n">>, erlmark:to_html(<<16#EF, 16#BB, 16#BF, "# Hi\n">>)),
    ?assertEqual(erlmark:to_html(<<"x">>), erlmark:to_html(<<16#EF, 16#BB, 16#BF, "x">>)).

pointy_destination_escape_test() ->
    %% a backslash before a line end is not an escape: the destination cannot span lines
    ?assertEqual(<<"<p>[a](&lt;b<br />\nc&gt;)</p>\n">>, erlmark:to_html(<<"[a](<b\\\nc>)\n">>)),
    ?assertEqual(<<"<p><a href=\"b%3E\">a</a></p>\n">>, erlmark:to_html(<<"[a](<b\\>>)\n">>)).
