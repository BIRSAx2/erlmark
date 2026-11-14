%% @private
%% Block-structure parser: turns Markdown text into a list of block nodes.
%% Inline content is kept as raw binaries and parsed at render time.
-module(erlmark_block).
-include("erlmark.hrl").
-compile({inline, [part/3]}).

-export([parse/1]).

%% Table-row scan: true for every byte except `\` and `|`, so four bytes can be skipped at once.
-define(SC_TAB,
    {true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, false, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, false, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true}
).
%% Maximum nesting of block quotes / list items (see quote/3).
-define(MAX_DEPTH, 64).
-export_type([block/0, item/0]).

-type align() :: none | left | right | center.
-type block() ::
    {heading, 1..6, binary()}
    | {paragraph, binary()}
    | {code, Info :: binary(), Content :: binary()}
    | {blockquote, [block()]}
    | {list, bullet | {ordered, non_neg_integer()}, Tight :: boolean(), [item()]}
    | thematic
    | {html, binary()}
    | {table, [align()], [binary()], [[binary()]]}.
-type item() :: {item, none | checked | unchecked, [block()]}.

-spec parse(binary()) -> {[block()], erlmark:refs()}.
parse(Bin) ->
    {Blocks, _Gap, Refs} = blocks(split_lines(Bin), #{}, 0),
    {Blocks, Refs}.

%%--------------------------------------------------------------------
%% Line handling
%%--------------------------------------------------------------------

split_lines(<<16#EF, 16#BB, 16#BF, Rest/binary>>) ->
    %% a UTF-8 byte-order mark at the start of the document is not content
    split_lines(Rest);
split_lines(Bin) ->
    %% The source is remembered so that the list item scanner can find out, once per document and
    %% only if the document has list items, whether it contains any tab (item_lines/3).
    put(erlmark_src, Bin),
    erase(erlmark_notab),
    erase(erlmark_lazy),
    case binary:match(Bin, <<"\r">>) of
        nomatch ->
            plain_lines(Bin);
        _ ->
            Ms = binary:matches(Bin, <<"\r">>),
            N = length(Ms),
            case N * 70 < byte_size(Bin) of
                %% Few CRs (fewer than about one line in two): fix up just those positions.
                true ->
                    plain_lines(fix_crs(Bin, Ms));
                false ->
                    case crlf_lines(Bin, N) of
                        none -> plain_lines(normalize_cr(Bin));
                        Lines -> Lines
                    end
            end
    end.

%% Same result as normalize_cr/1, touching only the CRs: a CR followed by LF is dropped (the
%% pair is one line end), any other CR becomes an LF.
fix_crs(Bin, Ms) -> iolist_to_binary(fix_crs(Ms, Bin, 0)).

fix_crs([{P, _} | T], Bin, S) ->
    Piece = part(Bin, S, P - S),
    case Bin of
        <<_:(P + 1)/binary, $\n, _/binary>> -> [Piece | fix_crs(T, Bin, P + 1)];
        _ -> [Piece, $\n | fix_crs(T, Bin, P + 1)]
    end;
fix_crs([], Bin, S) ->
    [part(Bin, S, byte_size(Bin) - S)].

%% Tabs are not expanded here: only the places that measure indentation expand
%% them (see norm/1). Expanding everything up front also turned tabs inside
%% fenced code into spaces, which CommonMark implementations preserve.
plain_lines(Bin) -> binary:split(strip_final_nl(Bin), <<"\n">>, [global]).

%% Every CR becomes an LF (CRLF counts as one line end, a lone CR as another).
normalize_cr(Bin) ->
    Lf = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    %% Only classic-Mac line ends (a lone CR) need a second pass.
    case binary:match(Lf, <<"\r">>) of
        nomatch -> Lf;
        _ -> binary:replace(Lf, <<"\r">>, <<"\n">>, [global])
    end.

%% Windows text: split on LF and drop the CR that ends each line, without rewriting the
%% document. Only valid if every CR is such a line-final CR (counted against all CRs);
%% anything else (a lone or doubled CR) returns `none` and takes the normalising path.
crlf_lines(Bin, CrCount) ->
    Pieces = binary:split(Bin, <<"\n">>, [global]),
    {Lines, Stripped} = strip_crs(Pieces, [], 0),
    case CrCount =:= Stripped of
        true -> Lines;
        false -> none
    end.

%% The final line terminator does not start another line: an empty last piece is dropped.
strip_crs([<<>>], Acc, K) ->
    {lists:reverse(Acc), K};
strip_crs([L | T], Acc, K) ->
    case byte_size(L) of
        0 ->
            strip_crs(T, [L | Acc], K);
        Size ->
            M = Size - 1,
            case L of
                <<Body:M/binary, $\r>> -> strip_crs(T, [Body | Acc], K + 1);
                _ -> strip_crs(T, [L | Acc], K)
            end
    end;
strip_crs([], Acc, K) ->
    {lists:reverse(Acc), K}.

%% The line terminator of the last line is not the start of another line.
strip_final_nl(<<>>) ->
    <<>>;
strip_final_nl(B) ->
    Size = byte_size(B),
    case B of
        <<Body:(Size - 1)/binary, $\n>> -> Body;
        _ -> B
    end.

%% Expand a line's leading blanks only when it has any (see split_lines/1).

%% Most lines start with neither a space nor a tab: nothing to do.
expand_tabs(<<C, _/binary>> = L) when C =/= $\s, C =/= $\t -> L;
expand_tabs(<<>> = L) ->
    L;
expand_tabs(<<$\t, R/binary>>) ->
    %% A tab at column 0 reaches column 4; any further leading blanks follow.
    {Col, Rest} = lead(R, 4),
    <<(spaces(Col))/binary, Rest/binary>>;
expand_tabs(L) ->
    case has_lead_tab(L) of
        false ->
            L;
        true ->
            {Col, Rest} = lead(L, 0),
            <<(spaces(Col))/binary, Rest/binary>>
    end.

%% Literal space runs for the usual tab-stop columns; no BIF call.
spaces(4) -> <<"    ">>;
spaces(8) -> <<"        ">>;
spaces(12) -> <<"            ">>;
spaces(2) -> <<"  ">>;
spaces(3) -> <<"   ">>;
spaces(6) -> <<"      ">>;
spaces(N) -> binary:copy(<<" ">>, N).

has_lead_tab(<<$\s, R/binary>>) -> has_lead_tab(R);
has_lead_tab(<<$\t, _/binary>>) -> true;
has_lead_tab(_) -> false.

lead(<<$\s, R/binary>>, C) -> lead(R, C + 1);
lead(<<$\t, R/binary>>, C) -> lead(R, C + 4 - (C rem 4));
lead(R, C) -> {C, R}.

%% {number-of-leading-spaces, rest}
indent(L) -> indent(L, 0).
indent(<<$\s, R/binary>>, N) -> indent(R, N + 1);
indent(R, N) -> {N, R}.

blank(B) -> erlmark_util:is_blank(B).

%%--------------------------------------------------------------------
%% Block loop
%%--------------------------------------------------------------------

%% Returns {Blocks, GapBetweenBlocks, Refs}.
blocks(Lines, Refs, D) -> blocks(Lines, Refs, D, [], false, false).

blocks([], Refs, _D, Acc, Gap, P) ->
    %% a blank line followed only by reference definitions makes the item loose only if
    %% something follows the item (cmark drops the definition paragraph before judging)
    {
        lists:reverse(Acc),
        case {Gap, P} of
            {false, skip} -> trail;
            _ -> Gap
        end,
        Refs
    };
blocks([<<>> | Rest], Refs, D, Acc, Gap, P) ->
    blocks(
        Rest,
        Refs,
        D,
        Acc,
        Gap,
        case P of
            skip -> skip;
            _ -> true
        end
    );
blocks([<<C, _/binary>> | _] = Lines, Refs, D, Acc, Gap, P) when ?IS_LETTER(C) ->
    case paragraph(Lines, Refs) of
        {skip, Rest2, Refs2, _} -> blocks(Rest2, Refs2, D, Acc, Gap, skip_p(P, Acc));
        {B, Rest2, Refs2, Trail} -> add(B, Rest2, Refs2, D, Acc, Gap, P, Trail)
    end;
blocks([<<$\t, C, _/binary>> | _] = Lines, Refs, 0, Acc, Gap, P) when C =/= $\s, C =/= $\t ->
    %% tab = four columns of indentation followed by text: indented code
    {Code, Rest2} = indented_code(Lines),
    add({code, <<>>, Code}, Rest2, Refs, 0, Acc, Gap, P, false);
blocks([<<$\t, _/binary>> = L | Rest], Refs, 0, Acc, Gap, P) ->
    %% A top-level line that starts with a tab: expand it, then classify it.
    blocks([expand_tabs(L) | Rest], Refs, 0, Acc, Gap, P);
blocks([<<C, _/binary>> = L | _] = Lines, Refs, D, Acc, Gap, P) when C =/= $\s, C =/= $\t ->
    %% No leading space: indent 0, and the line is its own remainder.
    case block(L, 0, Lines, Refs, D) of
        {skip, Rest2, Refs2, _} -> blocks(Rest2, Refs2, D, Acc, Gap, skip_p(P, Acc));
        {B, Rest2, Refs2, Trail} -> add(B, Rest2, Refs2, D, Acc, Gap, P, Trail)
    end;
blocks([L | Rest] = Lines, Refs, D, Acc, Gap, P) ->
    case indent(L) of
        {_, <<>>} ->
            blocks(
                Rest,
                Refs,
                D,
                Acc,
                Gap,
                case P of
                    skip -> skip;
                    _ -> true
                end
            );
        {N0, <<$\t, C, _/binary>>} when D =:= 0, N0 =< 3, C =/= $\s, C =/= $\t ->
            %% up to three spaces then a tab reach column 4: indented code
            {Code, Rest2} = indented_code(Lines),
            add({code, <<>>, Code}, Rest2, Refs, 0, Acc, Gap, P, false);
        {_, <<$\t, _/binary>>} when D =:= 0 ->
            %% spaces then a tab: the tab reaches the next tab stop
            blocks([expand_tabs(L) | Rest], Refs, 0, Acc, Gap, P);
        {N, _} when N >= 4 ->
            {Code, Rest2} = indented_code(Lines),
            add({code, <<>>, Code}, Rest2, Refs, D, Acc, Gap, P, false);
        {N, T} ->
            case block(T, N, Lines, Refs, D) of
                {skip, Rest2, Refs2, _} -> blocks(Rest2, Refs2, D, Acc, Gap, skip_p(P, Acc));
                {B, Rest2, Refs2, Trail} -> add(B, Rest2, Refs2, D, Acc, Gap, P, Trail)
            end
    end.

%% a skipped (definition-only) paragraph keeps a preceding blank line pending
skip_p(false, _) -> false;
skip_p(_, []) -> false;
skip_p(_, _) -> skip.

add(B, Rest, Refs, D, Acc, Gap, P, Trail) ->
    Gap1 = Gap orelse (P =/= false andalso Acc =/= []),
    blocks(Rest, Refs, D, [B | Acc], Gap1, Trail).

%% T is the line with its (<4) indentation removed and non-blank.
block(<<C, _/binary>> = T, N, [_ | Rest] = Lines, Refs, Dp) ->
    case C of
        $# ->
            case atx(T) of
                {ok, Lvl, Content} -> {{heading, Lvl, Content}, Rest, Refs, false};
                none -> paragraph(Lines, Refs)
            end;
        $> ->
            quote(Lines, Refs, Dp);
        $` ->
            fence_or_para(T, N, Lines, Refs);
        $~ ->
            fence_or_para(T, N, Lines, Refs);
        $- ->
            thematic_or_list(T, Lines, Refs, Dp);
        $* ->
            thematic_or_list(T, Lines, Refs, Dp);
        $_ ->
            case thematic(T) of
                true -> {thematic, Rest, Refs, false};
                false -> paragraph(Lines, Refs)
            end;
        $+ ->
            list_or_para(T, Lines, Refs, Dp);
        $< ->
            case html_start(T) of
                none -> paragraph(Lines, Refs);
                Type -> html_block(Type, Lines, Refs)
            end;
        Dg when ?IS_DIGIT(Dg) -> list_or_para(T, Lines, Refs, Dp);
        _ ->
            paragraph(Lines, Refs)
    end.

%%--------------------------------------------------------------------
%% ATX headings, thematic breaks, setext
%%--------------------------------------------------------------------

atx(T) ->
    L = erlmark_util:run_len(T, $#),
    if
        L >= 1, L =< 6 ->
            R = part(T, L, byte_size(T) - L),
            case R of
                <<>> -> {ok, L, <<>>};
                <<C, _/binary>> when ?IS_SP(C) -> {ok, L, strip_closing(erlmark_util:trim(R))};
                _ -> none
            end;
        true ->
            none
    end.

strip_closing(B) ->
    K = trailing_hashes(B, byte_size(B), 0),
    Size = byte_size(B),
    if
        K =:= 0 ->
            B;
        K =:= Size ->
            <<>>;
        true ->
            Before = part(B, 0, Size - K),
            case binary:last(Before) of
                C when ?IS_SP(C) -> erlmark_util:rtrim(Before);
                _ -> B
            end
    end.

trailing_hashes(B, N, K) when N > 0 ->
    case binary:at(B, N - 1) of
        $# -> trailing_hashes(B, N - 1, K + 1);
        _ -> K
    end;
trailing_hashes(_, _, K) ->
    K.

%% `- a` / `* a` / `-a` (the usual list-item shapes): the second significant byte is
%% neither the marker nor a blank, so this cannot be a thematic break.
thematic(<<C, X, _/binary>>) when
    (C =:= $- orelse C =:= $* orelse C =:= $_),
    X =/= C,
    X =/= $\s,
    X =/= $\t
->
    false;
thematic(<<C, $\s, X, _/binary>>) when
    (C =:= $- orelse C =:= $* orelse C =:= $_),
    X =/= C,
    X =/= $\s,
    X =/= $\t
->
    false;
thematic(<<C, _/binary>> = T) when C =:= $-; C =:= $*; C =:= $_ -> th(T, C, 0);
thematic(_) ->
    false.

th(<<C, R/binary>>, C, N) -> th(R, C, N + 1);
th(<<S, R/binary>>, C, N) when ?IS_SP(S) -> th(R, C, N);
th(<<>>, _, N) -> N >= 3;
th(_, _, _) -> false.

setext(<<$=, _/binary>> = T) ->
    case
        erlmark_util:is_blank(
            part(T, erlmark_util:run_len(T, $=), byte_size(T) - erlmark_util:run_len(T, $=))
        )
    of
        true -> {ok, 1};
        false -> none
    end;
setext(<<$-, _/binary>> = T) ->
    N = erlmark_util:run_len(T, $-),
    case erlmark_util:is_blank(part(T, N, byte_size(T) - N)) of
        true -> {ok, 2};
        false -> none
    end;
setext(_) ->
    none.

%%--------------------------------------------------------------------
%% Code
%%--------------------------------------------------------------------

indented_code(Lines) -> ic(Lines, [], []).

%% The usual code line: exactly four spaces, then a non-blank byte. No indentation walk,
%% and no pending blank lines to flush in the common case.
ic([<<"    ", C, _/binary>> = L | Rest], Acc, Pending) when C =/= $\s, C =/= $\t ->
    <<_:4/binary, R/binary>> = L,
    case Pending of
        [] -> ic(Rest, [[R, $\n] | Acc], []);
        _ -> ic(Rest, [[R, $\n] | [[P, $\n] || P <- Pending] ++ Acc], [])
    end;
ic([L | Rest] = Lines, Acc, Pending) ->
    case indent(L) of
        {N0, <<$\t, C, R0/binary>>} when N0 =< 3, C =/= $\s, C =/= $\t ->
            %% One tab (column 0 -> 4) followed by a non-blank byte: stripping the four
            %% columns leaves exactly the rest of the line; no expansion, no copy.
            ic(Rest, [[<<C, R0/binary>>, $\n] | [[P, $\n] || P <- Pending] ++ Acc], []);
        {_, <<$\t, _/binary>>} ->
            ic([expand_tabs(L) | Rest], Acc, Pending);
        %% A blank line keeps the columns beyond the four stripped (tabs count as columns).
        {_, <<>>} ->
            ic(Rest, Acc, [strip_cols(expand_tabs(L), 4) | Pending]);
        {N, _} when N >= 4 ->
            ic(Rest, [[strip_cols(L, 4), $\n] | [[P, $\n] || P <- Pending] ++ Acc], []);
        _ ->
            ic_end(Lines, Acc, Pending)
    end;
ic([], Acc, Pending) ->
    ic_end([], Acc, Pending).

%% Trailing blank lines are held in `Pending`; hand a single blank back to
%% the block loop so it still sees that the code block was followed by one.
ic_end(Rest, Acc, Pending) ->
    Rest1 =
        case Pending of
            [] -> Rest;
            _ -> [<<>> | Rest]
        end,
    {iolist_to_binary(lists:reverse(Acc)), Rest1}.

strip_cols(L, N) ->
    case L of
        <<_:N/binary, Rest/binary>> -> Rest;
        _ -> <<>>
    end.

fence_open(<<C, _/binary>> = T) when C =:= $`; C =:= $~ ->
    Len = erlmark_util:run_len(T, C),
    if
        Len >= 3 ->
            Info = erlmark_util:trim(part(T, Len, byte_size(T) - Len)),
            case C =:= $` andalso has_char(Info, $`) of
                true -> none;
                false -> {C, Len, Info}
            end;
        true ->
            none
    end;
fence_open(_) ->
    none.

fence_or_para(T, N, Lines, Refs) ->
    case fence_open(T) of
        none ->
            paragraph(Lines, Refs);
        {C, Len, Info} ->
            [_ | Rest] = Lines,
            {Content, Rest2} = fence_lines(Rest, C, Len, N),
            Word = erlmark_util:unescape(first_word(Info, Info, 0)),
            {{code, Word, iolist_to_binary(Content)}, Rest2, Refs, false}
    end.

%% Returns the content as an iolist built front to back, and the rest of the lines.
fence_lines([], _, _, _) ->
    put(erlmark_unclosed, true),
    {[], []};
fence_lines([L | Rest], C, Len, N) ->
    case closing_fence(L, C, Len) of
        true ->
            {[], Rest};
        false ->
            {More, Rest2} = fence_lines(Rest, C, Len, N),
            {[strip_upto(L, N), $\n | More], Rest2}
    end.

has_char(<<C, _/binary>>, C) -> true;
has_char(<<_, R/binary>>, C) -> has_char(R, C);
has_char(<<>>, _) -> false.

first_word(<<C, _/binary>>, O, N) when ?IS_SP(C) -> part(O, 0, N);
first_word(<<_, R/binary>>, O, N) -> first_word(R, O, N + 1);
first_word(<<>>, O, N) -> part(O, 0, N).

closing_fence(<<C0, _/binary>>, C, _Len) when C0 =/= $\s, C0 =/= C -> false;
closing_fence(<<$\s, $\s, $\s, $\s, _/binary>>, _, _) ->
    false;
closing_fence(L, C, Len) ->
    case indent(L) of
        {N, T} when N < 4 ->
            R = erlmark_util:run_len(T, C),
            R >= Len andalso blank(part(T, R, byte_size(T) - R));
        _ ->
            false
    end.

strip_upto(L, 0) -> L;
strip_upto(<<$\s, R/binary>>, N) -> strip_upto(R, N - 1);
strip_upto(L, _) -> L.

%%--------------------------------------------------------------------
%% Block quotes
%%--------------------------------------------------------------------

%% Container nesting is capped: beyond ?MAX_DEPTH a marker is just paragraph text.
%% Without a cap, parsing cost grows with the cube of the nesting depth (a
%% malicious input of a few MB could take minutes); real documents nest ~6 levels.
quote(Lines, Refs, D) when D >= ?MAX_DEPTH -> paragraph(Lines, Refs);
quote(Lines, Refs, D) ->
    {QLines, Rest} = quote_lines(Lines, [], false),
    {Blocks, _Gap, Refs2} = blocks(QLines, Refs, D + 1),
    {{blockquote, Blocks}, Rest, Refs2, false}.

%% InPara: is the last collected inner line part of an open paragraph?
quote_lines([], Acc, _) ->
    {lists:reverse(Acc), []};
quote_lines([L | Rest] = Lines, Acc, InPara) ->
    case quote_strip(L) of
        {ok, In} ->
            quote_lines(Rest, [In | Acc], block_state(InPara, In));
        none ->
            case InPara =:= true andalso lazy_line(L) of
                true -> quote_lines(Rest, [lazy_escape(L) | Acc], true);
                false -> {lists:reverse(Acc), Lines}
            end
    end.

%% `> ` followed by a blank or tab may hide a tab that must be expanded against its column: slow path.
quote_strip(<<$>, $\s, C, _/binary>> = L) when C =:= $\s; C =:= $\t -> quote_strip_slow(L);
quote_strip(<<$>, $\s, R/binary>>) -> {ok, R};
quote_strip(L) -> quote_strip_slow(L).

quote_strip_slow(L) ->
    case indent(L) of
        {N, <<$>, R/binary>>} when N < 4 ->
            case R of
                %% the optional space, then blanks that may include a tab: expand them against
                %% their real column (N + 2) so that `> \t*` means the same as `>   *`
                <<$\s, R2/binary>> -> {ok, expand_from(R2, N + 2)};
                <<$\t, _/binary>> -> {ok, tab_after_marker(R, N + 1)};
                _ -> {ok, R}
            end;
        _ ->
            none
    end.

%% The leading blanks of R, which starts at column Col, with any tab expanded to the next tab stop.
expand_from(<<C, _/binary>> = R, Col) when C =:= $\s; C =:= $\t ->
    case has_lead_tab(R) of
        true ->
            {End, Rest} = lead(R, Col),
            <<(spaces(End - Col))/binary, Rest/binary>>;
        false ->
            R
    end;
expand_from(R, _) ->
    R.

%% A tab right after a marker: expand it to the next tab stop, then give one
%% column to the optional space after the marker.
tab_after_marker(R, Col) ->
    {End, Rest} = lead(R, Col),
    <<(binary:copy(<<" ">>, End - Col - 1))/binary, Rest/binary>>.

%% What the last inner line of a container leaves open: `true` (a paragraph, so the next
%% unprefixed line may continue it lazily), `false` (nothing that can continue lazily),
%% `{fence, Char, Len}` (inside fenced code) or `{html, Type}` (inside an HTML block).
block_state(St, L) when is_tuple(St) -> inside_block(St, L);
block_state(St, L) -> plain_state(St, L).

%% St is `true` or `false` here.
plain_state(_, <<C, _/binary>>) when ?IS_LETTER(C); C >= 128 -> true;
%% `- text`, `* text`, `+ text`: a bullet with text on the same line keeps a paragraph open.
plain_state(_, <<M, $\s, C, _/binary>>) when
    (M =:= $- orelse M =:= $* orelse M =:= $+) andalso (?IS_LETTER(C) orelse C >= 128)
->
    true;
plain_state(St, <<$>, $\s, R/binary>>) ->
    plain_state(St, R);
plain_state(St, L) ->
    case indent(L) of
        {_, <<>>} ->
            false;
        {_, <<$\t, _/binary>> = T0} ->
            not erlmark_util:is_blank(T0) andalso St =:= true;
        {N, _} when N >= 4 ->
            St =:= true;
        {_, T} ->
            case fence_open(T) of
                {Ch, Len, _} ->
                    {fence, Ch, Len};
                none ->
                    case atx(T) =/= none orelse thematic(T) of
                        true -> false;
                        false -> start_state(St, T, L)
                    end
            end
    end.

%% Inside fenced code or an HTML block: only its end matters.
inside_block({fence, Ch, Len} = St, L) ->
    case closing_fence(L, Ch, Len) of
        true -> false;
        false -> St
    end;
inside_block({html, Type} = St, L) when Type =< 5 ->
    case html_ends(Type, L) of
        true -> false;
        false -> St
    end;
inside_block({html, _} = St, L) ->
    case blank(L) of
        true -> false;
        false -> St
    end.

%% A line that is neither a fence, a heading nor a thematic break.
start_state(St, <<$<, _/binary>> = T, L) ->
    case html_start(T) of
        none ->
            true;
        7 when St =:= true ->
            true;
        Type when Type =< 5 ->
            case html_ends(Type, L) of
                true -> false;
                false -> {html, Type}
            end;
        Type ->
            {html, Type}
    end;
start_state(_, <<$>, R/binary>>, _) ->
    case R of
        <<$\s, R2/binary>> -> block_state(false, R2);
        _ -> block_state(false, R)
    end;
start_state(_, <<C, _/binary>> = T, _) when C =:= $-; C =:= $*; C =:= $+; C >= $0, C =< $9 ->
    case list_marker(T) of
        {_, MLen, After, _} ->
            {_, Content} = item_start(0, MLen, After),
            block_state(false, Content);
        _ ->
            true
    end;
start_state(_, _, _) ->
    true.

%% May this un-prefixed line continue the paragraph lazily?
lazy_line(L) ->
    not blank(L) andalso
        case indent(L) of
            {N, _} when N >= 4 -> true;
            {_, <<$\t, _/binary>> = T0} -> not erlmark_util:is_blank(T0);
            {_, T} -> not interrupts(T)
        end.

%% A lazy continuation line is paragraph text even if it looks like a setext
%% underline, so neutralise it with a backslash escape.
lazy_escape(L) ->
    {N, T} = indent(L),
    case setext(T) of
        none -> L;
        _ -> <<(binary:copy(<<" ">>, N))/binary, $\\, T/binary>>
    end.

%%--------------------------------------------------------------------
%% Interruption of paragraphs
%%--------------------------------------------------------------------

interrupts(<<>>) ->
    false;
interrupts(<<C, _/binary>> = T) ->
    case C of
        $# ->
            atx(T) =/= none;
        $> ->
            true;
        $` ->
            fence_open(T) =/= none;
        $~ ->
            fence_open(T) =/= none;
        $- ->
            thematic(T) orelse bullet_nonempty(T);
        $* ->
            thematic(T) orelse bullet_nonempty(T);
        $_ ->
            thematic(T);
        $+ ->
            bullet_nonempty(T);
        $< ->
            case html_start(T) of
                none -> false;
                7 -> false;
                _ -> true
            end;
        D when ?IS_DIGIT(D) ->
            case list_marker(T) of
                {{ordered, _}, _, After, Num} ->
                    binary_to_integer(Num) =:= 1 andalso not blank(After);
                _ ->
                    false
            end;
        _ ->
            false
    end.

bullet_nonempty(T) ->
    case list_marker(T) of
        {{bullet, _}, 1, After, _} -> not blank(After);
        _ -> false
    end.

%%--------------------------------------------------------------------
%% Paragraphs, setext headings, tables, reference definitions
%%--------------------------------------------------------------------

paragraph([First | Rest], Refs) ->
    case table_start(First, Rest) of
        {ok, Aligns, Head, Rest2} -> table(Aligns, Head, Rest2, Refs);
        none -> para_collect(Rest, [First], Refs)
    end.

-define(PARA_CONT,
    {false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, true, true, false, true, true, true, true,
        true, true, false, false, true, false, true, true, false, false, false, false, false, false,
        false, false, false, false, true, true, false, false, false, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, false, false, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, false, false,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true}
).

para_collect([], Acc, Refs) ->
    finish_para(Acc, [], Refs);
%% A line starting with a letter (or a non-ASCII byte) can be none of: blank,
%% setext underline, or a paragraph interruption, so it just continues.
para_collect([<<C, _/binary>> = L | Rest], Acc, Refs) when ?IS_LETTER(C); C >= 128 ->
    para_collect(Rest, [L | Acc], Refs);
%% `- x` / `* x` / `+ x` (x neither the marker nor a blank): a non-empty bullet item,
%% which interrupts the paragraph; not a setext underline, not a thematic break.
para_collect([<<M, $\s, X, _/binary>> | _] = Lines, Acc, Refs) when
    (M =:= $- orelse M =:= $* orelse M =:= $+), X =/= M, X =/= $\s, X =/= $\t
->
    finish_para(Acc, Lines, Refs);
%% Any other first byte that is not blank, a setext underline (= -) or the start of a
%% paragraph interruption (# > ` ~ * _ + < and digits) continues the paragraph too.
para_collect([<<C, _/binary>> = L | Rest], Acc, Refs) when element(C + 1, ?PARA_CONT) ->
    para_collect(Rest, [L | Acc], Refs);
para_collect([L | Rest] = Lines, Acc, Refs) ->
    case indent(L) of
        {_, <<>>} ->
            finish_para(Acc, Lines, Refs);
        {_, <<$\t, _/binary>> = T0} ->
            case erlmark_util:is_blank(T0) of
                true -> finish_para(Acc, Lines, Refs);
                false -> para_collect(Rest, [L | Acc], Refs)
            end;
        {N, T} when N < 4 ->
            case setext(T) of
                {ok, Level} ->
                    finish_setext(Acc, Level, L, Rest, Refs);
                none ->
                    case interrupts(T) of
                        true -> finish_para(Acc, Lines, Refs);
                        false -> para_collect(Rest, [L | Acc], Refs)
                    end
            end;
        _ ->
            para_collect(Rest, [L | Acc], Refs)
    end.

join_para([L]) ->
    erlmark_util:rtrim(erlmark_util:ltrim(L));
join_para(AccRev) ->
    %% AccRev holds the lines last-first, so folding it builds the iolist in
    %% order in one pass (no reverse, no join, no intermediate list).
    erlmark_util:rtrim(iolist_to_binary(join_lines(AccRev, []))).

join_lines([L], Out) -> [erlmark_util:ltrim(L) | Out];
join_lines([L | Rest], Out) -> join_lines(Rest, [$\n, erlmark_util:ltrim(L) | Out]).

finish_para(Acc, Rest, Refs) ->
    {Text, Refs2} = extract_refs(join_para(Acc), Refs),
    case Text of
        <<>> -> {skip, Rest, Refs2, false};
        _ -> {{paragraph, Text}, Rest, Refs2, false}
    end.

finish_setext(Acc, Level, Underline, Rest, Refs) ->
    {Text, Refs2} = extract_refs(join_para(Acc), Refs),
    case Text of
        %% Only reference definitions: the "underline" is ordinary paragraph text.
        <<>> -> {skip, [Underline | Rest], Refs2, false};
        _ -> {{heading, Level, Text}, Rest, Refs2, false}
    end.

%% --- link reference definitions -------------------------------------

extract_refs(<<$[, _/binary>> = T, Refs) ->
    case ref_def(T) of
        {ok, Label, Url, Title, Rest} ->
            Refs1 =
                case maps:is_key(Label, Refs) of
                    true -> Refs;
                    false -> Refs#{Label => {Url, Title}}
                end,
            extract_refs(Rest, Refs1);
        none ->
            {T, Refs}
    end;
extract_refs(T, Refs) ->
    {T, Refs}.

ref_def(<<$[, R/binary>>) ->
    case erlmark_util:label_len(R) of
        {ok, N} ->
            <<Label:N/binary, $], After/binary>> = R,
            %% Only a label followed by `:` can be a definition: test that before the
            %% (comparatively costly) label normalisation.
            case After of
                <<$:, After2/binary>> ->
                    case erlmark_util:norm_label(Label) of
                        <<>> -> none;
                        NL -> ref_def2(NL, After2)
                    end;
                _ ->
                    none
            end;
        none ->
            none
    end.

ref_def2(Label, B) ->
    {B1, _} = erlmark_util:skip_ws(B),
    case erlmark_util:parse_dest(B1) of
        {ok, Url, Rest} when Url =/= <<>>; binary_part(B1, 0, 2) =:= <<"<>">> ->
            ref_title(Label, Url, Rest);
        _ ->
            none
    end.

ref_title(Label, Url, Rest) ->
    {R1, NL} = erlmark_util:skip_ws(Rest),
    WsConsumed = byte_size(R1) =/= byte_size(Rest),
    case WsConsumed andalso erlmark_util:parse_title(R1) of
        {ok, Title, R2} ->
            case rest_of_line(R2) of
                {ok, R3} -> {ok, Label, Url, Title, R3};
                none when NL -> no_title(Label, Url, Rest);
                none -> none
            end;
        _ ->
            no_title(Label, Url, Rest)
    end.

no_title(Label, Url, Rest) ->
    case rest_of_line(Rest) of
        {ok, R} -> {ok, Label, Url, none, R};
        none -> none
    end.

%% Succeeds when only whitespace remains on the current line.
rest_of_line(B) ->
    case erlmark_util:ltrim(B) of
        <<>> -> {ok, <<>>};
        <<$\n, R/binary>> -> {ok, R};
        _ -> none
    end.

%% --- GFM tables -------------------------------------------------------

table_start(Header, [Delim | Rest]) ->
    %% Cheap O(1) test first: a delimiter row starts with '|', '-' or ':'
    %% (after at most three spaces). Only then scan the header for a '|'.
    case delim_candidate(Delim) of
        false ->
            none;
        true ->
            case has_char(Header, $|) of
                false ->
                    none;
                true ->
                    case delim_row(Delim) of
                        {ok, Aligns} ->
                            Head = split_row(Header),
                            case length(Head) =:= length(Aligns) of
                                true -> {ok, Aligns, Head, Rest};
                                false -> none
                            end;
                        none ->
                            none
                    end
            end
    end;
table_start(_, _) ->
    none.

%% A delimiter row consists only of '|', '-', ':' and blanks (and has a '-').
%% Failing fast on the first other byte keeps ordinary text lines cheap.
delim_candidate(L) -> delim_candidate(L, false).

delim_candidate(<<$-, R/binary>>, _) ->
    delim_candidate(R, true);
delim_candidate(<<C, R/binary>>, D) when C =:= $|; C =:= $:; C =:= $\s; C =:= $\t ->
    delim_candidate(R, D);
delim_candidate(<<>>, D) ->
    D;
delim_candidate(_, _) ->
    false.

delim_row(Line) ->
    %% Tabs count as columns: a delimiter row indented four columns or more is not a table row.
    case indent(expand_tabs(Line)) of
        {N, T} when N < 4, T =/= <<>> ->
            Cells = split_row(T),
            Aligns = [cell_align(C) || C <- Cells],
            case Cells =/= [] andalso not lists:member(none_invalid, Aligns) of
                true -> {ok, Aligns};
                false -> none
            end;
        _ ->
            none
    end.

cell_align(C) ->
    case C of
        <<$:, R/binary>> ->
            case dashes(R) of
                {ok, <<$:>>} -> center;
                {ok, <<>>} -> left;
                _ -> none_invalid
            end;
        _ ->
            case dashes(C) of
                {ok, <<$:>>} -> right;
                {ok, <<>>} -> none;
                _ -> none_invalid
            end
    end.

dashes(<<$-, R/binary>>) -> dashes_more(R);
dashes(_) -> error.
dashes_more(<<$-, R/binary>>) -> dashes_more(R);
dashes_more(R) -> {ok, R}.

split_row(Line) ->
    T0 = erlmark_util:trim(Line),
    T1 =
        case T0 of
            <<$|, R/binary>> -> R;
            _ -> T0
        end,
    T2 =
        case T1 of
            <<>> ->
                T1;
            _ ->
                Sz = byte_size(T1),
                case binary:last(T1) =:= $| andalso not escaped_at(T1, Sz - 1) of
                    true -> part(T1, 0, Sz - 1);
                    false -> T1
                end
        end,
    {Cells, Esc} = sc(T2, T2, 0, 0, [], false),
    [cell(C, Esc) || C <- Cells].

cell(C, false) -> erlmark_util:trim(C);
cell(C, true) -> unpipe(erlmark_util:trim(C)).

%% `\|` -> `|` in a table cell: one pass, unchanged runs copied as slices.
unpipe(B) -> unp(B, B, 0, 0, []).

unp(<<$\\, $|, R/binary>>, O, S, L, A) ->
    unp(R, O, S + L + 2, 0, [$| | unp_fl(O, S, L, A)]);
unp(<<_, R/binary>>, O, S, L, A) ->
    unp(R, O, S, L + 1, A);
unp(<<>>, O, 0, _, []) ->
    O;
unp(<<>>, O, S, L, A) ->
    iolist_to_binary(lists:reverse(unp_fl(O, S, L, A))).

unp_fl(_, _, 0, A) -> A;
unp_fl(O, S, L, A) -> [part(O, S, L) | A].

escaped_at(B, Pos) when Pos > 0 -> binary:at(B, Pos - 1) =:= $\\;
escaped_at(_, _) -> false.

sc(<<A1, B1, C1, D1, R/binary>>, O, S, L, A, E) when
    element(A1 + 1, ?SC_TAB),
    element(B1 + 1, ?SC_TAB),
    element(C1 + 1, ?SC_TAB),
    element(D1 + 1, ?SC_TAB)
->
    sc(R, O, S, L + 4, A, E);
sc(<<$\\, $|, R/binary>>, O, S, L, A, _) ->
    sc(R, O, S, L + 2, A, true);
sc(<<$|, R/binary>>, O, S, L, A, E) ->
    sc(R, O, S + L + 1, 0, [part(O, S, L) | A], E);
sc(<<_, R/binary>>, O, S, L, A, E) ->
    sc(R, O, S, L + 1, A, E);
sc(<<>>, O, S, L, A, E) ->
    {lists:reverse([part(O, S, L) | A]), E}.

table(Aligns, Head, Lines, Refs) ->
    {Rows, Rest} = table_rows(Lines, length(Head), []),
    {{table, Aligns, Head, Rows}, Rest, Refs, false}.

table_rows([L | Rest] = Lines, N, Acc) ->
    case indent(L) of
        {_, <<>>} ->
            {lists:reverse(Acc), Lines};
        {_, <<$\t, _/binary>> = T0} ->
            case erlmark_util:is_blank(T0) of
                true -> {lists:reverse(Acc), Lines};
                false -> table_rows(Rest, N, [fit_row(split_row(L), N) | Acc])
            end;
        {M, T} when M < 4 ->
            case interrupts(T) of
                true -> {lists:reverse(Acc), Lines};
                false -> table_rows(Rest, N, [fit_row(split_row(L), N) | Acc])
            end;
        _ ->
            table_rows(Rest, N, [fit_row(split_row(L), N) | Acc])
    end;
table_rows([], _, Acc) ->
    {lists:reverse(Acc), []}.

fit_row(Cells, N) ->
    Len = length(Cells),
    if
        Len =:= N -> Cells;
        Len > N -> lists:sublist(Cells, N);
        true -> Cells ++ lists:duplicate(N - Len, <<>>)
    end.

%%--------------------------------------------------------------------
%% Lists
%%--------------------------------------------------------------------

%% -> {Kind, MarkerLen, AfterMarker, StartNumber} | none
list_marker(<<C, R/binary>>) when C =:= $-; C =:= $+; C =:= $* ->
    case marker_end(R) of
        true -> {{bullet, C}, 1, R, 0};
        false -> none
    end;
list_marker(<<C, _/binary>> = T) when ?IS_DIGIT(C) ->
    D = digit_run(T, 0),
    if
        D =< 9 ->
            case T of
                <<Num:D/binary, Delim, R/binary>> when Delim =:= $.; Delim =:= $) ->
                    case marker_end(R) of
                        true -> {{ordered, Delim}, D + 1, R, Num};
                        false -> none
                    end;
                _ ->
                    none
            end;
        true ->
            none
    end;
list_marker(_) ->
    none.

digit_run(<<C, R/binary>>, N) when ?IS_DIGIT(C) -> digit_run(R, N + 1);
digit_run(_, N) -> N.

marker_end(<<>>) -> true;
marker_end(<<C, _/binary>>) when ?IS_SP(C) -> true;
marker_end(_) -> false.

thematic_or_list(T, [_ | Rest] = Lines, Refs, D) ->
    case thematic(T) of
        true -> {thematic, Rest, Refs, false};
        false -> list_or_para(T, Lines, Refs, D)
    end.

list_or_para(_T, Lines, Refs, D) when D >= ?MAX_DEPTH -> paragraph(Lines, Refs);
list_or_para(T, Lines, Refs, D) ->
    case list_marker(T) of
        none ->
            paragraph(Lines, Refs);
        {Kind, _, _, StartRaw} ->
            Start =
                case Kind of
                    {ordered, _} -> binary_to_integer(StartRaw);
                    _ -> 0
                end,
            {Items, Rest, Refs2, Loose, Trail} = list_items(Lines, Refs, D, Kind, [], false, false),
            Tight = not (Loose orelse loose_items(Items)),
            Type =
                case Kind of
                    {bullet, _} -> bullet;
                    {ordered, _} -> {ordered, Start}
                end,
            {{list, Type, Tight, [I || {I, _} <- Items]}, Rest, Refs2, Trail}
    end.

loose_items([{_, true} | _]) -> true;
loose_items([{_, trail} | [_ | _]]) -> true;
loose_items([_ | T]) -> loose_items(T);
loose_items([]) -> false.

list_items([], Refs, _D, _Kind, Items, Loose, Blank) ->
    {lists:reverse(Items), [], Refs, Loose, Blank};
list_items([L | Rest] = Lines, Refs, D, Kind, Items, Loose, BlankBefore) ->
    case next_item(L, Kind) of
        {N, MLen, After} ->
            {W, First} = item_start(N, MLen, After),
            {ItemLines, Rest2, BlankAfter} = item_lines(Rest, W, First),
            {Blocks0, Gap, Refs2} = item_blocks(ItemLines, Refs, D + 1),
            {Task, Blocks} = task(Blocks0),
            Loose1 = Loose orelse (BlankBefore andalso Items =/= []),
            list_items(
                Rest2, Refs2, D, Kind, [{{item, Task, Blocks}, Gap} | Items], Loose1, BlankAfter
            );
        none ->
            {lists:reverse(Items), Lines, Refs, Loose, BlankBefore}
    end.

%% Fast path: a one-line item whose text starts with a letter or a non-ASCII
%% byte cannot open any other block, so it is simply a paragraph.
item_blocks([<<C, _/binary>> = L], Refs, _D) when ?IS_LETTER(C); C >= 128 ->
    {[{paragraph, erlmark_util:rtrim(L)}], false, Refs};
%% Several lines: a letter-first first line followed only by lines whose first byte can
%% neither end a paragraph nor underline it (see ?PARA_CONT) is one plain paragraph.
item_blocks([<<C, _/binary>> | [_ | _] = Conts] = Lines, Refs, D) when ?IS_LETTER(C); C >= 128 ->
    case all_cont(Conts) of
        true -> {[{paragraph, erlmark_util:rtrim(iolist_to_binary(join_nl(Lines)))}], false, Refs};
        false -> blocks(Lines, Refs, D)
    end;
item_blocks(Lines, Refs, D) ->
    blocks(Lines, Refs, D).

all_cont([<<C, _/binary>> | T]) when element(C + 1, ?PARA_CONT) -> all_cont(T);
all_cont([]) -> true;
all_cont(_) -> false.

join_nl([L]) -> [L];
join_nl([L | T]) -> [L, $\n | join_nl(T)].

%% `- text` at column 0 of a list with the same bullet: the byte after the space is
%% neither the marker nor a blank, so the line is not a thematic break and the marker
%% is a list marker. Skips the indentation scan and the thematic / marker tests.
next_item(<<M, $\s, X, _/binary>> = L, {bullet, M}) when
    (M =:= $- orelse M =:= $* orelse M =:= $+), X =/= M, X =/= $\s, X =/= $\t
->
    <<_, After/binary>> = L,
    {0, 1, After};
next_item(L, Kind) ->
    case indent(L) of
        {N, T} when N < 4 ->
            case thematic(T) of
                true ->
                    none;
                false ->
                    case list_marker(T) of
                        {Kind, MLen, After, _} -> {N, MLen, After};
                        _ -> none
                    end
            end;
        _ ->
            none
    end.

item_start(N, MLen, <<$\s, C, _/binary>> = After) when C =/= $\s, C =/= $\t ->
    %% Common case: exactly one space after the marker.
    <<_, Content/binary>> = After,
    {N + MLen + 1, Content};
item_start(N, MLen, After) ->
    {Sp, Content} =
        case has_lead_tab(After) of
            true ->
                {End, Rest} = lead(After, N + MLen),
                {End - (N + MLen), Rest};
            false ->
                indent(After)
        end,
    case Content of
        <<>> -> {N + MLen + 1, <<>>};
        _ when Sp >= 5 -> {N + MLen + 1, <<(binary:copy(<<" ">>, Sp - 1))/binary, Content/binary>>};
        _ -> {N + MLen + Sp, Content}
    end.

item_lines(Lines, W, First) ->
    case no_tabs() of
        true -> item_fast(Lines, W, [First], 0);
        false -> item_lines(Lines, W, [First], 0)
    end.

%% Does the document being parsed contain no tab at all? (Computed on first use, then cached.)
no_tabs() ->
    case get(erlmark_notab) of
        undefined ->
            NT =
                case get(erlmark_src) of
                    undefined -> false;
                    Src -> binary:match(Src, <<"\t">>) =:= nomatch
                end,
            put(erlmark_notab, NT),
            NT;
        NT ->
            NT
    end.

%% Tab-free document, content column W of 2, 3 or 4: a continuation line that starts with exactly
%% those spaces and ends in a non-blank byte is non-blank and indented by at least W, so it is
%% stripped directly; an empty line is counted (the blank lines are put back before the next
%% content line, as the general scanner does). Anything else (blank lines with spaces, trailing
%% blanks, other columns, a line that ends the item) goes to the general scanner.
item_fast([<<"  ", _/binary>> = L | Rest], 2, Acc, Bl) ->
    case nonblank_end(L) of
        true ->
            <<_:2/binary, R/binary>> = L,
            item_fast(Rest, 2, push(R, Acc, Bl), 0);
        false ->
            item_lines([L | Rest], 2, Acc, Bl)
    end;
item_fast([<<"   ", _/binary>> = L | Rest], 3, Acc, Bl) ->
    case nonblank_end(L) of
        true ->
            <<_:3/binary, R/binary>> = L,
            item_fast(Rest, 3, push(R, Acc, Bl), 0);
        false ->
            item_lines([L | Rest], 3, Acc, Bl)
    end;
item_fast([<<"    ", _/binary>> = L | Rest], 4, Acc, Bl) ->
    case nonblank_end(L) of
        true ->
            <<_:4/binary, R/binary>> = L,
            item_fast(Rest, 4, push(R, Acc, Bl), 0);
        false ->
            item_lines([L | Rest], 4, Acc, Bl)
    end;
%% An item may start with one blank line only (handled by the general scanner).
item_fast([<<>> | Rest], W, Acc, Bl) when Acc =/= [<<>>], (W =:= 2 orelse W =:= 3 orelse W =:= 4) ->
    item_fast(Rest, W, Acc, Bl + 1);
item_fast(Lines, W, Acc, Bl) ->
    item_lines(Lines, W, Acc, Bl).

push(R, Acc, 0) -> [R | Acc];
push(R, Acc, Bl) -> [R | lists:duplicate(Bl, <<>>) ++ Acc].

%% The last byte is not a blank (so the line is not blank).
nonblank_end(L) ->
    case L of
        <<_:(byte_size(L) - 1)/binary, X>> when X =/= $\s, X =/= $\t -> true;
        _ -> false
    end.

item_lines([], _W, Acc, Blanks) ->
    {lists:reverse(Acc), [], Blanks > 0};
%% A bullet marker at column 0 ends the item (W >= 2): it is a list marker, so the
%% line cannot be a lazy continuation either.
item_lines([<<M, $\s, X, _/binary>> | _] = Lines, _W, Acc, Blanks) when
    (M =:= $- orelse M =:= $* orelse M =:= $+), X =/= M, X =/= $\s, X =/= $\t
->
    {lists:reverse(Acc), Lines, Blanks > 0};
%% One tab (4 columns) or two (8) then a non-blank byte, inside an item whose content
%% column W is at most that wide: strip W columns directly (the rest of the tab stays as
%% spaces), without expanding the whole line first.
item_lines([<<$\t, C, _/binary>> = L | Rest], W, Acc, 0) when W =< 4, C =/= $\s, C =/= $\t ->
    <<_, R/binary>> = L,
    item_lines(Rest, W, [tab1(W, R) | Acc], 0);
item_lines([<<$\t, $\t, C, _/binary>> = L | Rest], W, Acc, 0) when W =< 8, C =/= $\s, C =/= $\t ->
    <<_, _, R/binary>> = L,
    item_lines(Rest, W, [tab2(W, R) | Acc], 0);
item_lines([L | Rest] = Lines, W, Acc, Blanks) ->
    case indent(L) of
        {N0, <<$\t, C, R0/binary>>} when
            N0 =< 11,
            C =/= $\s,
            C =/= $\t,
            N0 + 4 - (N0 rem 4) >= W
        ->
            %% N0 spaces then one tab reach the next tab stop: Cols columns of leading blanks.
            Cols = N0 + 4 - (N0 rem 4),
            Line = <<(spaces(Cols - W))/binary, C, R0/binary>>,
            case Blanks of
                0 -> item_lines(Rest, W, [Line | Acc], 0);
                _ -> item_lines(Rest, W, [Line | lists:duplicate(Blanks, <<>>) ++ Acc], 0)
            end;
        {_, <<$\t, _/binary>>} ->
            item_lines([expand_tabs(L) | Rest], W, Acc, Blanks);
        {_, <<>>} ->
            case Acc of
                %% An item may start with at most one blank line: it is empty,
                %% and the blank lines that follow separate it from the next item.
                [<<>>] -> {[<<>>], skip_blank_lines(Rest), true};
                _ -> item_lines(Rest, W, Acc, Blanks + 1)
            end;
        {N, _} when N >= W, Blanks =:= 0 ->
            item_lines(Rest, W, [strip_cols(L, W) | Acc], 0);
        {N, _} when N >= W ->
            Acc1 = lists:duplicate(Blanks, <<>>) ++ Acc,
            item_lines(Rest, W, [strip_cols(L, W) | Acc1], 0);
        {N, T} ->
            case Blanks =:= 0 andalso lazy_item(Acc, N, T, L) of
                true -> item_lines_lazy(Rest, W, [lazy_escape(L) | Acc]);
                false -> {lists:reverse(Acc), Lines, Blanks > 0}
            end
    end.

item_lines_lazy(Rest, W, Acc) ->
    put(erlmark_lazy, Acc),
    item_lines(Rest, W, Acc, 0).

%% The rest of a line after one / two leading tabs, with the part of the tab columns
%% beyond the item's content column W (<= 4 / <= 8) kept as spaces.
tab1(2, R) -> <<"  ", R/binary>>;
tab1(3, R) -> <<" ", R/binary>>;
tab1(4, R) -> R;
tab1(W, R) -> <<(spaces(4 - W))/binary, R/binary>>.

tab2(2, R) -> <<"      ", R/binary>>;
tab2(3, R) -> <<"     ", R/binary>>;
tab2(4, R) -> <<"    ", R/binary>>;
tab2(W, R) -> <<(spaces(8 - W))/binary, R/binary>>.

skip_blank_lines([L | Rest] = Lines) ->
    case blank(L) of
        true -> skip_blank_lines(Rest);
        false -> Lines
    end;
skip_blank_lines([]) ->
    [].

%% Lines indented four or more spaces cannot start a block here, so they just
%% continue an open paragraph; otherwise cheap, usually-decisive tests first.
lazy_item(Acc, N, T, L) ->
    not blank(L) andalso (N >= 4 orelse (list_marker(T) =:= none andalso not interrupts(T))) andalso
        acc_state(Acc) =:= true.

%% The state (see block_state/2) after the item lines collected so far, which are held newest
%% first. The result of a lazy continuation is remembered, so a run of lazy lines is not
%% rescanned from the start each time.
acc_state(Acc) ->
    case get(erlmark_lazy) of
        Acc ->
            true;
        _ ->
            lists:foldl(fun(L, St) -> block_state(St, L) end, false, lists:reverse(Acc))
    end.

task([{paragraph, <<"[ ] ", R/binary>>} | T]) -> {unchecked, [{paragraph, R} | T]};
task([{paragraph, <<"[x] ", R/binary>>} | T]) -> {checked, [{paragraph, R} | T]};
task([{paragraph, <<"[X] ", R/binary>>} | T]) -> {checked, [{paragraph, R} | T]};
task(B) -> {none, B}.

%%--------------------------------------------------------------------
%% HTML blocks
%%--------------------------------------------------------------------

-define(BLOCK_TAGS, [
    <<"address">>,
    <<"article">>,
    <<"aside">>,
    <<"base">>,
    <<"basefont">>,
    <<"blockquote">>,
    <<"body">>,
    <<"caption">>,
    <<"center">>,
    <<"col">>,
    <<"colgroup">>,
    <<"dd">>,
    <<"details">>,
    <<"dialog">>,
    <<"dir">>,
    <<"div">>,
    <<"dl">>,
    <<"dt">>,
    <<"fieldset">>,
    <<"figcaption">>,
    <<"figure">>,
    <<"footer">>,
    <<"form">>,
    <<"frame">>,
    <<"frameset">>,
    <<"h1">>,
    <<"h2">>,
    <<"h3">>,
    <<"h4">>,
    <<"h5">>,
    <<"h6">>,
    <<"head">>,
    <<"header">>,
    <<"hr">>,
    <<"html">>,
    <<"iframe">>,
    <<"legend">>,
    <<"li">>,
    <<"link">>,
    <<"main">>,
    <<"menu">>,
    <<"menuitem">>,
    <<"nav">>,
    <<"noframes">>,
    <<"ol">>,
    <<"optgroup">>,
    <<"option">>,
    <<"p">>,
    <<"param">>,
    <<"search">>,
    <<"section">>,
    <<"summary">>,
    <<"table">>,
    <<"tbody">>,
    <<"td">>,
    <<"tfoot">>,
    <<"th">>,
    <<"thead">>,
    <<"title">>,
    <<"tr">>,
    <<"track">>,
    <<"ul">>
]).

%% Block-level tag names as a literal map: one hash probe instead of a linear scan.
block_tags() ->
    #{
        <<"address">> => true,
        <<"article">> => true,
        <<"aside">> => true,
        <<"base">> => true,
        <<"basefont">> => true,
        <<"blockquote">> => true,
        <<"body">> => true,
        <<"caption">> => true,
        <<"center">> => true,
        <<"col">> => true,
        <<"colgroup">> => true,
        <<"dd">> => true,
        <<"details">> => true,
        <<"dialog">> => true,
        <<"dir">> => true,
        <<"div">> => true,
        <<"dl">> => true,
        <<"dt">> => true,
        <<"fieldset">> => true,
        <<"figcaption">> => true,
        <<"figure">> => true,
        <<"footer">> => true,
        <<"form">> => true,
        <<"frame">> => true,
        <<"frameset">> => true,
        <<"h1">> => true,
        <<"h2">> => true,
        <<"h3">> => true,
        <<"h4">> => true,
        <<"h5">> => true,
        <<"h6">> => true,
        <<"head">> => true,
        <<"header">> => true,
        <<"hr">> => true,
        <<"html">> => true,
        <<"iframe">> => true,
        <<"legend">> => true,
        <<"li">> => true,
        <<"link">> => true,
        <<"main">> => true,
        <<"menu">> => true,
        <<"menuitem">> => true,
        <<"nav">> => true,
        <<"noframes">> => true,
        <<"ol">> => true,
        <<"optgroup">> => true,
        <<"option">> => true,
        <<"p">> => true,
        <<"param">> => true,
        <<"search">> => true,
        <<"section">> => true,
        <<"summary">> => true,
        <<"table">> => true,
        <<"tbody">> => true,
        <<"td">> => true,
        <<"tfoot">> => true,
        <<"th">> => true,
        <<"thead">> => true,
        <<"title">> => true,
        <<"tr">> => true,
        <<"track">> => true,
        <<"ul">> => true
    }.

html_start(<<$<, R/binary>>) ->
    case R of
        <<"!--", _/binary>> ->
            2;
        <<"?", _/binary>> ->
            3;
        <<"![CDATA[", _/binary>> ->
            5;
        <<$!, C, _/binary>> when ?IS_LETTER(C) -> 4;
        _ ->
            {Closing, R1} =
                case R of
                    <<$/, X/binary>> -> {true, X};
                    _ -> {false, R}
                end,
            N = alnum_len(R1, 0),
            Name0 = part(R1, 0, N),
            After = part(R1, N, byte_size(R1) - N),
            Boundary =
                case After of
                    <<>> -> true;
                    <<C, _/binary>> when ?IS_WS(C); C =:= $> -> true;
                    <<"/>", _/binary>> -> true;
                    _ -> false
                end,
            if
                N =:= 0 ->
                    none;
                %% Tag names are almost always lowercase: match them as they are and
                %% only lowercase a copy when the name has an uppercase letter.
                Boundary ->
                    Name =
                        case has_upper(Name0) of
                            false -> Name0;
                            true -> <<<<(ascii_lower(Ch))>> || <<Ch>> <= Name0>>
                        end,
                    if
                        not Closing andalso
                            (Name =:= <<"script">> orelse Name =:= <<"pre">> orelse
                                Name =:= <<"style">> orelse Name =:= <<"textarea">>) ->
                            1;
                        true ->
                            case maps:is_key(Name, block_tags()) of
                                true -> 6;
                                false -> html7(<<$<, R/binary>>)
                            end
                    end;
                true ->
                    html7(<<$<, R/binary>>)
            end
    end.

has_upper(<<C, _/binary>>) when C >= $A, C =< $Z -> true;
has_upper(<<_, R/binary>>) -> has_upper(R);
has_upper(<<>>) -> false.

alnum_len(<<C, R/binary>>, N) when ?IS_ALNUM(C) -> alnum_len(R, N + 1);
alnum_len(_, N) -> N.

html7(<<$<, R/binary>> = T) ->
    case erlmark_util:html_tag_len(R) of
        {ok, L} ->
            Rest = part(T, L + 1, byte_size(T) - L - 1),
            case blank(Rest) andalso complete_tag(R) of
                true -> 7;
                false -> none
            end;
        none ->
            none
    end.

%% Type 7 only allows open/closing tags, not comments/PIs/declarations.
complete_tag(<<C, _/binary>>) when ?IS_LETTER(C); C =:= $/ -> true;
complete_tag(_) -> false.

html_block(Type, [L | Rest] = Lines, Refs) ->
    case Type of
        T when T =< 5 ->
            {Collected, Rest2} = html_until(T, Lines, []),
            {{html, join_html(Collected)}, Rest2, Refs, false};
        _ ->
            {Collected, Rest2} = html_blank(Rest, [L]),
            {{html, join_html(Collected)}, Rest2, Refs, false}
    end.

html_until(_, [], Acc) ->
    put(erlmark_unclosed, true),
    {lists:reverse(Acc), []};
html_until(T, [L | Rest], Acc) ->
    case html_ends(T, L) of
        true -> {lists:reverse([L | Acc]), Rest};
        false -> html_until(T, Rest, [L | Acc])
    end.

html_ends(1, L) -> closes1(L);
html_ends(2, L) -> has_seq(L, <<"-->">>);
html_ends(3, L) -> has_seq(L, <<"?>">>);
html_ends(4, L) -> has_char(L, $>);
html_ends(5, L) -> has_seq(L, <<"]]>">>).

%% Does the line contain `</script>`, `</pre>`, `</style>` or `</textarea>` (any case)? One scan;
%% only the bytes after a `</` are examined.
closes1(<<$<, $/, R/binary>>) ->
    end_name(R) orelse closes1(R);
closes1(<<_, R/binary>>) ->
    closes1(R);
closes1(<<>>) ->
    false.

end_name(<<C, R/binary>>) ->
    case C bor 16#20 of
        $p -> ci_rest(R, <<"re>">>);
        $s -> ci_rest(R, <<"cript>">>) orelse ci_rest(R, <<"tyle>">>);
        $t -> ci_rest(R, <<"extarea>">>);
        _ -> false
    end;
end_name(<<>>) ->
    false.

ci_rest(_, <<>>) ->
    true;
ci_rest(<<C, R/binary>>, <<L, T/binary>>) ->
    case ascii_lower(C) of
        L -> ci_rest(R, T);
        _ -> false
    end;
ci_rest(<<>>, _) ->
    false.

%% Does L contain the 2- or 3-byte sequence? Direct scan, no pattern compilation.
has_seq(<<A, B, _/binary>>, <<A, B>>) -> true;
has_seq(<<A, B, C, _/binary>>, <<A, B, C>>) -> true;
has_seq(<<_, R/binary>>, Seq) -> has_seq(R, Seq);
has_seq(<<>>, _) -> false.

ascii_lower(C) when C >= $A, C =< $Z -> C + 32;
ascii_lower(C) -> C.

html_blank([], Acc) ->
    {lists:reverse(Acc), []};
html_blank([L | Rest] = Lines, Acc) ->
    case blank(L) of
        true -> {lists:reverse(Acc), Lines};
        false -> html_blank(Rest, [L | Acc])
    end.

join_html(Lines) -> iolist_to_binary(lists:join(<<"\n">>, Lines)).

%% Pattern-matching slice: same as binary:part/3 for non-negative lengths, but
%% inlined (no BIF call).
part(B, S, L) ->
    <<_:S/binary, R:L/binary, _/binary>> = B,
    R.
