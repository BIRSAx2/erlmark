%% Runs the official CommonMark 0.31.2 spec examples (test/spec.json).
-module(erlmark_spec_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/0, report/0]).

load() ->
    Path = filename:join([
        filename:dirname(code:which(?MODULE)), "..", "..", "..", "..", "test", "spec.json"
    ]),
    Path1 =
        case filelib:is_regular(Path) of
            true -> Path;
            false -> "test/spec.json"
        end,
    {ok, Bin} = file:read_file(Path1),
    json:decode(Bin).

%% Mirror the commonmark.js test normalisation: whitespace between tags.
norm(B) ->
    B1 = re:replace(B, ">\\s+<", "><", [global, {return, binary}]),
    string:trim(B1).

run() ->
    [
        begin
            #{<<"example">> := N, <<"markdown">> := Md, <<"html">> := Exp, <<"section">> := Sec} =
                E,
            Got =
                try
                    erlmark:to_html(Md)
                catch
                    C:R:_ -> {crash, C, R}
                end,
            Status =
                case Got of
                    Exp ->
                        exact;
                    {crash, _, _} ->
                        crash;
                    _ ->
                        case norm(Got) =:= norm(Exp) of
                            true -> normalized;
                            false -> fail
                        end
                end,
            {N, Sec, Status, Md, Exp, Got}
        end
     || E <- load()
    ].

report() ->
    Rs = run(),
    Total = length(Rs),
    Pass = length([1 || {_, _, S, _, _, _} <- Rs, S =:= exact orelse S =:= normalized]),
    Exact = length([1 || {_, _, exact, _, _, _} <- Rs]),
    Crash = length([1 || {_, _, crash, _, _, _} <- Rs]),
    io:format(
        "~nCommonMark 0.31.2: ~p/~p pass (~.1f%), ~p exact, ~p crashes~n~n",
        [Pass, Total, 100 * Pass / Total, Exact, Crash]
    ),
    Secs = lists:usort([S || {_, S, _, _, _, _} <- Rs]),
    [
        begin
            T = length([1 || {_, S2, _, _, _, _} <- Rs, S2 =:= S]),
            P = length([
                1
             || {_, S2, St, _, _, _} <- Rs, S2 =:= S, St =:= exact orelse St =:= normalized
            ]),
            io:format("  ~-34s ~3w/~3w~n", [binary_to_list(S), P, T])
        end
     || S <- Secs
    ],
    {Pass, Total, Rs}.

%% Every official example must match exactly.
spec_conformance_test() ->
    Rs = run(),
    Bad = [N || {N, _, S, _, _, _} <- Rs, S =/= exact],
    ?assertEqual([], Bad).

%% GFM extension examples (test/gfm.json, from the cmark-gfm spec): tables and
%% strikethrough are always on; autolinks and the tagfilter are opt-in.
gfm_conformance_test() ->
    Path =
        case filelib:is_regular("test/gfm.json") of
            true ->
                "test/gfm.json";
            false ->
                filename:join([
                    filename:dirname(code:which(?MODULE)),
                    "..",
                    "..",
                    "..",
                    "..",
                    "test",
                    "gfm.json"
                ])
        end,
    {ok, Bin} = file:read_file(Path),
    Bad = [
        {Ext, Md, Got}
     || #{<<"ext">> := Ext, <<"markdown">> := Md, <<"html">> := Exp} <- json:decode(Bin),
        Got <- [erlmark:to_html(Md, [{extensions, [autolink, tagfilter]}])],
        Got =/= Exp
    ],
    ?assertEqual([], Bad).

%% ---- Additional conformance data -------------------------------------------------------

data_path(Name) ->
    P = filename:join([filename:dirname(code:which(?MODULE)), "..", "..", "..", "..", "test", Name]),
    case filelib:is_regular(P) of
        true -> P;
        false -> filename:join("test", Name)
    end.

%% The cmark reference implementation's regression suite (bug reports the spec does not cover).
%% One example is a cmark-specific rule outside the CommonMark spec (an info string that already
%% starts with `language-` is not prefixed again); commonmark.js, like this library, prefixes it.
cmark_regression_test() ->
    {ok, Bin} = file:read_file(data_path("cmark_regression.json")),
    Known = [<<"```language-r\nx <- 1\n```\n\n```r\nx <- 1\n```\n">>],
    Bad = [
        {Md, Got}
     || #{<<"markdown">> := Md, <<"html">> := Exp} <- json:decode(Bin),
        not lists:member(Md, Known),
        Got <- [erlmark:to_html(Md)],
        Got =/= Exp
    ],
    ?assertEqual([], Bad).

%% The complete GFM spec (672 examples). Its CommonMark part is version 0.29, ours is 0.31.2: the
%% nine emphasis examples below changed between the two (the same inputs are in test/spec.json with
%% the 0.31.2 expectation, which this library passes), and the two task-list examples are marked
%% "disabled" in the spec itself (equivalent HTML with a different attribute order).
gfm_full_spec_test() ->
    {ok, Bin} = file:read_file(data_path("gfm_all.json")),
    KnownN = [398, 426, 434, 435, 436, 473, 474, 475, 477, 279, 280],
    Bad = [
        {N, Md, Got}
     || #{<<"n">> := N, <<"ext">> := Ext, <<"markdown">> := Md, <<"html">> := Exp} <- json:decode(
            Bin
        ),
        not lists:member(N, KnownN),
        Got <- [
            erlmark:to_html(
                Md,
                case Ext of
                    <<"autolink">> -> [{extensions, [autolink]}];
                    <<"tagfilter">> -> [{extensions, [tagfilter]}];
                    _ -> []
                end
            )
        ],
        Got =/= Exp
    ],
    ?assertEqual([], Bad).
