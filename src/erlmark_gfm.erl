%% @doc Opt-in GFM extensions that are not part of the default converter:
%% extended autolinks and the tagfilter. Nothing here runs unless the caller passes
%% `{extensions, [...]}' to `erlmark:to_html/2', so the default path pays nothing.
%%
%% Autolinks work in two passes around the normal inline parser. `pre/1' replaces
%% each bare URL / e-mail address in a paragraph's source by an inert placeholder
%% (control byte 1, a kind letter, the hex of the original text, control byte 2).
%% The inline parser treats it as ordinary text, so emphasis, code spans and links
%% behave as usual. `post/1' then turns every placeholder in the rendered HTML into
%% a link, unless it ended up inside a tag, a link or a code span, in which case the
%% original text is restored.
-module(erlmark_gfm).

-export([pre/1, post/1, tagfilter/1]).

-define(IS_ALNUM(C),
    ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9))
).

%%--------------------------------------------------------------------
%% Tagfilter
%%--------------------------------------------------------------------

%% Every `<' in the output starts a tag (text `<' is always escaped), so one pass
%% over the finished HTML is enough.
-spec tagfilter(binary()) -> binary().
tagfilter(Html) ->
    case binary:match(Html, <<"<">>) of
        nomatch ->
            Html;
        _ ->
            re:replace(
                Html,
                "<(?=/?(?:title|textarea|style|xmp|iframe|noembed|noframes|script|plaintext)(?:[\\s/>]|$))",
                "\\&lt;",
                [global, caseless, {return, binary}]
            )
    end.

%%--------------------------------------------------------------------
%% Autolinks: pre pass (source -> source with placeholders)
%%--------------------------------------------------------------------

-spec pre(binary()) -> binary().
pre(Src) ->
    case binary:matches(Src, [<<"www.">>, <<"://">>, <<"@">>]) of
        [] ->
            Src;
        Ms ->
            case binary:match(Src, [<<1>>, <<2>>]) of
                nomatch -> iolist_to_binary(scan(Ms, Src, 0, []));
                _ -> Src
            end
    end.

%% Pos is the end of the last consumed candidate; Acc is the output built in reverse.
scan([], Src, Pos, Acc) ->
    lists:reverse([tail(Src, Pos) | Acc]);
scan([{P, L} | Ms], Src, Pos, Acc) ->
    case candidate(Src, P, L, Pos) of
        {Start, End, Kind} when Start >= Pos ->
            Text = binary:part(Src, Start, End - Start),
            Ph = [1, Kind, binary:encode_hex(Text), 2],
            scan(
                drop_until(Ms, End),
                Src,
                End,
                [Ph, binary:part(Src, Pos, Start - Pos) | Acc]
            );
        _ ->
            scan(Ms, Src, Pos, Acc)
    end.

tail(Src, Pos) -> binary:part(Src, Pos, byte_size(Src) - Pos).

drop_until([{P, _} | T], End) when P < End -> drop_until(T, End);
drop_until(Ms, _) -> Ms.

%% -> {Start, End, Kind} | none.  Kind: $w (www.), $u (scheme://), $e (e-mail)

%% "www."
candidate(Src, P, 4, Pos) ->
    case boundary(Src, P) andalso P >= Pos andalso not in_dest(Src, P) of
        true ->
            case domain_end(Src, P + 4, www) of
                none -> none;
                DEnd -> finish(Src, P, DEnd, $w)
            end;
        false ->
            none
    end;
%% "://"
candidate(Src, P, 3, Pos) ->
    {Start, Scheme} = scheme_before(Src, P, Pos),
    case
        lists:member(Scheme, [<<"http">>, <<"https">>, <<"ftp">>]) andalso
            boundary(Src, Start) andalso not in_dest(Src, Start)
    of
        true ->
            case domain_end(Src, P + 3, url) of
                none -> none;
                DEnd -> finish(Src, Start, DEnd, $u)
            end;
        false ->
            none
    end;
%% "@"
candidate(Src, P, 1, Pos) ->
    Start = local_start(Src, P, Pos),
    case Start < P andalso not preceded_by(Src, Start, $<) andalso not in_dest(Src, Start) of
        true -> email_end(Src, Start, P + 1);
        false -> none
    end.

%% A bare URL may start at the beginning of the text, after whitespace, or after
%% one of * _ ~ ( (and after > so that it can follow an inline HTML tag).
boundary(_Src, 0) ->
    true;
boundary(Src, P) ->
    C = binary:at(Src, P - 1),
    C =:= $\s orelse C =:= $\n orelse C =:= $\t orelse C =:= $* orelse C =:= $_ orelse
        C =:= $~ orelse C =:= $( orelse C =:= $>.

preceded_by(_Src, 0, _) -> false;
preceded_by(Src, P, C) -> binary:at(Src, P - 1) =:= C.

%% `](' directly before: it would be a link destination, which must stay as is.
in_dest(Src, P) when P >= 2 -> binary:part(Src, P - 2, 2) =:= <<"](">>;
in_dest(_, _) -> false.

scheme_before(Src, P, Pos) -> scheme_before(Src, P, P, Pos).
scheme_before(Src, S, P, Pos) when S > Pos ->
    C = binary:at(Src, S - 1),
    case (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) of
        true -> scheme_before(Src, S - 1, P, Pos);
        false -> {S, binary:part(Src, S, P - S)}
    end;
scheme_before(Src, S, P, _) ->
    {S, binary:part(Src, S, P - S)}.

local_start(Src, P, Pos) when P > Pos ->
    C = binary:at(Src, P - 1),
    case ?IS_ALNUM(C) orelse C =:= $. orelse C =:= $_ orelse C =:= $+ orelse C =:= $- of
        true -> local_start(Src, P - 1, Pos);
        false -> P
    end;
local_start(_, P, _) ->
    P.

%% End of the host name (letters, digits, `-', `_', `.'). For `www' the part after
%% the prefix only needs to be non-empty; for a scheme URL it needs a period.
%% Underscores are not allowed in the last two labels.
domain_end(Src, From, Mode) ->
    End = host_end(Src, From),
    Host = binary:part(Src, From, End - From),
    Labels = binary:split(Host, <<".">>, [global]),
    Last2 = lists:nthtail(max(0, length(Labels) - 2), Labels),
    HasDot = length(Labels) > 1,
    Ok =
        Host =/= <<>> andalso
            lists:all(fun(L) -> binary:match(L, <<"_">>) =:= nomatch end, Last2) andalso
            (Mode =:= www orelse HasDot),
    case Ok of
        true -> End;
        false -> none
    end.

host_end(Src, P) when P < byte_size(Src) ->
    C = binary:at(Src, P),
    case ?IS_ALNUM(C) orelse C =:= $- orelse C =:= $_ orelse C =:= $. of
        true -> host_end(Src, P + 1);
        false -> P
    end;
host_end(_, P) ->
    P.

%% Extend over the path (up to whitespace, `<' or a control byte), then trim.
finish(Src, Start, DEnd, Kind) ->
    {Start, trim(Src, Start, path_end(Src, DEnd)), Kind}.

path_end(Src, P) when P < byte_size(Src) ->
    C = binary:at(Src, P),
    case C =< 32 orelse C =:= $< of
        true -> P;
        false -> path_end(Src, P + 1)
    end;
path_end(_, P) ->
    P.

trim(Src, Start, End) when End > Start ->
    C = binary:at(Src, End - 1),
    if
        C =:= $? orelse C =:= $! orelse C =:= $. orelse C =:= $, orelse C =:= $: orelse
            C =:= $* orelse C =:= $_ orelse C =:= $~ orelse C =:= $' orelse C =:= $" ->
            trim(Src, Start, End - 1);
        C =:= $) ->
            Cur = binary:part(Src, Start, End - Start),
            case count(Cur, $)) > count(Cur, $() of
                true -> trim(Src, Start, End - 1);
                false -> End
            end;
        C =:= $; ->
            case entity_start(Src, Start, End - 1) of
                none -> End;
                S -> trim(Src, Start, S)
            end;
        true ->
            End
    end;
trim(_, _, End) ->
    End.

count(Bin, C) -> length([x || <<X>> <= Bin, X =:= C]).

%% `&' followed by one or more alphanumerics, ending just before the `;' at Semi.
entity_start(Src, Start, Semi) -> entity_start(Src, Start, Semi, Semi).
entity_start(Src, Start, I, Semi) when I > Start ->
    C = binary:at(Src, I - 1),
    if
        C =:= $& ->
            case I < Semi of
                true -> I - 1;
                false -> none
            end;
        ?IS_ALNUM(C) ->
            entity_start(Src, Start, I - 1, Semi);
        true ->
            none
    end;
entity_start(_, _, _, _) ->
    none.

email_end(Src, Start, From) ->
    End0 = email_domain_end(Src, From),
    End = strip_dots(Src, From, End0),
    Domain = binary:part(Src, From, End - From),
    Last =
        case Domain of
            <<>> -> $.;
            _ -> binary:last(Domain)
        end,
    case
        binary:match(Domain, <<".">>) =/= nomatch andalso Last =/= $- andalso Last =/= $_ andalso
            ?IS_ALNUM(binary:first(Domain))
    of
        true -> {Start, End, $e};
        false -> none
    end.

email_domain_end(Src, P) when P < byte_size(Src) ->
    C = binary:at(Src, P),
    case ?IS_ALNUM(C) orelse C =:= $- orelse C =:= $_ orelse C =:= $. of
        true -> email_domain_end(Src, P + 1);
        false -> P
    end;
email_domain_end(_, P) ->
    P.

strip_dots(Src, From, End) when End > From ->
    case binary:at(Src, End - 1) of
        $. -> strip_dots(Src, From, End - 1);
        _ -> End
    end;
strip_dots(_, _, End) ->
    End.

%%--------------------------------------------------------------------
%% Autolinks: post pass (HTML with placeholders -> HTML)
%%--------------------------------------------------------------------

-spec post(binary()) -> binary().
post(Html) ->
    case binary:split(Html, <<1>>, [global]) of
        [Only] ->
            Only;
        [First | Rest] ->
            iolist_to_binary(post(Rest, update({false, false, false}, First), [First]))
    end.

%% State is {InTag, InAnchor, InCode}, advanced over the text before each placeholder.
post([], _St, Acc) ->
    lists:reverse(Acc);
post([Piece | Rest], St, Acc) ->
    <<Kind, Tail/binary>> = Piece,
    [Hex, After] = binary:split(Tail, <<2>>),
    Text = binary:decode_hex(Hex),
    {InTag, InAnchor, InCode} = St,
    Out =
        case InTag orelse InAnchor orelse InCode of
            true -> erlmark_util:esc(Text);
            false -> to_link(Kind, Text)
        end,
    post(Rest, update(St, After), [After, Out | Acc]).

to_link(Kind, Text) ->
    Href =
        case Kind of
            $w -> <<"http://", Text/binary>>;
            $u -> Text;
            $e -> <<"mailto:", Text/binary>>
        end,
    [<<"<a href=\"">>, erlmark_util:url(Href), <<"\">">>, erlmark_util:esc(Text), <<"</a>">>].

update(St, Bin) ->
    Ms = binary:matches(Bin, [
        <<"<a ">>, <<"<a>">>, <<"</a>">>, <<"<code">>, <<"</code>">>, <<"<">>, <<">">>
    ]),
    lists:foldl(
        fun({P, L}, {_, A, C}) ->
            case binary:part(Bin, P, L) of
                <<"<a ">> -> {true, true, C};
                <<"<a>">> -> {false, true, C};
                <<"</a>">> -> {false, false, C};
                <<"<code">> -> {true, A, true};
                <<"</code>">> -> {false, A, false};
                <<"<">> -> {true, A, C};
                <<">">> -> {false, A, C}
            end
        end,
        St,
        Ms
    ).
