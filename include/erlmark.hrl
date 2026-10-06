-define(IS_PUNCT(C),
    ((C >= 33 andalso C =< 47) orelse (C >= 58 andalso C =< 64) orelse
        (C >= 91 andalso C =< 96) orelse (C >= 123 andalso C =< 126))
).
-define(IS_LETTER(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z))).
-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).
-define(IS_ALNUM(C), (?IS_LETTER(C) orelse ?IS_DIGIT(C))).
-define(IS_WS(C), (C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r orelse C =:= $\f)).
-define(IS_SP(C), (C =:= $\s orelse C =:= $\t)).
