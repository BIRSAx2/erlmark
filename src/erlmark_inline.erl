%% @private
%% Inline parser: renders the inline content of a paragraph/heading/cell
%% straight to HTML iodata, using the CommonMark delimiter-stack approach.
-module(erlmark_inline).
-include("erlmark.hrl").
-compile({inline, [part/3, hit/7]}).

-export([render/2]).

%% Stack tokens (the stack is a reversed list, head = most recent):
%%   IoData (any non-tuple)              finished HTML fragment
%%   {d, Char, Count, CanOpen, CanClose, OrigCount}   emphasis delimiter run
%%   {b, IsImage, LinkCountAtOpen, RestAtOpen}  '[' or '![' opener (inert once it fails)

-spec render(binary(), erlmark:refs()) -> iodata().
render(Src, Refs) ->
    Stack = scan(Src, $\s, [], {Refs, [], 0}),
    %% Fast path: if the stack holds only finished fragments (no delimiters or
    %% brackets) there is nothing to resolve; unwrap in a single pass.
    case unwrap(Stack, []) of
        none -> emph(lists:reverse(Stack));
        IoData -> IoData
    end.

unwrap([X | T], Acc) when not is_tuple(X) -> unwrap(T, [X | Acc]);
%% A bracket that never became a link is just text.
unwrap([{b, true, _, _} | T], Acc) -> unwrap(T, [<<"![">> | Acc]);
unwrap([{b, false, _, _} | T], Acc) -> unwrap(T, [<<"[">> | Acc]);
%% A delimiter run that cannot close anything. If no run on the stack can close, nothing
%% can match, so every run is plain text (`a * b`, `snake_case`, `*a **b`).
unwrap([{d, _, _, _, false, _} = D | T], Acc) -> unwrap(T, [flat1(D) | Acc]);
unwrap([], Acc) -> Acc;
unwrap(_, _) -> none.

%%--------------------------------------------------------------------
%% Scanner
%%--------------------------------------------------------------------
%% Text runs are scanned byte by byte. `&`, `<`, `>` and `"` are treated as
%% specials, so a text run never needs escaping and can be emitted as-is.

-define(HIT, hit(C, R, O, L, P, St, Rf)).
% ASCII character class (ws / punct / other), indexed by code point + 1.
-define(CLS_TAB,
    {other, other, other, other, other, other, other, other, other, ws, ws, other, ws, ws, other,
        other, other, other, other, other, other, other, other, other, other, other, other, other,
        other, other, other, other, ws, punct, punct, punct, punct, punct, punct, punct, punct,
        punct, punct, punct, punct, punct, punct, punct, other, other, other, other, other, other,
        other, other, other, other, punct, punct, punct, punct, punct, punct, punct, other, other,
        other, other, other, other, other, other, other, other, other, other, other, other, other,
        other, other, other, other, other, other, other, other, other, other, other, punct, punct,
        punct, punct, punct, punct, other, other, other, other, other, other, other, other, other,
        other, other, other, other, other, other, other, other, other, other, other, other, other,
        other, other, other, other, punct, punct, punct, punct, other}
).

-define(TXT_PLAIN,
    {true, true, true, true, true, true, true, true, true, true, false, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, false, false, true, true, true, false, true, true, true, false, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, false, true, false, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, false, false, false, true, false, false, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, false, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true}
).
-define(EAGER_LIMIT, 12).
-define(PLAIN(X), ((X >= $a andalso X =< $z) orelse X =:= $\s)).

scan(Bin, Prev, Stack, Rf) -> txt(Bin, Bin, 0, Prev, Stack, Rf).

%% Unrolled fast path: four ordinary bytes (a-z, space) per iteration.
txt(<<A, B, C, D, R/binary>>, O, L, P, St, Rf) when
    ?PLAIN(A), ?PLAIN(B), ?PLAIN(C), ?PLAIN(D)
->
    txt(R, O, L + 4, P, St, Rf);
%% Second tier, one table lookup per byte: capitals, digits, punctuation, UTF-8 ... Any
%% byte that is not one of the characters handled by hit/7 (so a special fails fast).
txt(<<A, B, C, D, R/binary>>, O, L, P, St, Rf) when
    element(A + 1, ?TXT_PLAIN),
    element(B + 1, ?TXT_PLAIN),
    element(C + 1, ?TXT_PLAIN),
    element(D + 1, ?TXT_PLAIN)
->
    txt(R, O, L + 4, P, St, Rf);
txt(<<C, R/binary>>, O, L, P, St, Rf) ->
    case C of
        $\\ -> ?HIT;
        $` -> ?HIT;
        $* -> ?HIT;
        $_ -> ?HIT;
        $[ -> ?HIT;
        $] -> ?HIT;
        $! -> ?HIT;
        $< -> ?HIT;
        $> -> ?HIT;
        $& -> ?HIT;
        $" -> ?HIT;
        $\n -> ?HIT;
        $~ -> ?HIT;
        _ -> txt(R, O, L + 1, P, St, Rf)
    end;
txt(<<>>, _O, 0, _P, St, _Rf) ->
    St;
txt(<<>>, O, L, _P, St, _Rf) ->
    <<Text:L/binary, _/binary>> = O,
    [Text | St].

hit($\n, R, O, L, _P, St, Rf) ->
    <<Text:L/binary, _/binary>> = O,
    newline(Text, R, St, Rf);
hit(C, R, _O, 0, P, St, Rf) ->
    special(C, R, P, St, Rf);
hit(C, R, O, L, _P, St, Rf) ->
    M = L - 1,
    <<Text:L/binary, _/binary>> = O,
    <<_:M/binary, Last, _/binary>> = Text,
    %% ASCII stays inline; only a multi-byte character needs decoding.
    Prev =
        if
            Last < 128 -> Last;
            true -> erlmark_util:last_cp(Text)
        end,
    special(C, R, Prev, [Text | St], Rf).

newline(Text, Rest, Stack, Rf) ->
    Trimmed = rtrim_spaces(Text),
    Hard = byte_size(Text) - byte_size(Trimmed) >= 2,
    St1 =
        case Trimmed of
            <<>> -> Stack;
            _ -> [Trimmed | Stack]
        end,
    Br =
        case Hard of
            true -> <<"<br />\n">>;
            false -> soft_break()
        end,
    scan(Rest, $\s, [Br | St1], Rf).

soft_break() ->
    case get(erlmark_flags) of
        undefined ->
            <<"\n">>;
        _ ->
            case erlmark_util:flag(breaks) of
                true -> <<"<br />\n">>;
                false -> <<"\n">>
            end
    end.

rtrim_spaces(<<>> = B) ->
    B;
rtrim_spaces(B) ->
    N = byte_size(B),
    M = N - 1,
    %% Usual case: no trailing space, return the text untouched.
    case B of
        <<_:M/binary, $\s>> -> rtrim_spaces(B, M);
        _ -> B
    end.
rtrim_spaces(B, N) when N > 0 ->
    M = N - 1,
    case B of
        <<_:M/binary, $\s, _/binary>> ->
            rtrim_spaces(B, M);
        _ when N =:= byte_size(B) -> B;
        _ ->
            <<T:N/binary, _/binary>> = B,
            T
    end;
rtrim_spaces(_, 0) ->
    <<>>.

%% C was found at the front of the (already consumed) text; R is what follows.
special($\\, <<$\n, R/binary>>, _P, St, Rf) ->
    scan(R, $\s, [<<"<br />\n">> | St], Rf);
special($\\, <<X, R/binary>>, _P, St, Rf) when ?IS_PUNCT(X) ->
    scan(R, X, [erlmark_util:esc(<<X>>) | St], Rf);
special($\\, R, _P, St, Rf) ->
    scan(R, $\\, [<<"\\">> | St], Rf);
special($>, R, _P, St, Rf) ->
    scan(R, $>, [<<"&gt;">> | St], Rf);
special($", R, _P, St, Rf) ->
    scan(R, $", [<<"&quot;">> | St], Rf);
%% The four entities that decode to HTML-significant characters are by far the
%% most common; their escaped form is known, so skip the table lookup.
special($&, <<"amp;", R/binary>>, _P, St, Rf) ->
    scan(R, $&, [<<"&amp;">> | St], Rf);
special($&, <<"lt;", R/binary>>, _P, St, Rf) ->
    scan(R, $<, [<<"&lt;">> | St], Rf);
special($&, <<"gt;", R/binary>>, _P, St, Rf) ->
    scan(R, $>, [<<"&gt;">> | St], Rf);
special($&, <<"quot;", R/binary>>, _P, St, Rf) ->
    scan(R, $", [<<"&quot;">> | St], Rf);
special($&, R, _P, St, Rf) ->
    case erlmark_util:entity(R) of
        {ok, Decoded, N} ->
            <<_:N/binary, R2/binary>> = R,
            Prev =
                case Decoded of
                    <<X>> ->
                        X;
                    <<B1, B2>> when B1 >= 16#C2, B1 =< 16#DF ->
                        ((B1 band 16#1F) bsl 6) bor (B2 band 16#3F);
                    <<B1, B2, B3>> when B1 >= 16#E0, B1 =< 16#EF ->
                        ((B1 band 16#0F) bsl 12) bor ((B2 band 16#3F) bsl 6) bor (B3 band 16#3F);
                    _ ->
                        erlmark_util:last_cp(Decoded)
                end,
            %% A reference that decodes to text starting with a non-ASCII byte never
            %% contains & < > " (checked against all 2,125 named entities), so it needs
            %% no escaping.
            Node =
                case Decoded of
                    <<Lead, _/binary>> when Lead >= 16#80 -> Decoded;
                    _ -> erlmark_util:esc(Decoded)
                end,
            scan(R2, Prev, [Node | St], Rf);
        none ->
            scan(R, $&, [<<"&amp;">> | St], Rf)
    end;
special($`, R, _P, St, Rf) ->
    case R of
        <<$`, _/binary>> ->
            N = 1 + erlmark_util:run_len(R, $`),
            <<_:(N - 1)/binary, After/binary>> = R,
            code_run(N, After, St, Rf);
        %% the common case: a single backtick
        _ ->
            code_run(1, R, St, Rf)
    end;
special(C, R, Prev, St, Rf) when C =:= $*; C =:= $_; C =:= $~ ->
    case R of
        %% a run of more than one delimiter
        <<C, _/binary>> ->
            N = 1 + erlmark_util:run_len(R, C),
            <<_:(N - 1)/binary, After/binary>> = R,
            delim_run(C, N, After, Prev, St, Rf);
        %% the common case: a single delimiter, nothing to measure or slice
        _ ->
            delim_run(C, 1, R, Prev, St, Rf)
    end;
special($[, <<$^, R0/binary>> = R, _P, St, {Refs, B, LN} = Rf) ->
    case footnote_ref(R0, Refs) of
        {ok, Node, Rest} -> scan(Rest, $], [Node | St], Rf);
        none -> scan(R, $[, [{b, false, LN, R} | St], {Refs, [{false, LN, R} | B], LN})
    end;
special($[, R, _P, St, {Refs, B, LN}) ->
    scan(R, $[, [{b, false, LN, R} | St], {Refs, [{false, LN, R} | B], LN});
special($!, <<$[, R/binary>>, _P, St, {Refs, B, LN}) ->
    scan(R, $[, [{b, true, LN, R} | St], {Refs, [{true, LN, R} | B], LN});
special($!, R, _P, St, Rf) ->
    scan(R, $!, [<<"!">> | St], Rf);
special($], R, _P, St, Rf) ->
    close_bracket(R, St, Rf);
special($<, R, _P, St, Rf) ->
    case
        maybe_autolink(R) andalso erlmark_util:could_autolink(R) andalso erlmark_util:autolink(R)
    of
        {ok, Text, Href, Rest} ->
            Node =
                case dest(Href) of
                    %% Unchanged by URL encoding: every byte is URL-safe, hence also
                    %% free of & < > ", so the text needs no escaping either.
                    U when is_binary(U) ->
                        [<<"<a href=\"">>, U, <<"\">">>, Text, <<"</a>">>];
                    U ->
                        [<<"<a href=\"">>, U, <<"\">">>, erlmark_util:esc(Text), <<"</a>">>]
                end,
            scan(Rest, $>, [Node | St], Rf);
        _ ->
            case erlmark_util:html_tag_len(R) of
                {ok, L} ->
                    <<Tag:L/binary, Rest/binary>> = R,
                    scan(Rest, $>, [raw_html(Tag) | St], Rf);
                none ->
                    scan(R, $<, [<<"&lt;">> | St], Rf)
            end
    end.

%% `[^label]` where a footnote with that label is defined (and footnotes are enabled).
footnote_ref(R, Refs) ->
    case erlmark_util:flag(footnotes) of
        true ->
            case binary:split(R, <<"]">>) of
                [Label, Rest] when Label =/= <<>> ->
                    Key = {footnote, erlmark_util:norm_label(Label)},
                    case Refs of
                        #{Key := {DefLabel, _Blocks}} -> footnote_node(Key, DefLabel, Rest);
                        _ -> none
                    end;
                _ ->
                    none
            end;
        false ->
            none
    end.

footnote_node(Key, DefLabel, Rest) ->
    {N, Label, K} = erlmark_util:footnote_reference(Key, DefLabel),
    Id =
        case K of
            1 -> <<"fnref-", Label/binary>>;
            _ -> <<"fnref-", Label/binary, $-, (integer_to_binary(K))/binary>>
        end,
    {ok,
        [
            <<"<sup class=\"footnote-ref\"><a href=\"#fn-">>,
            erlmark_util:url(Label),
            <<"\" id=\"">>,
            erlmark_util:esc(Id),
            <<"\" data-footnote-ref>">>,
            integer_to_binary(N),
            <<"</a></sup>">>
        ],
        Rest}.

%% Raw inline HTML, or the placeholder that replaces it in safe mode.
raw_html(Tag) ->
    case get(erlmark_flags) of
        undefined ->
            [<<"<">>, Tag];
        _ ->
            case erlmark_util:flag(safe) of
                true -> <<"<!-- raw HTML omitted -->">>;
                false -> [<<"<">>, Tag]
            end
    end.

%% A link or image destination, empty in safe mode when its scheme is not safe.
dest(Url) ->
    case get(erlmark_flags) of
        undefined -> erlmark_util:url(Url);
        _ -> checked_dest(Url)
    end.

checked_dest(Url) ->
    case erlmark_util:flag(safe) andalso erlmark_util:unsafe_url(Url) of
        true -> <<>>;
        false -> erlmark_util:url(Url)
    end.

code_run(N, After, St, Rf) ->
    case find_closer(After, N) of
        {ok, Content, Rest, HasNl} ->
            Code = code_span(Content, HasNl),
            scan(Rest, $`, [[<<"<code>">>, erlmark_util:esc(Code), <<"</code>">>] | St], Rf);
        none ->
            scan(After, $`, [binary:copy(<<"`">>, N) | St], Rf)
    end.

delim_run(C, N, After, Prev, St, Rf) ->
    case C =:= $~ andalso N > 2 of
        true ->
            scan(After, $~, [binary:copy(<<"~">>, N) | St], Rf);
        false ->
            Next =
                case After of
                    <<X, _/binary>> when X < 128 -> X;
                    _ -> erlmark_util:first_cp(After)
                end,
            {Open, Close} = flanking(C, Prev, Next),
            case Close andalso N =< 2 andalso eager(St, C, N, []) of
                {ok, Node, Deeper} -> scan(After, C, [Node | Deeper], Rf);
                _ -> scan(After, C, [{d, C, N, Open, Close, N} | St], Rf)
            end
    end.

%% '<' followed by '/', '!' or '?' is raw HTML (closing tag, comment, declaration,
%% processing instruction) and can never be an autolink.
maybe_autolink(<<C, _/binary>>) when C =:= $/; C =:= $!; C =:= $? -> false;
maybe_autolink(_) -> true.

%%--------------------------------------------------------------------
%% Code spans
%%--------------------------------------------------------------------

%% Finds the closing backtick run; also reports whether the content has a newline
%% (so the content is not scanned a second time).
find_closer(After, N) -> fc(After, After, 0, N, false).

fc(<<C, R/binary>>, O, Off, N, Nl) when C =/= $`, C =/= $\n -> fc(R, O, Off + 1, N, Nl);
fc(<<$`, _/binary>> = R, O, Off, N, Nl) ->
    Run = erlmark_util:run_len(R, $`),
    case Run =:= N of
        true ->
            <<Content:Off/binary, _:N/binary, Rest/binary>> = O,
            {ok, Content, Rest, Nl};
        false ->
            <<_:Run/binary, R2/binary>> = R,
            fc(R2, O, Off + Run, N, Nl)
    end;
fc(<<$\n, R/binary>>, O, Off, N, _) ->
    fc(R, O, Off + 1, N, true);
fc(<<_, R/binary>>, O, Off, N, Nl) ->
    fc(R, O, Off + 1, N, Nl);
fc(<<>>, _, _, _, _) ->
    none.

code_span(Content, HasNl) ->
    C1 =
        case HasNl of
            true ->
                <<
                    <<
                        (case X of
                            $\n -> $\s;
                            _ -> X
                        end)
                    >>
                 || <<X>> <= Content
                >>;
            false ->
                Content
        end,
    %% One leading and one trailing space are stripped if both exist and the
    %% content is not all spaces.
    case C1 of
        <<$\s, Rest/binary>> when byte_size(Rest) >= 1 ->
            Inner = byte_size(Rest) - 1,
            case Rest of
                <<Mid:Inner/binary, $\s>> ->
                    case all_spaces(C1) of
                        true -> C1;
                        false -> Mid
                    end;
                _ ->
                    C1
            end;
        _ ->
            C1
    end.

all_spaces(<<$\s, R/binary>>) -> all_spaces(R);
all_spaces(<<>>) -> true;
all_spaces(_) -> false.

%%--------------------------------------------------------------------
%% Delimiter flanking
%%--------------------------------------------------------------------

flanking(C, Prev, Next) ->
    P = cls(Prev),
    N = cls(Next),
    %% left-flanking:  not followed by whitespace, and (not followed by
    %%                 punctuation, or preceded by whitespace/punctuation)
    %% right-flanking: the mirror image
    Left = N =/= ws andalso (N =/= punct orelse P =/= other),
    Right = P =/= ws andalso (P =/= punct orelse N =/= other),
    case C of
        $_ ->
            {
                Left andalso ((not Right) orelse P =:= punct),
                Right andalso ((not Left) orelse N =:= punct)
            };
        _ ->
            {Left, Right}
    end.

%% Classify a code point once: whitespace, punctuation (incl. symbols) or other.
cls(C) when C < 128 -> element(C + 1, ?CLS_TAB);
cls(C) ->
    case erlmark_util:unicode_ws(C) of
        true ->
            ws;
        false ->
            case erlmark_util:unicode_punct(C) of
                true -> punct;
                false -> other
            end
    end.

%%--------------------------------------------------------------------
%% Links and images
%%--------------------------------------------------------------------

%% Open brackets live on their own stack, so finding the opener is O(1) and a
%% failed bracket costs O(1): the opener's token simply stays in the token stack,
%% inert, and is rendered as the literal text it is.
close_bracket(R, St, {_, [], _} = Rf) ->
    scan(R, $], [<<"]">> | St], Rf);
close_bracket(R, St, {Refs, [{Img, LNOpen, ROpen} | BRest], LN}) ->
    %% A link may not contain another link: an opener is inactive once a link
    %% has been formed since it was pushed (images may contain links).
    Active = Img orelse LNOpen =:= LN,
    Result =
        case Active of
            true ->
                Label = part(ROpen, 0, byte_size(ROpen) - byte_size(R) - 1),
                resolve(R, Label, Refs);
            false ->
                none
        end,
    case Result of
        {ok, Url, Title, R2} ->
            {Above, Below} = take_above(St, byte_size(ROpen)),
            %% Alt text of an image with only plain fragments inside needs no
            %% emphasis pass and no tag stripping.
            PlainAlt = Img andalso all_plain(Above),
            Inner =
                case PlainAlt of
                    true -> Above;
                    false -> emph(Above)
                end,
            case Img of
                false ->
                    Node = [
                        <<"<a href=\"">>,
                        dest(Url),
                        link_tail(Title),
                        Inner,
                        <<"</a>">>
                    ],
                    scan(R2, $), [Node | Below], {Refs, BRest, LN + 1});
                true ->
                    Alt =
                        case PlainAlt of
                            true -> iolist_to_binary(Inner);
                            false -> erlmark_util:strip_tags(Inner)
                        end,
                    Node = [
                        <<"<img src=\"">>,
                        dest(Url),
                        <<"\" alt=\"">>,
                        Alt,
                        img_tail(Title)
                    ],
                    scan(R2, $), [Node | Below], {Refs, BRest, LN})
            end;
        none ->
            scan(R, $], [<<"]">> | St], {Refs, BRest, LN})
    end.

%% Split the token stack at the opener whose "rest at open" has size Id (that
%% size is unique per opener). Above comes back in chronological order.
take_above([{b, _, _, RO} | Below], Id, Above) when byte_size(RO) =:= Id -> {Above, Below};
take_above([X | T], Id, Above) -> take_above(T, Id, [X | Above]).

take_above(St, Id) -> take_above(St, Id, []).

%% Only plain-text binaries qualify: code spans, raw HTML, autolinks and hard
%% breaks are fragments that contain tags, which the alt text must not keep.
all_plain([X | T]) when is_binary(X) -> no_lt(X) andalso all_plain(T);
all_plain([]) -> true;
all_plain(_) -> false.

no_lt(<<$<, _/binary>>) -> false;
no_lt(<<_, R/binary>>) -> no_lt(R);
no_lt(<<>>) -> true.

link_tail(none) -> <<"\">">>;
link_tail(Title) -> [<<"\" title=\"">>, erlmark_util:esc(Title), <<"\">">>].

img_tail(none) -> <<"\" />">>;
img_tail(Title) -> [<<"\" title=\"">>, erlmark_util:esc(Title), <<"\" />">>].

resolve(R, Label, Rf) ->
    case R of
        <<$(, R1/binary>> ->
            case inline_link(R1) of
                {ok, _, _, _} = Ok -> Ok;
                none -> reference(R, Label, Rf)
            end;
        _ ->
            reference(R, Label, Rf)
    end.

reference(_R, _Label, Rf) when map_size(Rf) =:= 0 -> none;
reference(R, Label, Rf) ->
    case R of
        <<$[, R1/binary>> ->
            case erlmark_util:label_len(R1) of
                %% collapsed reference: [text][]
                {ok, 0} ->
                    lookup(Label, part(R1, 1, byte_size(R1) - 1), Rf);
                %% full reference: [text][label]. If the label is undefined the
                %% whole thing is not a link (no fallback to a shortcut reference).
                {ok, N} ->
                    <<L2:N/binary, $], Rest/binary>> = R1,
                    lookup(L2, Rest, Rf);
                none ->
                    lookup(Label, R, Rf)
            end;
        _ ->
            lookup(Label, R, Rf)
    end.

lookup(Label, Rest, Rf) ->
    case erlmark_util:norm_label(Label) of
        <<>> ->
            none;
        Key ->
            case Rf of
                #{Key := {Url, Title}} -> {ok, Url, Title, Rest};
                _ -> none
            end
    end.

inline_link(R1) ->
    %% The common shapes need no whitespace skipping at all.
    R2 =
        case R1 of
            <<C, _/binary>> when C > 32 -> R1;
            _ -> element(1, erlmark_util:skip_ws(R1))
        end,
    case R2 of
        <<$), R3/binary>> ->
            {ok, <<>>, none, R3};
        _ ->
            case erlmark_util:parse_dest(R2) of
                {ok, Dest, <<$), R5/binary>>} ->
                    {ok, Dest, none, R5};
                {ok, Dest, R3} ->
                    {R4, _} = erlmark_util:skip_ws(R3),
                    case R4 of
                        <<$), R5/binary>> ->
                            {ok, Dest, none, R5};
                        _ when byte_size(R4) =/= byte_size(R3) ->
                            case erlmark_util:parse_title(R4) of
                                {ok, Title, R5} ->
                                    {R6, _} = erlmark_util:skip_ws(R5),
                                    case R6 of
                                        <<$), R7/binary>> -> {ok, Dest, Title, R7};
                                        _ -> none
                                    end;
                                none ->
                                    none
                            end;
                        _ ->
                            none
                    end;
                none ->
                    none
            end
    end.

%%--------------------------------------------------------------------
%% Emphasis resolution

%% Eager fast path for a closing run of length 1 or 2: if only plain text lies
%% between it and an opener of the same character and the exact same length,
%% the deferred algorithm below would pair them identically (nearest opener, no
%% remnants, rule-of-3 cannot apply to equal lengths), so resolve right away.
%% The opener must not be able to close: a run that can do both is itself a closer
%% and has to look for an opener first.
%% The walk is bounded: finished fragments pile up in long runs of emphasis, and an
%% unbounded walk would make the whole scan quadratic. Giving up is always safe:
%% the closer is then just pushed and the deferred algorithm resolves it.
eager(St, C, N, Acc) -> eager(St, C, N, Acc, ?EAGER_LIMIT).

eager(_, _, _, _, 0) -> none;
eager([X | T], C, N, Acc, L) when not is_tuple(X) -> eager(T, C, N, [X | Acc], L - 1);
eager([{d, C, N, true, false, _} | Deeper], C, N, Acc, _) -> {ok, wrap(C, N, Acc), Deeper};
eager(_, _, _, _, _) -> none.

%%--------------------------------------------------------------------

%% Deferred emphasis resolution. Len is the length of Out, and Bots remembers, per
%% closer class, how many tokens at the bottom of Out are known to hold no usable
%% opener (cmark's "openers_bottom"). Without it every unmatched closer rescans
%% every earlier delimiter and the whole pass is quadratic.
emph(Tokens) -> emph(Tokens, [], 0, #{}).

emph([], Out, _, _) ->
    flat_rev(Out, []);
emph([{d, C, N, Open, true, Orig} = D | T], Out, Len, Bots) ->
    Key = bottom_key(C, N, Open, Orig),
    Safe = maps:get(Key, Bots, 0),
    case find_opener(Out, D, [], Len - Safe, 0) of
        {ok, Between, {d, _, M, OO, OC, OrigM}, Deeper, Steps} ->
            Use = use(C, M, N),
            Inner = flat(Between),
            Node = wrap(C, Use, Inner),
            DeeperLen = Len - Steps,
            {Remain, RLen} =
                case M - Use of
                    0 -> {[], 0};
                    MR -> {[{d, C, MR, OO, OC, OrigM}], 1}
                end,
            Out1 = [Node | Remain ++ Deeper],
            Len1 = DeeperLen + RLen + 1,
            Bots1 = shrink(Bots, DeeperLen),
            case N - Use of
                0 -> emph(T, Out1, Len1, Bots1);
                NR -> emph([{d, C, NR, Open, true, Orig} | T], Out1, Len1, Bots1)
            end;
        none ->
            %% Nothing below this point can match this class of closer.
            emph(T, [D | Out], Len + 1, Bots#{Key => Len})
    end;
emph([X | T], Out, Len, Bots) ->
    emph(T, [X | Out], Len + 1, Bots).

%% What decides whether an opener is usable for a closer: the character, whether
%% the closer can also open, and (rule of 3) its original length mod 3; for '~'
%% the length itself.
bottom_key($~, N, _, _) -> {$~, N};
bottom_key(C, _, Open, Orig) -> {C, Open, Orig rem 3}.

%% A match consumed tokens above DeeperLen: floors above it are no longer valid.
shrink(Bots, _) when map_size(Bots) =:= 0 -> Bots;
shrink(Bots, DeeperLen) -> maps:map(fun(_, V) -> min(V, DeeperLen) end, Bots).

use($~, _M, N) -> N;
use(_, M, N) when M >= 2, N >= 2 -> 2;
use(_, _, _) -> 1.

wrap($~, _, Inner) -> [<<"<del>">>, Inner, <<"</del>">>];
wrap(_, 2, Inner) -> [<<"<strong>">>, Inner, <<"</strong>">>];
wrap(_, 1, Inner) -> [<<"<em>">>, Inner, <<"</em>">>].

%% Walk the already-processed output looking for a usable opener, looking at no
%% more than Limit tokens. Returns how many tokens were walked, opener included.
find_opener(_, _, _, Limit, Steps) when Steps >= Limit -> none;
find_opener([{d, C, M, true, OC, OrigM} = Op | Deeper], {d, C, N, CO, _, OrigN} = D, Between, L, S) ->
    Ok =
        case C of
            $~ ->
                M =:= N;
            _ ->
                not ((OC orelse CO) andalso (OrigM + OrigN) rem 3 =:= 0 andalso
                    not (OrigM rem 3 =:= 0 andalso OrigN rem 3 =:= 0))
        end,
    case Ok of
        true -> {ok, Between, Op, Deeper, S + 1};
        false -> find_opener(Deeper, D, [Op | Between], L, S + 1)
    end;
find_opener([X | Deeper], D, Between, L, S) ->
    find_opener(Deeper, D, [X | Between], L, S + 1);
find_opener([], _, _, _, _) ->
    none.

flat(Tokens) -> [flat1(T) || T <- Tokens].

%% Out is the stack (most recent first): convert and re-order in a single pass.
flat_rev([T | Ts], Acc) -> flat_rev(Ts, [flat1(T) | Acc]);
flat_rev([], Acc) -> Acc.

flat1(X) when not is_tuple(X) -> X;
flat1({d, $*, 1, _, _, _}) -> <<"*">>;
flat1({d, $*, 2, _, _, _}) -> <<"**">>;
flat1({d, $_, 1, _, _, _}) -> <<"_">>;
flat1({d, $_, 2, _, _, _}) -> <<"__">>;
flat1({d, $~, 1, _, _, _}) -> <<"~">>;
flat1({d, $~, 2, _, _, _}) -> <<"~~">>;
flat1({d, C, N, _, _, _}) -> binary:copy(<<C>>, N);
flat1({b, true, _, _}) -> <<"![">>;
flat1({b, false, _, _}) -> <<"[">>.

%% Pattern-matching slice: same as binary:part/3 for non-negative lengths, but
%% inlined (no BIF call).
part(B, S, L) ->
    <<_:S/binary, R:L/binary, _/binary>> = B,
    R.
