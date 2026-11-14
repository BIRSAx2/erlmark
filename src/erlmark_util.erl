%% @private
%% Low-level helpers shared by the block and inline parsers.
-module(erlmark_util).
-include("erlmark.hrl").
-compile({inline, [part/3]}).

%% Bytes that certainly need no escaping: letters, digits, space, newline and
%% most punctuation (everything except & < > " and a few rare ones).
-define(ESC_OK(X), (X > 62 orelse X < 34 orelse (X > 38 andalso X < 60))).

-export([
    flag/1,
    unsafe_url/1,
    slug/1,
    could_autolink/1,
    esc/1,
    url/1,
    entity/1,
    unescape/1,
    label_len/1,
    last_cp/1,
    first_cp/1,
    unicode_ws/1,
    unicode_punct/1,
    norm_label/1,
    trim/1,
    ltrim/1,
    rtrim/1,
    run_len/2,
    skip_ws/1,
    is_blank/1,
    parse_dest/1,
    parse_title/1,
    html_tag_len/1,
    autolink/1,
    strip_tags/1
]).

%%--------------------------------------------------------------------
%% HTML escaping
%%--------------------------------------------------------------------

%% Escape & < > " . Returns the input unchanged when nothing needs escaping.
-define(ESC_TAB,
    {true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, false, true, true, true, false, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, false,
        true, false, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true}
).
-spec esc(binary()) -> iodata().
esc(Bin) -> esc(Bin, Bin, 0, 0, []).

esc(<<>>, Orig, 0, _, []) ->
    Orig;
esc(<<>>, Orig, S, L, A) ->
    lists:reverse(fl(Orig, S, L, A));
esc(<<A1, B1, C1, D1, R/binary>>, O, S, L, A) when
    element(A1 + 1, ?ESC_TAB),
    element(B1 + 1, ?ESC_TAB),
    element(C1 + 1, ?ESC_TAB),
    element(D1 + 1, ?ESC_TAB)
->
    esc(R, O, S, L + 4, A);
esc(<<$&, R/binary>>, O, S, L, A) ->
    esc(R, O, S + L + 1, 0, [<<"&amp;">> | fl(O, S, L, A)]);
esc(<<$<, R/binary>>, O, S, L, A) ->
    esc(R, O, S + L + 1, 0, [<<"&lt;">> | fl(O, S, L, A)]);
esc(<<$>, R/binary>>, O, S, L, A) ->
    esc(R, O, S + L + 1, 0, [<<"&gt;">> | fl(O, S, L, A)]);
esc(<<$", R/binary>>, O, S, L, A) ->
    esc(R, O, S + L + 1, 0, [<<"&quot;">> | fl(O, S, L, A)]);
esc(<<_, R/binary>>, O, S, L, A) ->
    esc(R, O, S, L + 1, A).

fl(_, _, 0, A) -> A;
fl(O, S, L, A) -> [part(O, S, L) | A].

%%--------------------------------------------------------------------
%% URL encoding (href / src)
%%--------------------------------------------------------------------

-define(IS_HEX(C),
    ((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F))
).

-define(URL_SAFE(C),
    (?IS_ALNUM(C) orelse C =:= $- orelse C =:= $_ orelse C =:= $. orelse C =:= $+ orelse
        C =:= $! orelse C =:= $* orelse C =:= $( orelse C =:= $) orelse C =:= $, orelse
        C =:= $# orelse C =:= $@ orelse C =:= $? orelse C =:= $= orelse
        C =:= $; orelse C =:= $: orelse C =:= $/ orelse C =:= $$ orelse C =:= $~)
).

%% Common URL bytes, tested first so the unrolled path rarely falls through.
-define(URL_FAST(X),
    ((X >= $a andalso X =< $z) orelse X =:= $/ orelse X =:= $. orelse X =:= $: orelse
        (X >= $0 andalso X =< $9) orelse X =:= $- orelse X =:= $_ orelse (X >= $A andalso X =< $Z))
).

-define(URL_TAB,
    {false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, true, false, true, true, false, false,
        false, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, false, true, false, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, false, false, false, false, true, false, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, false, false, false, true,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false}
).
-spec url(binary()) -> iodata().
url(Bin) -> url(Bin, Bin, 0, 0, []).

url(<<>>, Orig, 0, _, []) ->
    Orig;
url(<<>>, Orig, S, L, A) ->
    lists:reverse(fl(Orig, S, L, A));
url(<<A1, B1, C1, D1, R/binary>>, O, S, L, A) when
    element(A1 + 1, ?URL_TAB),
    element(B1 + 1, ?URL_TAB),
    element(C1 + 1, ?URL_TAB),
    element(D1 + 1, ?URL_TAB)
->
    url(R, O, S, L + 4, A);
url(<<$%, H1, H2, R/binary>>, O, S, L, A) when ?IS_HEX(H1), ?IS_HEX(H2) -> url(R, O, S, L + 3, A);
url(<<C, R/binary>>, O, S, L, A) when ?URL_SAFE(C) -> url(R, O, S, L + 1, A);
url(<<$&, R/binary>>, O, S, L, A) ->
    url(R, O, S + L + 1, 0, [<<"&amp;">> | fl(O, S, L, A)]);
url(<<$', R/binary>>, O, S, L, A) ->
    url(R, O, S + L + 1, 0, [<<"&#x27;">> | fl(O, S, L, A)]);
url(<<C, R/binary>>, O, S, L, A) ->
    url(R, O, S + L + 1, 0, [<<$%, (hex(C bsr 4)), (hex(C band 15))>> | fl(O, S, L, A)]).

hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + N - 10.

%%--------------------------------------------------------------------
%% Character references
%%--------------------------------------------------------------------

%% Decode a character reference. Input is the binary *after* the '&'.
%% Returns the decoded UTF-8 and how many bytes were consumed (through ';').
-spec entity(binary()) -> {ok, binary(), pos_integer()} | none.
entity(<<$#, X, R/binary>>) when X =:= $x; X =:= $X ->
    case hexrun(R, 0) of
        N when N >= 1, N =< 6 ->
            case R of
                <<H:N/binary, $;, _/binary>> ->
                    {ok, codepoint(binary_to_integer(H, 16)), 2 + N + 1};
                _ ->
                    none
            end;
        _ ->
            none
    end;
entity(<<$#, R/binary>>) ->
    case digitrun(R, 0) of
        N when N >= 1, N =< 7 ->
            case R of
                <<D:N/binary, $;, _/binary>> -> {ok, codepoint(binary_to_integer(D)), 1 + N + 1};
                _ -> none
            end;
        _ ->
            none
    end;
entity(<<C, _/binary>> = R) when ?IS_LETTER(C) ->
    case alnumrun(R, 0) of
        N when N >= 1, N =< 31 ->
            case R of
                <<Name:N/binary, $;, _/binary>> ->
                    case erlmark_entities:lookup(Name) of
                        error -> none;
                        Chars -> {ok, Chars, N + 1}
                    end;
                _ ->
                    none
            end;
        _ ->
            none
    end;
entity(_) ->
    none.

%% Invalid code points become U+FFFD (CommonMark).
codepoint(0) -> <<16#FFFD/utf8>>;
codepoint(C) when C > 16#10FFFF -> <<16#FFFD/utf8>>;
codepoint(C) when C >= 16#D800, C =< 16#DFFF -> <<16#FFFD/utf8>>;
codepoint(C) -> <<C/utf8>>.

hexrun(<<C, R/binary>>, N) when ?IS_DIGIT(C); C >= $a, C =< $f; C >= $A, C =< $F ->
    hexrun(R, N + 1);
hexrun(_, N) ->
    N.
digitrun(<<C, R/binary>>, N) when ?IS_DIGIT(C) -> digitrun(R, N + 1);
digitrun(_, N) -> N.
alnumrun(<<C, R/binary>>, N) when ?IS_ALNUM(C), N < 40 -> alnumrun(R, N + 1);
alnumrun(_, N) -> N.

%%--------------------------------------------------------------------
%% Strings
%%--------------------------------------------------------------------

%% Remove backslash escapes before ASCII punctuation and decode character
%% references, in one left-to-right pass (so an escaped '&' stays literal).
-spec unescape(binary()) -> binary().
unescape(B) -> unesc(B, B, 0, 0, []).

%% One pass over the text: unchanged runs are copied as slices (like esc/1), a backslash
%% escape drops the backslash, a character reference is decoded. Four bytes per step
%% through the long runs that contain neither `\\` nor `&`.
-define(UNESC_TAB,
    {true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, false, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, false, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true}
).

unesc(<<>>, O, 0, _, []) ->
    O;
unesc(<<>>, O, S, L, A) ->
    iolist_to_binary(lists:reverse(fl(O, S, L, A)));
unesc(<<A1, B1, C1, D1, R/binary>>, O, S, L, A) when
    element(A1 + 1, ?UNESC_TAB),
    element(B1 + 1, ?UNESC_TAB),
    element(C1 + 1, ?UNESC_TAB),
    element(D1 + 1, ?UNESC_TAB)
->
    unesc(R, O, S, L + 4, A);
unesc(<<$\\, X, R/binary>>, O, S, L, A) when ?IS_PUNCT(X) ->
    unesc(R, O, S + L + 2, 0, [<<X>> | fl(O, S, L, A)]);
unesc(<<$&, R/binary>>, O, S, L, A) ->
    case entity(R) of
        {ok, Dec, N} ->
            <<_:N/binary, R2/binary>> = R,
            unesc(R2, O, S + L + 1 + N, 0, [Dec | fl(O, S, L, A)]);
        none ->
            unesc(R, O, S, L + 1, A)
    end;
unesc(<<_, R/binary>>, O, S, L, A) ->
    unesc(R, O, S, L + 1, A).

%% Normalise a link label: case-fold and collapse internal whitespace.
-spec norm_label(binary()) -> binary().
norm_label(L) ->
    case already_normal(L) of
        true -> L;
        false -> norm_label_slow(L)
    end.

%% A label that is lowercase ASCII with single inner spaces and no edge spaces is
%% its own normal form: return it as is, without rebuilding it.
already_normal(<<$\s, _/binary>>) -> false;
already_normal(B) -> already_normal(B, false).

already_normal(<<>>, PrevSp) -> not PrevSp;
already_normal(<<$\s, _/binary>>, true) -> false;
already_normal(<<$\s, R/binary>>, false) -> already_normal(R, true);
already_normal(<<C, _/binary>>, _) when C >= $A, C =< $Z; C =:= $\t; C =:= $\n; C >= 128 -> false;
already_normal(<<_, R/binary>>, _) -> already_normal(R, false).

norm_label_slow(L) ->
    try
        an(L, <<>>, false)
    catch
        throw:non_ascii -> norm_label_unicode(L)
    end.

%% Non-ASCII label: full Unicode case folding when the bytes are valid UTF-8,
%% otherwise (arbitrary bytes are legal input) fold ASCII only.
norm_label_unicode(L) ->
    try
        Folded = unicode:characters_to_binary(string:casefold(L)),
        true = is_binary(Folded),
        iolist_to_binary(lists:join(<<" ">>, string:lexemes(Folded, [$\s, $\t, $\n])))
    catch
        _:_ -> an_lenient(L, <<>>, false)
    end.

%% ASCII fast path: lowercase, collapse whitespace runs, trim.
an(<<C, R/binary>>, Acc, Sp) when C >= $A, C =< $Z -> an(R, an_add(Acc, Sp, C + 32), false);
an(<<C, R/binary>>, Acc, _) when C =:= $\s; C =:= $\t; C =:= $\n -> an(R, Acc, true);
an(<<C, _/binary>>, _, _) when C >= 128 -> throw(non_ascii);
an(<<C, R/binary>>, Acc, Sp) -> an(R, an_add(Acc, Sp, C), false);
an(<<>>, Acc, _) -> Acc.

%% Same, but passes bytes >= 128 through untouched.
an_lenient(<<C, R/binary>>, Acc, Sp) when C >= $A, C =< $Z ->
    an_lenient(R, an_add(Acc, Sp, C + 32), false);
an_lenient(<<C, R/binary>>, Acc, _) when C =:= $\s; C =:= $\t; C =:= $\n ->
    an_lenient(R, Acc, true);
an_lenient(<<C, R/binary>>, Acc, Sp) ->
    an_lenient(R, an_add(Acc, Sp, C), false);
an_lenient(<<>>, Acc, _) ->
    Acc.

an_add(<<>>, _, C) -> <<C>>;
an_add(Acc, true, C) -> <<Acc/binary, $\s, C>>;
an_add(Acc, false, C) -> <<Acc/binary, C>>.

%% Length of a link label's text. Input is the binary *after* the '['; the
%% label ends at the first unescaped ']' and may not contain an unescaped '['.
-spec label_len(binary()) -> {ok, non_neg_integer()} | none.
label_len(R) -> lscan(R, 0).

%% A label is the text up to the first unescaped `]` and may not contain `[`; its length is
%% at most 999. Four ordinary bytes per step (neither `\\`, `[` nor `]`).
-define(LABEL_TAB,
    {true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        false, false, false, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true}
).

lscan(<<A, B, C, D, R/binary>>, N) when
    element(A + 1, ?LABEL_TAB),
    element(B + 1, ?LABEL_TAB),
    element(C + 1, ?LABEL_TAB),
    element(D + 1, ?LABEL_TAB)
->
    lscan(R, N + 4);
lscan(<<$\\, _, R/binary>>, N) ->
    lscan(R, N + 2);
lscan(<<$[, _/binary>>, _) ->
    none;
lscan(<<$], _/binary>>, N) when N =< 999 -> {ok, N};
lscan(<<$], _/binary>>, _) ->
    none;
lscan(<<_, R/binary>>, N) ->
    lscan(R, N + 1);
lscan(<<>>, _) ->
    none.

%% Code point helpers for Unicode-aware delimiter flanking.
-spec last_cp(binary()) -> non_neg_integer().
last_cp(<<>>) ->
    $\s;
last_cp(B) ->
    Size = byte_size(B),
    case binary:last(B) of
        C when C < 128 -> C;
        _ -> last_cp(B, Size - 1, 0)
    end.

last_cp(B, J, K) when J >= 0, K < 4 ->
    case B of
        <<_:J/binary, C, _/binary>> when C band 16#C0 =:= 16#80 -> last_cp(B, J - 1, K + 1);
        <<_:J/binary, CP/utf8>> -> CP;
        _ -> 16#FFFD
    end;
last_cp(_, _, _) ->
    16#FFFD.

-spec first_cp(binary()) -> non_neg_integer().
first_cp(<<C, _/binary>>) when C < 128 -> C;
first_cp(<<CP/utf8, _/binary>>) -> CP;
first_cp(<<_, _/binary>>) -> 16#FFFD;
first_cp(<<>>) -> $\s.

%% Unicode whitespace (category Zs) and punctuation (categories P* and S*).
%% unicode_util:category/1 exists from OTP 29; older releases use PCRE's Unicode
%% properties, with the compiled patterns cached in persistent_term.
-if(?OTP_RELEASE >= 29).
-spec unicode_ws(non_neg_integer()) -> boolean().
unicode_ws(CP) ->
    case unicode_util:category(CP) of
        {separator, space} -> true;
        _ -> false
    end.

-spec unicode_punct(non_neg_integer()) -> boolean().
unicode_punct(CP) ->
    case unicode_util:category(CP) of
        {punctuation, _} -> true;
        {symbol, _} -> true;
        _ -> false
    end.
-else.
-spec unicode_ws(non_neg_integer()) -> boolean().
unicode_ws(CP) -> has_property(ws, CP).

-spec unicode_punct(non_neg_integer()) -> boolean().
unicode_punct(CP) -> has_property(punct, CP).

has_property(Kind, CP) when CP >= 0, CP =< 16#10FFFF, not (CP >= 16#D800 andalso CP =< 16#DFFF) ->
    re:run(<<CP/utf8>>, property_re(Kind), [{capture, none}]) =:= match;
has_property(_, _) ->
    false.

property_re(Kind) ->
    case persistent_term:get({?MODULE, Kind}, undefined) of
        undefined ->
            Src =
                case Kind of
                    ws -> <<"^\\p{Zs}$">>;
                    punct -> <<"^[\\p{P}\\p{S}]$">>
                end,
            {ok, Re} = re:compile(Src, [unicode, ucp]),
            persistent_term:put({?MODULE, Kind}, Re),
            Re;
        Re ->
            Re
    end.
-endif.

%% The value of a conversion option set by erlmark:to_html/2, or `false'.
-spec flag(atom()) -> term().
flag(Key) ->
    case get(erlmark_flags) of
        undefined -> false;
        Flags -> proplists:get_value(Key, Flags, false)
    end.

%% Does a destination use a scheme that can run script or read local data? Browsers
%% ignore leading control characters and spaces and any tab or line break inside the
%% scheme, so those are skipped before comparing, ignoring case. `data:' is allowed for
%% the common raster image formats only.
-spec unsafe_url(binary()) -> boolean().
unsafe_url(Url) ->
    Head = binary:part(Url, 0, min(byte_size(Url), 64)),
    Clean = <<<<(lower(C))>> || <<C>> <= skip_controls(Head), C =/= $\t, C =/= $\n, C =/= $\r>>,
    case Clean of
        <<"javascript:", _/binary>> -> true;
        <<"vbscript:", _/binary>> -> true;
        <<"file:", _/binary>> -> true;
        <<"data:image/png", _/binary>> -> false;
        <<"data:image/gif", _/binary>> -> false;
        <<"data:image/jpeg", _/binary>> -> false;
        <<"data:image/webp", _/binary>> -> false;
        <<"data:", _/binary>> -> true;
        _ -> false
    end.

skip_controls(<<C, R/binary>>) when C =< 32 -> skip_controls(R);
skip_controls(B) -> B.

lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

%% The GitHub-style anchor for a heading's plain text: lowercase, only letters, marks,
%% numbers, connector punctuation, spaces and hyphens kept, spaces turned into hyphens.
-spec slug(binary()) -> binary().
slug(Text) ->
    Lower =
        case unicode:characters_to_binary(Text) of
            Valid when is_binary(Valid) -> string:lowercase(Valid);
            _ -> <<<<(lower(C))>> || <<C>> <= Text>>
        end,
    Kept = re:replace(Lower, "[^\\p{L}\\p{M}\\p{N}\\p{Pc} -]", "", [
        unicode, ucp, global, {return, binary}
    ]),
    binary:replace(Kept, <<" ">>, <<"-">>, [global]).

-spec ltrim(binary()) -> binary().
ltrim(<<C, R/binary>>) when ?IS_SP(C) -> ltrim(R);
ltrim(B) -> B.

-spec rtrim(binary()) -> binary().
rtrim(<<>>) ->
    <<>>;
rtrim(B) ->
    N = byte_size(B),
    M = N - 1,
    %% Usual case: the last byte is not a blank, return B untouched.
    case B of
        <<_:M/binary, C>> when ?IS_SP(C) -> rtrim(B, M);
        _ -> B
    end.

rtrim(B, N) when N > 0 ->
    M = N - 1,
    case B of
        <<_:M/binary, C, _/binary>> when ?IS_SP(C) -> rtrim(B, M);
        _ when N =:= byte_size(B) -> B;
        _ ->
            <<T:N/binary, _/binary>> = B,
            T
    end;
rtrim(_, 0) ->
    <<>>.

-spec trim(binary()) -> binary().
trim(B) -> ltrim(rtrim(B)).

-spec run_len(binary(), byte()) -> non_neg_integer().
run_len(B, C) -> run_len(B, C, 0).
run_len(<<C, R/binary>>, C, N) -> run_len(R, C, N + 1);
run_len(_, _, N) -> N.

-spec is_blank(binary()) -> boolean().
is_blank(<<>>) -> true;
is_blank(<<C, R/binary>>) when ?IS_SP(C) -> is_blank(R);
is_blank(_) -> false.

%% Skip spaces/tabs and at most one line ending.
-spec skip_ws(binary()) -> {binary(), boolean()}.
skip_ws(B) ->
    case ltrim(B) of
        <<$\n, R/binary>> -> {ltrim(R), true};
        B1 -> {B1, false}
    end.

%%--------------------------------------------------------------------
%% Link destinations and titles
%%--------------------------------------------------------------------

-spec parse_dest(binary()) -> {ok, binary(), binary()} | none.
parse_dest(<<$<, R/binary>>) -> pointy(R, R, 0, false);
parse_dest(B) -> plain(B, B, 0, 0, false).

%% a backslash escapes only ASCII punctuation (a backslash before a line end is not an escape)
pointy(<<$\\, X, R/binary>>, O, N, _) when ?IS_PUNCT(X) -> pointy(R, O, N + 2, true);
pointy(<<$&, R/binary>>, O, N, _) ->
    pointy(R, O, N + 1, true);
pointy(<<$>, Rest/binary>>, O, N, E) ->
    <<D:N/binary, _/binary>> = O,
    {ok, maybe_unescape(D, E), Rest};
pointy(<<C, _/binary>>, _, _, _) when C =:= $\n; C =:= $< -> none;
pointy(<<_, R/binary>>, O, N, E) ->
    pointy(R, O, N + 1, E);
pointy(<<>>, _, _, _) ->
    none.

%% Bytes that need no special handling inside an unbracketed destination.
-define(DEST_OK(X),
    (X > 32 andalso X < 127 andalso X =/= $\\ andalso X =/= $( andalso X =/= $) andalso X =/= $&)
).

%% Dp = open-paren depth, E = a backslash escape was seen (so unescaping is needed).
plain(<<A, B, C, D, R/binary>>, O, N, Dp, E) when
    ?DEST_OK(A), ?DEST_OK(B), ?DEST_OK(C), ?DEST_OK(D)
->
    plain(R, O, N + 4, Dp, E);
plain(<<C, R/binary>> = All, O, N, Dp, E) ->
    case C of
        $\\ ->
            case R of
                <<X, R2/binary>> when ?IS_PUNCT(X) -> plain(R2, O, N + 2, Dp, true);
                _ -> plain(R, O, N + 1, Dp, E)
            end;
        $& ->
            plain(R, O, N + 1, Dp, true);
        $( when Dp < 32 -> plain(R, O, N + 1, Dp + 1, E);
        $( ->
            none;
        $) when Dp =:= 0 -> dest_done(All, O, N, E);
        $) ->
            plain(R, O, N + 1, Dp - 1, E);
        _ when C =< 32; C =:= 127 -> plain_end(All, O, N, Dp, E);
        _ ->
            plain(R, O, N + 1, Dp, E)
    end;
plain(<<>>, O, N, Dp, E) ->
    plain_end(<<>>, O, N, Dp, E).

plain_end(Rest, O, N, 0, E) -> dest_done(Rest, O, N, E);
plain_end(_, _, _, _, _) -> none.

dest_done(Rest, O, N, E) ->
    <<D:N/binary, _/binary>> = O,
    {ok, maybe_unescape(D, E), Rest}.

maybe_unescape(D, true) -> unescape(D);
maybe_unescape(D, false) -> D.

-spec parse_title(binary()) -> {ok, binary(), binary()} | none.
parse_title(<<$", R/binary>>) -> title(R, $", R, 0, false);
parse_title(<<$', R/binary>>) -> title(R, $', R, 0, false);
parse_title(<<$(, R/binary>>) -> title(R, $), R, 0, false);
parse_title(_) -> none.

-define(TITLE_OK(X, Close), (X =/= Close andalso X =/= $\\ andalso X =/= $( andalso X =/= $&)).

title(<<A, B, C, D, R/binary>>, Close, O, N, E) when
    ?TITLE_OK(A, Close), ?TITLE_OK(B, Close), ?TITLE_OK(C, Close), ?TITLE_OK(D, Close)
->
    title(R, Close, O, N + 4, E);
title(<<C, R/binary>>, Close, O, N, E) ->
    case C of
        Close ->
            <<T:N/binary, _/binary>> = O,
            {ok, maybe_unescape(T, E), R};
        $\\ ->
            case R of
                <<X, R2/binary>> when ?IS_PUNCT(X) -> title(R2, Close, O, N + 2, true);
                _ -> title(R, Close, O, N + 1, E)
            end;
        $& ->
            title(R, Close, O, N + 1, true);
        $( when Close =:= $) -> none;
        _ ->
            title(R, Close, O, N + 1, E)
    end;
title(<<>>, _, _, _, _) ->
    none.

%%--------------------------------------------------------------------
%% Raw inline HTML. Input is the binary *after* the '<'.
%% Returns the number of bytes consumed (through the closing '>').
%%--------------------------------------------------------------------

-spec html_tag_len(binary()) -> {ok, pos_integer()} | none.
html_tag_len(R) ->
    case html_tag(R) of
        none -> none;
        Rest -> {ok, byte_size(R) - byte_size(Rest)}
    end.

%% Each clause returns the binary after the tag, or `none`. No exceptions: a
%% failed match (a stray "<") must be cheap.
html_tag(<<"!-->", R/binary>>) ->
    R;
html_tag(<<"!--->", R/binary>>) ->
    R;
html_tag(<<"!--", R/binary>>) ->
    seq_end(R, <<"-->">>);
html_tag(<<"?", R/binary>>) ->
    seq_end(R, <<"?>">>);
html_tag(<<"![CDATA[", R/binary>>) ->
    seq_end(R, <<"]]>">>);
html_tag(<<$!, C, R/binary>>) when ?IS_LETTER(C) -> seq_end(R, <<">">>);
html_tag(<<$/, C, R/binary>>) when ?IS_LETTER(C) ->
    R1 = tag_name(R),
    case R1 of
        <<$>, R3/binary>> ->
            R3;
        _ ->
            {R2, _} = ws(R1, 0),
            case R2 of
                <<$>, R4/binary>> -> R4;
                _ -> none
            end
    end;
html_tag(<<C, R/binary>>) when ?IS_LETTER(C) ->
    R0 = tag_name(R),
    case R0 of
        %% fast path: bare <tag>
        <<$>, R5/binary>> -> R5;
        _ -> html_open_rest(R0)
    end;
html_tag(_) ->
    none.

html_open_rest(R0) ->
    case open_pos(R0, 0) of
        none ->
            none;
        End ->
            <<_:End/binary, Rest/binary>> = R0,
            Rest
    end.

%% The attributes and the end of an open tag, scanned by offset into the tag (no sub-binary
%% per step). Returns the offset just after the closing `>` / `/>`, or `none`.
open_pos(B, P) ->
    case B of
        <<_:P/binary, $\s, C, _/binary>> when ?IS_LETTER(C) -> attr_pos(B, P + 2);
        <<_:P/binary, W, _/binary>> when ?IS_WS(W) ->
            P1 = ws_pos(B, P + 1),
            case B of
                <<_:P1/binary, C, _/binary>> when ?IS_LETTER(C); C =:= $_; C =:= $: ->
                    attr_pos(B, P1 + 1);
                <<_:P1/binary, "/>", _/binary>> ->
                    P1 + 2;
                <<_:P1/binary, $>, _/binary>> ->
                    P1 + 1;
                _ ->
                    none
            end;
        <<_:P/binary, "/>", _/binary>> ->
            P + 2;
        <<_:P/binary, $>, _/binary>> ->
            P + 1;
        _ ->
            none
    end.

%% P is just after the first byte of an attribute name.
attr_pos(B, P) ->
    P1 = name_pos(B, P),
    case B of
        <<_:P1/binary, $=, $", _/binary>> ->
            value_end(B, quote_pos(B, P1 + 2, $"));
        <<_:P1/binary, $=, $', _/binary>> ->
            value_end(B, quote_pos(B, P1 + 2, $'));
        _ ->
            P2 = ws_pos(B, P1),
            case B of
                <<_:P2/binary, $=, _/binary>> ->
                    P3 = ws_pos(B, P2 + 1),
                    case B of
                        <<_:P3/binary, $", _/binary>> -> value_end(B, quote_pos(B, P3 + 1, $"));
                        <<_:P3/binary, $', _/binary>> -> value_end(B, quote_pos(B, P3 + 1, $'));
                        _ -> value_end(B, unquoted_pos(B, P3, P3))
                    end;
                %% no value: the next attribute (or the end) is looked for right after the name
                _ ->
                    open_pos(B, P1)
            end
    end.

value_end(_, none) -> none;
value_end(B, P) -> open_pos(B, P).

-define(UNQ_STOP(C),
    (?IS_WS(C) orelse C =:= $" orelse C =:= $' orelse C =:= $= orelse
        C =:= $< orelse C =:= $> orelse C =:= $`)
).

%% An unquoted value: a non-empty run without blanks, quotes, `=`, `<`, `>` or backtick.
unquoted_pos(B, P, Start) ->
    case B of
        <<_:P/binary, C, _/binary>> when not ?UNQ_STOP(C) -> unquoted_pos(B, P + 1, Start);
        _ when P =:= Start -> none;
        _ -> P
    end.

ws_pos(B, P) ->
    case B of
        <<_:P/binary, C, _/binary>> when ?IS_WS(C) -> ws_pos(B, P + 1);
        _ -> P
    end.

-define(ATTR_NAME_TAB,
    {false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, true, true, false, true, true, true, true, true,
        true, true, true, true, true, true, false, false, false, false, false, false, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, false, false, false, false, true,
        false, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false}
).

name_pos(B, P) ->
    case B of
        <<_:P/binary, A, B1, C, D, _/binary>> when
            element(A + 1, ?ATTR_NAME_TAB),
            element(B1 + 1, ?ATTR_NAME_TAB),
            element(C + 1, ?ATTR_NAME_TAB),
            element(D + 1, ?ATTR_NAME_TAB)
        ->
            name_pos(B, P + 4);
        <<_:P/binary, C, _/binary>> when ?IS_ALNUM(C); C =:= $_; C =:= $.; C =:= $:; C =:= $- ->
            name_pos(B, P + 1);
        _ ->
            P
    end.

%% Offset just after the next occurrence of byte Q at or after P (`none` if there is none).
%% One sub-binary, then a consuming scan (the match context is kept between steps): four bytes
%% per step for the first 64 bytes, then one native search for a longer value.
quote_pos(B, P, Q) ->
    <<_:P/binary, R/binary>> = B,
    case qscan(R, Q, 0) of
        none -> none;
        N -> P + N + 1
    end.

qscan(<<Q, _/binary>>, Q, N) ->
    N;
qscan(<<X1, X2, X3, X4, R/binary>>, Q, N) when
    N < 64, X1 =/= Q, X2 =/= Q, X3 =/= Q, X4 =/= Q
->
    qscan(R, Q, N + 4);
qscan(<<_, R/binary>>, Q, N) when N < 64 -> qscan(R, Q, N + 1);
qscan(<<>>, _, _) ->
    none;
qscan(R, Q, N) ->
    case binary:match(R, <<Q>>) of
        {Pos, 1} -> N + Pos;
        nomatch -> none
    end.

%% The binary after the first occurrence of a 1-3 byte sequence, or `none`.
seq_end(R, <<A>>) -> seq_end1(R, A, 0);
seq_end(<<A, B, R/binary>>, <<A, B>>) -> R;
seq_end(<<A, B, C, R/binary>>, <<A, B, C>>) -> R;
seq_end(<<_, R/binary>>, Seq) -> seq_end(R, Seq);
seq_end(<<>>, _) -> none.

%% One-byte terminator (attribute value quotes, '>'): a few byte steps, then one
%% native memchr-fast search for the rest of a long value.
seq_end1(<<A, R/binary>>, A, _) ->
    R;
seq_end1(<<X1, X2, X3, X4, R/binary>>, A, N) when
    N < 64, X1 =/= A, X2 =/= A, X3 =/= A, X4 =/= A
->
    seq_end1(R, A, N + 4);
seq_end1(<<_, R/binary>>, A, N) when N < 64 -> seq_end1(R, A, N + 1);
seq_end1(<<>>, _, _) ->
    none;
seq_end1(R, A, _) ->
    case binary:match(R, <<A>>) of
        {P, 1} ->
            <<_:P/binary, _, After/binary>> = R,
            After;
        nomatch ->
            none
    end.

tag_name(<<C, R/binary>>) when ?IS_ALNUM(C); C =:= $- -> tag_name(R);
tag_name(R) -> R.

ws(<<C, R/binary>>, N) when ?IS_WS(C) -> ws(R, N + 1);
ws(R, N) -> {R, N}.

%%--------------------------------------------------------------------
%% Autolinks. Input is the binary *after* the '<'.
%%--------------------------------------------------------------------

%% Cheap pre-check: an autolink needs a ':' (URI) or '@' (email) before the '>'.
-spec could_autolink(binary()) -> boolean().
could_autolink(<<C, _/binary>>) when C =:= $:; C =:= $@ -> true;
could_autolink(<<C, _/binary>>) when C =:= $>; C =:= $<; C =< 32 -> false;
could_autolink(<<_, R/binary>>) -> could_autolink(R);
could_autolink(<<>>) -> false.

-spec autolink(binary()) -> {ok, binary(), binary(), binary()} | none.
autolink(<<C, R/binary>> = All) when ?IS_LETTER(C) ->
    case scheme(R, 1) of
        {ok, N} ->
            %% All = scheme ":" rest ">"
            <<_:N/binary, $:, Tail/binary>> = All,
            case until_gt(Tail, 0) of
                {ok, M} ->
                    %% scheme ":" body is contiguous in the input: slice, don't rebuild
                    <<Text:(N + 1 + M)/binary, $>, Rest/binary>> = All,
                    {ok, Text, Text, Rest};
                none ->
                    email(All)
            end;
        none ->
            email(All)
    end;
autolink(All) ->
    email(All).

scheme(<<C, R/binary>>, N) when
    N < 32, (?IS_ALNUM(C) orelse C =:= $+ orelse C =:= $. orelse C =:= $-)
->
    scheme(R, N + 1);
scheme(<<$:, _/binary>>, N) when N >= 2 -> {ok, N};
scheme(_, _) ->
    none.

%% Autolink body bytes: above 32, not `<`, `>` or DEL (the run is checked four bytes at a
%% time; the single-byte clauses below decide what ends it).
-define(BODY_TAB,
    {false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, false, false, false, false, false, false,
        false, false, false, false, false, false, false, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, false, true, false, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, false, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        true, true, true, true, true, true}
).

until_gt(B, N) ->
    case B of
        <<_:N/binary, A, B1, C, D, _/binary>> when
            element(A + 1, ?BODY_TAB),
            element(B1 + 1, ?BODY_TAB),
            element(C + 1, ?BODY_TAB),
            element(D + 1, ?BODY_TAB)
        ->
            until_gt(B, N + 4);
        _ ->
            until_gt1(B, N)
    end.

until_gt1(B, N) ->
    case B of
        <<_:N/binary, $>, _/binary>> -> {ok, N};
        <<_:N/binary, C, _/binary>> when C =< 32; C =:= $<; C =:= 127 -> none;
        <<_:N/binary, _, _/binary>> -> until_gt1(B, N + 1);
        _ -> none
    end.

email(All) ->
    case local(All, 0) of
        {ok, N} when N > 0 ->
            <<Local:N/binary, $@, Dom/binary>> = All,
            case domain(Dom, 0, 0) of
                {ok, M} ->
                    <<D:M/binary, $>, Rest/binary>> = Dom,
                    Text = <<Local/binary, $@, D/binary>>,
                    {ok, Text, <<"mailto:", Text/binary>>, Rest};
                none ->
                    none
            end;
        _ ->
            none
    end.

local(B, N) ->
    case B of
        <<_:N/binary, C, _/binary>> when
            ?IS_ALNUM(C);
            C =:= $.;
            C =:= $!;
            C =:= $#;
            C =:= $$;
            C =:= $%;
            C =:= $&;
            C =:= $';
            C =:= $*;
            C =:= $+;
            C =:= $/;
            C =:= $=;
            C =:= $?;
            C =:= $^;
            C =:= $_;
            C =:= $`;
            C =:= ${;
            C =:= $|;
            C =:= $};
            C =:= $~;
            C =:= $-
        ->
            local(B, N + 1);
        <<_:N/binary, $@, _/binary>> ->
            {ok, N};
        _ ->
            none
    end.

%% domain: label *("." label) then '>'; label = alnum [alnum or '-']*
domain(B, N, LabelLen) ->
    case B of
        <<_:N/binary, C, _/binary>> when ?IS_ALNUM(C) -> domain(B, N + 1, LabelLen + 1);
        <<_:N/binary, $-, _/binary>> when LabelLen > 0 -> domain(B, N + 1, LabelLen + 1);
        <<_:N/binary, $., _/binary>> when LabelLen > 0 -> domain(B, N + 1, 0);
        <<_:N/binary, $>, _/binary>> when LabelLen > 0, N > 0 -> {ok, N};
        _ -> none
    end.

%%--------------------------------------------------------------------

%% Remove <...> sequences (used for image alt text).
-spec strip_tags(iodata()) -> binary().
strip_tags(IoData) -> strip(iolist_to_binary(IoData), <<>>).

strip(<<"<img src=\"", R/binary>>, Acc) ->
    %% A nested image contributes its own alt text.
    case binary:match(R, <<"\" alt=\"">>) of
        {P, L} ->
            After = part(R, P + L, byte_size(R) - P - L),
            case binary:match(After, <<"\"">>) of
                {Q, 1} ->
                    Alt = part(After, 0, Q),
                    skip_tag(part(After, Q, byte_size(After) - Q), <<Acc/binary, Alt/binary>>);
                nomatch ->
                    skip_tag(R, Acc)
            end;
        nomatch ->
            skip_tag(R, Acc)
    end;
strip(<<$<, R/binary>>, Acc) ->
    skip_tag(R, Acc);
strip(<<C, R/binary>>, Acc) ->
    strip(R, <<Acc/binary, C>>);
strip(<<>>, Acc) ->
    Acc.

skip_tag(<<$>, R/binary>>, Acc) -> strip(R, Acc);
skip_tag(<<_, R/binary>>, Acc) -> skip_tag(R, Acc);
skip_tag(<<>>, Acc) -> Acc.

%% Pattern-matching slice: same as binary:part/3 for non-negative lengths, but
%% inlined (no BIF call).
part(B, S, L) ->
    <<_:S/binary, R:L/binary, _/binary>> = B,
    R.
