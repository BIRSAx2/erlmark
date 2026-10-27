%% @private
%% Picks cut points for converting a document in parallel.
%%
%% A cut is placed at "a blank line followed by an unindented letter or '#'":
%% such a line starts a new top-level block (it cannot continue a list, quote
%% or paragraph across the blank line, and it is not an indented code line).
%%
%% The only constructs that can contain such a line are fenced code blocks and
%% HTML blocks of types 1-5. Rather than scanning for them up front, the block
%% parser reports when a chunk ends inside one (see `erlmark:convert_chunk/1`),
%% and the caller then falls back to sequential conversion.
-module(erlmark_split).
-include("erlmark.hrl").

-export([split/3]).

%% @doc Split `Bin' into at most `K' chunks of at least `MinChunk' bytes.
-spec split(binary(), pos_integer(), pos_integer()) -> [binary()].
split(Bin, K, MinChunk) when K > 1, byte_size(Bin) >= 2 * MinChunk ->
    Size = byte_size(Bin),
    Chunks = min(K, Size div MinChunk),
    Step = Size div Chunks,
    case fence_intervals(Bin, Size) of
        ambiguous ->
            [Bin];
        Fences ->
            Cuts = cuts(Bin, Size, Fences, Step, Step, Chunks - 1, 0, []),
            slice(Bin, Cuts, 0, [])
    end;
split(Bin, _, _) ->
    [Bin].

%% Top-level fenced code blocks as {OpenPos, CloseLineEnd} intervals, used only to
%% *prefer* cuts outside them (the parser still verifies every cut). With few
%% markers the real fence rules are simulated (marker character, run length,
%% up to three spaces of indent, blank-only closing line), which handles nested
%% and mixed-style fences. Many markers fall back to cheap parity pairing. A
%% document without any fence skips all of this.
-define(EXACT_LIMIT, 4096).
%% The breakout shape is systematic (an author or generator that writes fences
%% that way does so consistently), so sampling the first few indented fences
%% catches it at a fraction of the cost of scanning all of them.
-define(BREAKOUT_SAMPLE, 8).
-define(PROBE_MARKERS, 12).

fence_intervals(Bin, Size) ->
    case patterns(Bin) of
        [] ->
            [];
        Pats ->
            %% Compile the search once: a list pattern would otherwise rebuild its
            %% automaton on every binary:match/3 call.
            CP = binary:compile_pattern(Pats),
            case probe(Bin, Size, CP) of
                ambiguous -> ambiguous;
                ok -> fence_intervals(Bin, Size, CP)
            end
    end.

%% Cheap look at the first few fences (single searches, no full scan): an
%% ambiguous document shows its shape immediately, so decide before scanning
%% every marker.
probe(Bin, Size, Pats) ->
    First = first_markers(Bin, Size, Pats, 0, ?PROBE_MARKERS, []),
    try
        _ = simulate(Bin, Size, First, closed, [], 0),
        ok
    catch
        throw:ambiguous -> ambiguous
    end.

%% N bounds every occurrence examined, not only the accepted ones, so a document
%% full of quoted or inline backtick runs cannot make the probe expensive.
first_markers(_, _, _, _, 0, Acc) ->
    lists:reverse(Acc);
first_markers(Bin, Size, Pats, From, N, Acc) when From < Size ->
    case binary:match(Bin, Pats, [{scope, {From, Size - From}}]) of
        nomatch ->
            lists:reverse(Acc);
        {P, L} ->
            case line_start(Bin, P) of
                true -> first_markers(Bin, Size, Pats, P + L, N - 1, [P | Acc]);
                false -> first_markers(Bin, Size, Pats, P + L, N - 1, Acc)
            end
    end;
first_markers(_, _, _, _, _, Acc) ->
    lists:reverse(Acc).

fence_intervals(Bin, Size, Pats) ->
    begin
        Marks = [P || {P, _} <- binary:matches(Bin, Pats), line_start(Bin, P)],
        case length(Marks) =< ?EXACT_LIMIT of
            true ->
                try
                    [{S, E} || {S, E, _} <- simulate(Bin, Size, Marks, closed, [], 0)]
                catch
                    throw:ambiguous -> ambiguous
                end;
            false ->
                pair(Marks, Size)
        end
    end.

%% A single-search guard first (cheap on fence-free text); tildes only if present.
patterns(Bin) ->
    BT =
        case binary:match(Bin, <<"```">>) of
            nomatch -> [];
            _ -> [<<"```">>]
        end,
    TT =
        case binary:match(Bin, <<"~">>) of
            nomatch ->
                [];
            _ ->
                case binary:match(Bin, <<"~~~">>) of
                    nomatch -> [];
                    _ -> [<<"~~~">>]
                end
        end,
    BT ++ TT.

%% A marker must be preceded on its line by at most three spaces.
line_start(_, 0) -> true;
line_start(Bin, P) -> line_start(Bin, P, 0).

line_start(_, 0, _) ->
    true;
line_start(Bin, P, N) when N =< 3 ->
    case binary:at(Bin, P - 1) of
        $\n -> true;
        $\s -> line_start(Bin, P - 1, N + 1);
        _ -> false
    end;
line_start(_, _, _) ->
    false.

%% One tight pass per marker line: run length, whether the rest of the line
%% contains a backtick / is blank, and where the line ends. No BIF calls.
simulate(_Bin, _Size, [], closed, Acc, _) ->
    lists:reverse(Acc);
simulate(_Bin, Size, [], {open, _, _, S, I}, Acc, _) ->
    lists:reverse([{S, Size, I} | Acc]);
simulate(Bin, Size, [P | Ps], closed, Acc, Ni) ->
    <<_:P/binary, Rest/binary>> = Bin,
    {C, Run, Tick, _Blank, Len} = marker_line(Rest),
    LineEnd = P + Len,
    case C =:= $` andalso Tick of
        true ->
            simulate(Bin, Size, Ps, closed, Acc, Ni);
        false ->
            simulate(
                Bin, Size, drop_before(Ps, LineEnd), {open, C, Run, P, indented(Bin, P)}, Acc, Ni
            )
    end;
simulate(Bin, Size, [P | Ps], {open, C, Len, S, I} = St, Acc, Ni) ->
    <<_:P/binary, Rest/binary>> = Bin,
    {C1, Run, _Tick, Blank, LLen} = marker_line(Rest),
    case C1 =:= C andalso Run >= Len andalso Blank of
        true ->
            Iv = {S, P + LLen, I},
            %% Abort at the first indented fence that shows the breakout shape.
            Ni1 =
                case I of
                    true ->
                        case Ni < ?BREAKOUT_SAMPLE andalso breakout(Bin, Iv) of
                            true -> throw(ambiguous);
                            _ -> Ni + 1
                        end;
                    false ->
                        Ni
                end,
            simulate(Bin, Size, drop_before(Ps, P + LLen), closed, [Iv | Acc], Ni1);
        false ->
            simulate(Bin, Size, Ps, St, Acc, Ni)
    end.

%% Is the fence marker at P indented (1-3 spaces)?
indented(_, 0) -> false;
indented(Bin, P) -> binary:at(Bin, P - 1) =:= $\s.

%% An indented fence whose content has an unindented line cannot be modelled
%% from the markers alone: in real Markdown that line ends an enclosing list
%% item (and the fence), so every later marker pairs the other way round.
breakout(Bin, {S, E, true}) ->
    col0_line(binary:part(Bin, S, E - S));
breakout(_, _) ->
    false.

%% Skip eight bytes at a time while none of them is a newline.
col0_line(<<A, B, C, D, E, F, G, H, R/binary>>) when
    A =/= $\n, B =/= $\n, C =/= $\n, D =/= $\n, E =/= $\n, F =/= $\n, G =/= $\n, H =/= $\n
->
    col0_line(R);
col0_line(<<$\n, C, _/binary>>) when C =/= $\s, C =/= $\t, C =/= $\n -> true;
col0_line(<<_, R/binary>>) ->
    col0_line(R);
col0_line(<<>>) ->
    false.

%% -> {FenceChar, RunLength, RestHasBacktick, RestIsBlank, LineLengthWithoutNewline}
marker_line(<<C, _/binary>> = Rest) ->
    {Run, After} = run(Rest, C, 0),
    {Tick, Blank, Extra} = tail(After, false, true, 0),
    {C, Run, Tick, Blank, Run + Extra}.

run(<<C, R/binary>>, C, N) -> run(R, C, N + 1);
run(R, _, N) -> {N, R}.

tail(<<$\n, _/binary>>, Tick, Blank, N) -> {Tick, Blank, N};
tail(<<$`, R/binary>>, _, _, N) -> tail(R, true, false, N + 1);
tail(<<C, R/binary>>, Tick, Blank, N) when C =:= $\s; C =:= $\t -> tail(R, Tick, Blank, N + 1);
tail(<<_, R/binary>>, Tick, _, N) -> tail(R, Tick, false, N + 1);
tail(<<>>, Tick, Blank, N) -> {Tick, Blank, N}.

drop_before([P | Ps], Limit) when P < Limit -> drop_before(Ps, Limit);
drop_before(Ps, _) -> Ps.

%% Cheap approximation for fence-heavy documents: pair markers off in order.
pair([], _) -> [];
pair([S], Size) -> [{S, Size}];
pair([S, E | Rest], Size) -> [{S, E} | pair(Rest, Size)].

%% HTML blocks of types 1-5 (<pre>, <script>, <style>, <textarea>, <!-- -->) may
%% contain blank lines. Instead of scanning the whole document for them, look
%% only at the window before a candidate cut: is the nearest opener there still
%% unclosed? Blocks longer than the window are left to the parser check.
-define(HTML_WINDOW, 512).
-define(HTML_PT, {?MODULE, html_patterns}).

html_patterns() ->
    case persistent_term:get(?HTML_PT, undefined) of
        undefined ->
            Opens = binary:compile_pattern([
                <<"\n<pre">>,
                <<"\n<script">>,
                <<"\n<style">>,
                <<"\n<textarea">>,
                <<"\n<!--">>
            ]),
            Closes = binary:compile_pattern([
                <<"</pre>">>,
                <<"</script>">>,
                <<"</style>">>,
                <<"</textarea>">>,
                <<"-->">>
            ]),
            persistent_term:put(?HTML_PT, {Opens, Closes}),
            {Opens, Closes};
        Ps ->
            Ps
    end.

in_html(Bin, P) ->
    From = max(0, P - ?HTML_WINDOW),
    {Opens, Closes} = html_patterns(),
    case last_match(Bin, Opens, From, P - From) of
        none ->
            false;
        {S, L} ->
            %% inside iff nothing closes it between the opener and the candidate
            binary:match(Bin, Closes, [{scope, {S + L, P - S - L}}]) =:= nomatch
    end.

%% Last match of Pat within [From, From+Len).
last_match(Bin, Pat, From, Len) ->
    case binary:matches(Bin, Pat, [{scope, {From, Len}}]) of
        [] -> none;
        Ms -> lists:last(Ms)
    end.

%% True when P lies inside none of the (sorted) fence intervals.
outside([], _) ->
    true;
outside([{S, E} | Is], P) ->
    if
        P =< S -> true;
        P < E -> false;
        true -> outside(Is, P)
    end.

%% Find one cut at or after each target offset. A heading is preferred (a bare
%% `#' line after a blank is rarely inside code); only if none is near the
%% target do we accept any block starting with a letter.
cuts(_, _, _, _, _, 0, _, Acc) ->
    lists:reverse(Acc);
cuts(Bin, Size, Fences, Step, Target, N, Prev, Acc) ->
    From = max(Target, Prev + 1),
    Window = From + Step div 2,
    Found =
        case heading(Bin, Size, Fences, From, Window) of
            none -> find(Bin, Size, Fences, From, Size);
            H -> H
        end,
    case Found of
        none -> lists:reverse(Acc);
        Cut -> cuts(Bin, Size, Fences, Step, Cut + Step, N - 1, Cut, [Cut | Acc])
    end.

%% A heading after a blank line is the literal "\n\n#": one native search.
heading(Bin, Size, Fences, From, Limit) when From < Size - 2 ->
    Len = min(Limit, Size) - From,
    case Len > 2 andalso binary:match(Bin, <<"\n\n#">>, [{scope, {From, Len}}]) of
        {Pos, 3} ->
            P = Pos + 2,
            case outside(Fences, P) andalso not in_html(Bin, P) of
                true -> P;
                false -> heading(Bin, Size, Fences, Pos + 1, Limit)
            end;
        _ ->
            none
    end;
heading(_, _, _, _, _) ->
    none.

%% First position >= From that begins a top-level block after a blank line.
find(Bin, Size, Fences, From, Limit) when From < Size - 1, From < Limit ->
    case binary:match(Bin, <<"\n\n">>, [{scope, {From, Size - From}}]) of
        nomatch ->
            none;
        {Pos, 2} ->
            P = skip_newlines(Bin, Size, Pos + 2),
            case
                P < Size andalso start_ok(binary:at(Bin, P)) andalso outside(Fences, P) andalso
                    not in_html(Bin, P)
            of
                true -> P;
                false when P >= Limit -> none;
                false -> find(Bin, Size, Fences, Pos + 1, Limit)
            end
    end;
find(_, _, _, _, _) ->
    none.

skip_newlines(Bin, Size, P) when P < Size ->
    case binary:at(Bin, P) of
        $\n -> skip_newlines(Bin, Size, P + 1);
        _ -> P
    end;
skip_newlines(_, _, P) ->
    P.

start_ok(C) -> ?IS_LETTER(C) orelse C =:= $#.

slice(Bin, [], Start, Acc) ->
    lists:reverse([binary:part(Bin, Start, byte_size(Bin) - Start) | Acc]);
slice(Bin, [C | Cs], Start, Acc) ->
    slice(Bin, Cs, C, [binary:part(Bin, Start, C - Start) | Acc]).
