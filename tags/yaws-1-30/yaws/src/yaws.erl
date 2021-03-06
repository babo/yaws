%%%----------------------------------------------------------------------
%%% File    : yaws.erl
%%% Author  : Claes Wikstrom <klacke@bluetail.com>
%%% Purpose : 
%%% Created : 16 Jan 2002 by Claes Wikstrom <klacke@bluetail.com>
%%%----------------------------------------------------------------------

-module(yaws).
-author('klacke@bluetail.com').

-include_lib("yaws/include/yaws.hrl").
-include_lib("yaws/include/yaws_api.hrl").
-include("yaws_debug.hrl").



-include_lib("kernel/include/file.hrl").

-compile(export_all).
-import(lists, [reverse/1, reverse/2]).

%%-export([Function/Arity, ...]).


start() ->
    application:start(yaws, permanent).
stop() ->
    application:stop(yaws).

hup(Sock) ->
    spawn(fun() ->
		  group_leader(whereis(user), self()),
		  dohup(Sock)
	  end).

dohup(Sock) ->
    io:format("in dohup~n", []),
    {Debug, Trace, TraceOut, Conf, _RunMod, _Embed} = 
	yaws_server:get_app_args(),
    Res = (catch case yaws_config:load(Conf, Trace, TraceOut, Debug) of
		     {ok, Gconf, Sconfs} ->
			 yaws_api:setconf(Gconf, Sconfs);
		     Err ->
			 Err
		 end),
    gen_tcp:send(Sock, io_lib:format("hupped: ~p~n", [Res])),
    gen_tcp:close(Sock).
    

%% use from cli only
restart() ->
    stop(),
    load(),
    start().


modules() ->
    application:load(yaws),
    M = case application:get_all_key(yaws) of
	    {ok, L} ->
		case lists:keysearch(modules, 1, L) of
		    {value, {modules, Mods}} ->
			Mods;
		    _ ->
			[]
		end;
	    _ ->
		[]
	end,
    M.


load() ->
    load(modules()).
load(M) ->
    lists:foreach(fun(Mod) ->
			  ?Debug("Load ~p~n", [Mod]),
			  c:l(Mod)
		  end, M).

%%% misc funcs
first(_F, []) ->
    false;
first(F, [H|T]) ->
    case F(H) of
	{ok, Val} ->
	    {ok, Val, H};
	ok ->
	    {ok, ok, H};
	_ ->
	    first(F, T)
    end.

	    
elog(F, As) ->
    error_logger:format(F, As).



filesize(Fname) ->
    case file:read_file_info(Fname) of
	{ok, FI} when FI#file_info.type == regular ->
	    {ok, FI#file_info.size};
	{ok, FI} ->
	    {error,  FI#file_info.type};
	Err ->
	    Err
    end.
%% 
upto(0, []) ->
    [];
upto(_I, []) ->
    [];
upto(0, _) ->
    " ....";
upto(_I, [0|_]) ->
    " ....";
upto(I,[H|T]) ->
    [H|upto(I-1, T)].
zip([H1|T1], [H2|T2]) ->
    [{H1, H2} |zip(T1, T2)];
zip([], []) ->
    [].





%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Date and Time functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

date_and_time() ->
    case catch erlang:now() of
	{'EXIT', _} -> % We don't have info about UTC
	    short_time(calendar:local_time());
	Now ->
	    UTC = calendar:now_to_universal_time(Now),
	    Local = calendar:universal_time_to_local_time(UTC),
	    date_and_time(Local, UTC)
    end.
 
date_and_time(Local, UTC) ->
    DiffSecs = calendar:datetime_to_gregorian_seconds(Local) -
	       calendar:datetime_to_gregorian_seconds(UTC),
    short_time(Local) ++ diff(DiffSecs).

%% short_time

short_time({{Y,M,D},{H,Mi,S}}) ->
    [y1(Y), y2(Y), M, D, H, Mi, S].

%% Format date according to ISO 8601
date_and_time_to_string(DAT) ->
    case validate_date_and_time(DAT) of
	true ->
	    dat2str(DAT);
	false ->
	    exit({badarg, {?MODULE, date_and_time_to_string, [DAT]}})
    end.

universal_time_to_string(UTC) ->
    Local = calendar:universal_time_to_local_time(UTC),
    DT = local_time_to_date_and_time(Local),
    date_and_time_to_string(DT).


dat2str([Y1,Y2, Mo, D, H, M, S | Diff]) ->
    lists:flatten(
      io_lib:format("~s ~w-~2.2.0w-~2.2.0w,~2.2.0w:~2.2.0w:~2.2.0w",
		    [weekday(Y1,Y2,Mo,D), y(Y1,Y2),Mo,D,H,M,S]) ++
      case Diff of
	  [Sign,Hd,Md] ->
	      io_lib:format("~c~2.2.0w~2.2.0w",
			    [Sign,Hd,Md]);
	  _ -> []
      end).

weekday(Y1,Y2,Mo,D) ->
    int_to_wd(calendar:day_of_the_week(Y1*256+Y2,Mo,D)).

int_to_wd(1) ->
    "Mon";
int_to_wd(2) ->
    "Tue";
int_to_wd(3) ->
    "Wed";
int_to_wd(4) ->
    "Thu";
int_to_wd(5) ->
    "Fri";
int_to_wd(6) ->
    "Sat";
int_to_wd(7) ->
    "Sun".

y1(Y) -> (Y bsr 8) band 255.
y2(Y) -> Y band 255.

y(Y1, Y2) -> 256 * Y1 + Y2.
    
diff(Secs) ->
    case calendar:seconds_to_daystime(Secs) of
	{0, {H, M,_}} ->
	    [$+, H, M];
	{-1, _} ->
	    {0, {H, M, _}} = calendar:seconds_to_daystime(-Secs),
	    [$-, H, M]
    end.

universal_time_to_date_and_time(UTC) ->
    short_time(UTC) ++ [$+, 0, 0].

local_time_to_date_and_time(Local) ->
    UTC = calendar:local_time_to_universal_time(Local),
    date_and_time(Local, UTC).

date_and_time_to_universal_time([Y1,Y2, Mo, D, H, M, S]) ->
    %% Local time specified, convert to UTC
    Local = {{y(Y1,Y2), Mo, D}, {H, M, S}},
    calendar:local_time_to_universal_time(Local);
date_and_time_to_universal_time([Y1,Y2, Mo, D, H, M, S, Sign, Hd, Md]) ->
    %% Time specified as local time + diff from UTC. Conv to UTC.
    Local = {{y(Y1,Y2), Mo, D}, {H, M, S}},
    LocalSecs = calendar:datetime_to_gregorian_seconds(Local),
    Diff = (Hd*60 + Md)*60,
    UTCSecs = if Sign == $+ -> LocalSecs - Diff;
		 Sign == $- -> LocalSecs + Diff
	      end,
    calendar:gregorian_seconds_to_datetime(UTCSecs).

validate_date_and_time([Y1,Y2, Mo, D, H, M, S | Diff]) 
  when 0 =< Y1, 0 =< Y2, 0 < Mo, Mo < 13, 0 < D, D < 32, 0 =< H,
       H < 24, 0 =< M, M < 60, 0 =< S, S < 61  ->
    case check_diff(Diff) of
	true ->
	    calendar:valid_date(y(Y1,Y2), Mo, D);
	false ->
	    false
    end;
validate_date_and_time(_) -> false.

check_diff([]) -> true;
check_diff([$+, H, M]) when 0 =< H, H < 12, 0 =< M, M < 60 -> true;
check_diff([$-, H, M]) when 0 =< H, H < 12, 0 =< M, M < 60 -> true;
check_diff(_) -> false.



%% to_string

to_string(X) when float(X) ->
    io_lib:format("~.2.0f",[X]);
to_string(X) when integer(X) ->
    integer_to_list(X);
to_string(X) when atom(X) ->
    atom_to_list(X);
to_string(X) ->
    lists:concat([X]).

%%


to_list(L) when list(L) ->
    L;
to_list(A) when atom(A) ->
    atom_to_list(A).


lowercase([C|S]) -> [lowercase(C)|S];
lowercase(C) when C>=$A, C=<$Z -> C+32;
lowercase(C) -> C.

%%

uppercase([C|S]) -> [uppercase(C)|S];
uppercase(C) when C>=$a, C=<$z -> C-32;
uppercase(C) -> C.

%%

lowercase_string(String) ->
    lists:map(fun(X) -> lowercase(X) end, String).

%% integer_to_hex

integer_to_hex(I) when I<10 ->
    integer_to_list(I);
integer_to_hex(I) when I<16 ->
    [I-10+$A];
integer_to_hex(I) when I>=16 ->
    N = trunc(I/16),
    integer_to_hex(N) ++ integer_to_hex(I rem 16).

%% hex_to_integer

hex_to_integer(Hex) ->
    DEHEX = fun (H) when H >= $a, H =< $f -> H - $a + 10;
		(H) when H >= $A, H =< $F -> H - $A + 10;
		(H) when H >= $0, H =< $9 -> H - $0
	    end,
    lists:foldl(fun(E, Acc) -> Acc*16+DEHEX(E) end, 0, Hex).

%% string_to_hex

string_to_hex(String) ->
    HEXC = fun (D) when D > 9 -> $a + D - 10;
	       (D) ->            $0 + D
	   end,
    lists:foldr(fun (E, Acc) ->
			[HEXC(E div 16),HEXC(E rem 16)|Acc]
		end, [],
		String).


%% hex_to_string

hex_to_string(Hex) ->
    DEHEX = fun (H) when H >= $a -> H - $a + 10;
		(H) when H >= $A -> H - $A + 10;
		(H) ->              H - $0
	    end,
    {String, _} =
	lists:foldr(fun (E, {Acc, nolow}) ->
			    {Acc, DEHEX(E)};
			(E, {Acc, LO})  ->
			    {[DEHEX(E)*16+LO|Acc], nolow}
		    end, {[], nolow},
		    Hex),
    String.


%% mk_list

mk_list([]) ->
    [];
mk_list([X]) ->
    to_string(X);
mk_list([X|Rest]) ->
    [to_string(X)," ",mk_list(Rest)].



universal_time_as_string() ->
    time_to_string(calendar:universal_time(), "GMT").
local_time_as_gmt_string(LocalTime) ->
    time_to_string(calendar:local_time_to_universal_time(LocalTime),"GMT").


time_to_string( {{Year, Month, Day}, {Hour, Min, Sec}}, Zone) ->
    io_lib:format("~s, ~s ~s ~w ~s:~s:~s ~s",
		  [day(Year, Month, Day),
		   mk2(Day), month(Month), Year,
		   mk2(Hour), mk2(Min), mk2(Sec), Zone]).



mk2(I) when I < 10 ->
    [$0 | integer_to_list(I)];
mk2(I) ->
    integer_to_list(I).

day(Year, Month, Day) ->
    int_to_wd(calendar:day_of_the_week(Year, Month, Day)).

month(1) ->
    "Jan";
month(2) ->
    "Feb";
month(3) ->
    "Mar";
month(4) ->
    "Apr";
month(5) ->
    "May";
month(6) ->
    "Jun";
month(7) ->
    "Jul";
month(8) ->
    "Aug";
month(9) ->
    "Sep";
month(10) ->
    "Oct";
month(11) ->
    "Nov";
month(12) ->
    "Dec".



month_str_to_int("Jan") ->
    1;
month_str_to_int("Jun") ->
    6;
month_str_to_int("Jul") ->
    7;
month_str_to_int("Feb") ->
    2;
month_str_to_int("Mar") ->
    3;
month_str_to_int("Apr") ->
    4;
month_str_to_int("May") ->
    5;
month_str_to_int("Aug") ->
    8;
month_str_to_int("Sep") ->
    7;
month_str_to_int("Oct") ->
    10;
month_str_to_int("Nov") ->
    11;
month_str_to_int("Dec") ->
    12.



day_str_to_int("Mon") ->
    1;
day_str_to_int("Tue") ->
    2;
day_str_to_int("Wed") ->
    3;
day_str_to_int("Thu") ->
    4;
day_str_to_int("Fri") ->
    5;
day_str_to_int("Sat") ->
    6;
day_str_to_int("Sun") ->
    7.


%% Wed, 23 Jan 2002 19:07:44 GMT

stringdate_to_datetime([$ |T]) ->
    stringdate_to_datetime(T);
stringdate_to_datetime([_D1, _D2, _D3, $\,, $ |Tail]) ->
    stringdate_to_datetime1(Tail).

stringdate_to_datetime1([A, B, $\s |T]) ->
    stringdate_to_datetime2(T, list_to_integer([A,B]));

stringdate_to_datetime1([A, $\s |T]) ->
    stringdate_to_datetime2(T, list_to_integer([A])).



stringdate_to_datetime2([M1, M2, M3, $\s , Y1, Y2, Y3, Y4, $\s ,
			 H1, H2, $:, Min1, Min2,$:, 
			 S1, S2,$\s ,$G, $M, $T|_], Day) ->
    {{list_to_integer([Y1,Y2,Y3,Y4]), 
      month_str_to_int([M1, M2, M3]), Day},
     {list_to_integer([H1, H2]),
      list_to_integer([Min1, Min2]),
      list_to_integer([S1, S2])}}.




%% used by If-Modified-Since header code
is_modified_p(FI, UTC_string) ->
    case catch stringdate_to_datetime(UTC_string) of
	{'EXIT', _ } ->
	    true;
	UTC ->
	    Mtime = FI#file_info.mtime,
	    MtimeUTC = calendar:local_time_to_universal_time(Mtime),
	    MtimeUTC > UTC
    end.




ticker(Time, Msg) ->
    S = self(),
    spawn_link(yaws, ticker, [Time, S, Msg]).
ticker(Time, To, Msg) ->
    process_flag(trap_exit, true),
    yaws_ticker:ticker(Time, To, Msg).


fmt_ip({A,B,C,D}) ->
    [integer_to_list(A), $.,
     integer_to_list(B), $.,
     integer_to_list(C), $.,
     integer_to_list(D)].



parse_ip(Val) ->
    case string:tokens(Val, [$.]) of
	Nums = [_X1, _X2, _X3,_X4] ->
	    L = lists:map(
		  fun(S) -> (catch list_to_integer(S)) end, 
		  Nums),
	    case lists:zf(fun(I) when integer(I),
				      0 =< I,
				      I =< 255 ->
				  true;
			     (_) ->
				  false
			  end, L) of
		L2 when length(L2) == 4 ->
		    list_to_tuple(L2);
		_ ->
		    error
	    end;
	_ ->
	    error
    end.






address(GConf, Sconf) ->
%     ?F("<address> ~s Server at ~s:~w </address>",
%       [
%	GConf#gconf.yaws,
%	yaws:fmt_ip(Sconf#sconf.listen),
%	Sconf#sconf.port]).
     ?F("<address> ~s Server at ~s </address>",
       [
	GConf#gconf.yaws,
	Sconf#sconf.servername]).




is_space($\s) ->
    true;
is_space($\r) ->
    true;
is_space($\n) ->
    true;
is_space($\r) ->
    true;
is_space(_) ->
    false.


strip_spaces(String) ->
    strip_spaces(String, both).

strip_spaces(String, left) ->
    drop_spaces(String);
strip_spaces(String, right) ->
    lists:reverse(drop_spaces(lists:reverse(String)));
strip_spaces(String, both) ->
    strip_spaces(drop_spaces(String), right).

drop_spaces([]) ->
    [];
drop_spaces(YS=[X|XS]) ->
    case is_space(X) of
	true ->
	    drop_spaces(XS);
	false ->
	    YS
    end.


%%% basic uuencode and decode functionality    

list_to_uue(L) -> list_to_uue(L, []).

list_to_uue([], Out) ->
    reverse([$\n,enc(0)|Out]);
list_to_uue(L, Out) ->
    {L45, L1} = get_45(L),
    Encoded = encode_line(L45),
    list_to_uue(L1, reverse(Encoded, Out)).

uue_to_list(L) -> 
    uue_to_list(L, []).

uue_to_list([], Out) ->
    reverse(Out);
uue_to_list(L, Out) ->
    {Decoded, L1} = decode_line(L),
    uue_to_list(L1, reverse(Decoded, Out)).

encode_line(L) ->
    [enc(length(L))|encode_line1(L)].

encode_line1([C0, C1, C2|T]) ->
    Char1 = enc(C0 bsr 2),
    Char2 = enc((C0 bsl 4) band 8#60 bor (C1 bsr 4) band 8#17),
    Char3 = enc((C1 bsl 2) band 8#74 bor (C2 bsr 6) band 8#3),
    Char4 = enc(C2 band 8#77),
    [Char1,Char2,Char3,Char4|encode_line1(T)];
encode_line1([C1, C2]) -> encode_line1([C1, C2, 0]);
encode_line1([C])      -> encode_line1([C,0,0]);
encode_line1([])       -> [$\n].

decode_line([H|T]) ->
    case dec(H) of 
        0   -> {[], []};
        Len -> decode_line(T, Len, [])
    end.

decode_line([P0,P1,P2,P3|T], N, Out) when N >= 3->
    Char1 = 16#FF band ((dec(P0) bsl 2) bor (dec(P1) bsr 4)),
    Char2 = 16#FF band ((dec(P1) bsl 4) bor (dec(P2) bsr 2)),
    Char3 = 16#FF band ((dec(P2) bsl 6) bor dec(P3)),
    decode_line(T, N-3, [Char3,Char2,Char1|Out]);
decode_line([P0,P1,P2,_|T], 2, Out) ->
    Char1  = 16#FF band ((dec(P0) bsl 2) bor (dec(P1) bsr 4)),
    Char2  = 16#FF band ((dec(P1) bsl 4) bor (dec(P2) bsr 2)),
    {reverse([Char2,Char1|Out]), tl(T)};
decode_line([P0,P1,_,_|T], 1, Out) ->
    Char1  = 16#FF band ((dec(P0) bsl 2) bor (dec(P1) bsr 4)),
    {reverse([Char1|Out]), tl(T)};
decode_line(T, 0, Out) ->
    {reverse(Out), tl(T)}.

get_45(L) -> get_45(L, 45, []).

get_45(L, 0, F)     -> {reverse(F), L};
get_45([H|T], N, L) -> get_45(T, N-1, [H|L]);
get_45([], _N, L)    -> {reverse(L), []}.

%% enc/1 is the basic 1 character encoding function to make a char printing
%% dec/1 is the inverse

enc(0) -> $`;
enc(C) -> (C band 8#77) + $ .

dec(Char) -> (Char - $ ) band 8#77.

to_octal(I) -> reverse(to_octal1(I)).

to_octal1(0) ->  [];
to_octal1(I) ->  [$0 + I band 7|to_octal1(I bsr 3)].

oct_to_dig(O) -> oct_to_dig(O, 0).

oct_to_dig([], D)    -> D;
oct_to_dig([H|T], D) -> oct_to_dig(T, D*8 + H - $0).



printversion() ->
    io:format("Yaws ~s~n", [yaws_vsn:version()]),
    init:stop().

%% our default arg rewriteer does's of cource nothing
arg_rewrite(A) ->
    A.



to_lowerchar(C) when C >= $A, C =< $Z ->
    C+($a-$A);
to_lowerchar(C) ->
    C.

to_lower([C|Cs]) when C >= $A, C =< $Z ->
    [C+($a-$A)|to_lower(Cs)];
to_lower([C|Cs]) ->
    [C|to_lower(Cs)];
to_lower([]) ->
    [].



funreverse(List, Fun) ->
    funreverse(List, Fun, []).

funreverse([H|T], Fun, Ack) ->
    funreverse(T, Fun, [Fun(H)|Ack]);
funreverse([], _Fun, Ack) ->
    Ack.


%% splits Str in two parts
%% First part leading Upto SubStr and remaining part after
split_at(Str, Substr) ->
    split_at(Str, Substr,[]).

split_at(Str, Substr, Ack) ->
    case is_prefix(Substr, Str) of
	{true, Tail} ->
	    {lists:reverse(Ack), Tail};
	false ->
	    case Str of
		[] ->
		    {lists:reverse(Ack), []};
		[H|T] ->
		    split_at(T, Substr, [H|Ack])
	    end
    end.


%% is arg1 a prefix of arg2
is_prefix([H|T1], [H|T2]) ->
    is_prefix(T1, T2);
is_prefix([], T) ->
    {true, T};
is_prefix(_,_) ->
    false.

    
%% Split a string of words seperated by Sep into a list of words and
%% strip off white space.
%%
%% HTML semantics are used, such that empty words are omitted.


split_sep(undefined, _Sep) ->
    [];
split_sep(L, Sep) ->
    case drop_spaces(L) of
	[] -> [];
	[Sep|T] -> split_sep(T, Sep);
	[C|T]   -> split_sep(T, Sep, [C], [])
    end.

split_sep([], _Sep, AccL) ->
    lists:reverse(AccL);
split_sep([Sep|T], Sep, AccL) ->
    split_sep(T, Sep, AccL);
split_sep([C|T], Sep, AccL) ->
    split_sep(T, Sep, [C], AccL).

split_sep([], _Sep, AccW, AccL) ->
    lists:reverse([lists:reverse(drop_spaces(AccW))|AccL]);
split_sep([Sep|Tail], Sep, AccW, AccL) ->
    split_sep(drop_spaces(Tail), 
	      Sep, 
	      [lists:reverse(drop_spaces(AccW))|AccL]);
split_sep([C|Tail], Sep, AccW, AccL) ->
    split_sep(Tail, Sep, [C|AccW], AccL).
		      
		    


%% imperative out header management

outh_set_status_code(Code) ->
    put(outh, (get(outh))#outh{status = Code}),
    ok.

outh_set_non_cacheable(_Version) ->
    put(outh, (get(outh))#outh{cache_control = "Cache-Control: no-cache\r\n"}),
    ok.

outh_set_content_type(Mime) ->
    put(outh, (get(outh))#outh{content_type = 
			       make_content_type_header(Mime)}),
    ok.

outh_set_cookie(C) ->
    put(outh, (get(outh))#outh{set_cookie = ["Set-Cookie: " , C, "\r\n"]}),
    ok.


outh_clear_headers() ->
    H = get(outh),
    put(outh, #outh{status = H#outh.status,
		    doclose = true,
		    chunked = false,
		    connection  = make_connection_close_header(true)}),
    ok.


outh_set_static_headers(Req, UT, Headers) ->
    outh_set_static_headers(Req, UT, Headers, all).

outh_set_static_headers(Req, UT, Headers, Range) ->
    H = get(outh),
    {DoClose, _Chunked} = dcc(Req, Headers),
    H2 = H#outh{
	   status = case Range of
			all -> 200;
			{fromto, _From, _To, _Tot} -> 206
		    end,
	   chunked = false,
	   date = make_date_header(),
	   server = make_server_header(),
	   last_modified = make_last_modified_header(UT#urltype.finfo),
	   etag = make_etag_header(UT#urltype.finfo),
	   content_range = make_content_range_header(Range),
	   content_length = make_content_length_header(
			      case Range of
				  all ->
				      UT#urltype.finfo;
				  {fromto, From, To, _Tot} ->
				      To - From + 1
			      end
			     ),
	   content_type = make_content_type_header(UT#urltype.mime),
	   connection  = make_connection_close_header(DoClose),
	   doclose = DoClose,
	   contlen = (UT#urltype.finfo)#file_info.size
	  },
    put(outh, H2).

outh_set_304_headers(Req, UT, Headers) ->
     H = get(outh),
     {DoClose, _Chunked} = dcc(Req, Headers),
     H2 = H#outh{
          status = 304,
          chunked = false,
          date = make_date_header(),
          server = make_server_header(),
          last_modified = make_last_modified_header(UT#urltype.finfo),
          etag = make_etag_header(UT#urltype.finfo),
          content_length = make_content_length_header(0),
          connection  = make_connection_close_header(DoClose),
          doclose = DoClose,
          contlen = 0
              },
     put(outh, H2).

outh_set_dyn_headers(Req, Headers) ->
    H = get(outh),
    {DoClose, Chunked} = dcc(Req, Headers),
    H2 = H#outh{
	   status = 200,
	   date = make_date_header(),
	   server = make_server_header(),
	   connection = make_connection_close_header(DoClose),
	   content_type = make_content_type_header("text/html"),
	   doclose = DoClose,
	   chunked = Chunked,
	   transfer_encoding = 
	       make_transfer_encoding_chunked_header(Chunked)},
    
    put(outh, H2).


outh_set_connection_close(Bool) ->
    H = get(outh),
    H2 = H#outh{connection = make_connection_close_header(Bool),
		doclose = Bool},
    put(outh, H2),
    ok.


outh_set_content_length(Int) ->
    H = get(outh),
    H2 = H#outh{content_length = make_content_length_header(Int)},
    put(outh, H2).



outh_set_dcc(Req, Headers) ->
    H = get(outh),
    {DoClose, Chunked} = dcc(Req, Headers),
    H2 = H#outh{connection = make_connection_close_header(DoClose),
		doclose = DoClose,
		chunked = Chunked,
		transfer_encoding = 
		make_transfer_encoding_chunked_header(Chunked)},
    put(outh, H2).


%% can only turn if off, not on.
%% if it allready is off, it's off because the cli headers forced us.

outh_set_transfer_encoding_off() ->
    H = get(outh),
    H2 = H#outh{chunked = false,
		transfer_encoding = 
		make_transfer_encoding_chunked_header(false)},
    put(outh, H2).




dcc(Req, Headers) ->
    DoClose = case Req#http_request.version of
		  {1, 0} -> 
		      case Headers#headers.keep_alive of
			  undefined ->
			      true;
			  _ ->
			      false
		      end;
		  {1, 1} ->
		      false;
		  {0,9} ->
		      true
	      end,
    Chunked = case Req#http_request.version of
		  {1, 0} ->
		      false;
		  {1,1} ->
		      true;
		  {0,9} ->
		      false
	      end,
    {DoClose, Chunked}.


		  


%%
%% The following all make_ function return an actual header string
%%

make_allow_header() ->
    "Allow: GET, POST, PUT, OPTIONS, HEAD\r\n".
make_server_header() ->
    ["Server: Yaws/", yaws_vsn:version(), " Yet Another Web Server\r\n"].



make_last_modified_header(FI) ->
    N = element(2, now()),
    Inode = FI#file_info.inode,  %% unix only
    case get({last_modified, Inode}) of
	{Str, Secs} when N < (Secs+10) ->
	    Str;
	_ ->
	    S = do_make_last_modified(FI),
	    put({last_modified, Inode}, {S, N}),
	    S
    end.

do_make_last_modified(FI) ->
    Then = FI#file_info.mtime,
    ["Last-Modified: ", yaws:local_time_as_gmt_string(Then), "\r\n"].



make_location_header(Where) ->
    ["Location: ", Where, "\r\n"].


make_etag_header(FI) ->
    ETag = make_etag(FI),
    ["Etag: ", ETag, "\r\n"].

make_etag(FI) ->
    {{Y,M,D}, {H,Min, S}}  = FI#file_info.mtime,
    Inode = FI#file_info.inode,
    %% pack_ints([M, D, H, Min, S, Inode]).
    pack_bin( <<0:6,(Y band 2#11111111):8,M:4,D:5,H:5,Min:6,S:6,Inode:32>> ).

pack_bin(<<_:6,A:6,B:6,C:6,D:6,E:6,F:6,G:6,H:6,I:6,J:6,K:6>>) ->
    [$",
     pc(A),pc(B),pc(C),pc(D),pc(E),pc(F),pc(G),pc(H),pc(I),pc(J),pc(K),
     $"].

%% Like Base64 for no particular reason.
pc(X) when X >= 0, X < 26 -> 
    X + $A;
pc(X) when X >= 26, X < 52 -> 
    X - 26 + $a;
pc(X) when X >= 52, X < 62 ->
    X - 52 + $0;
pc(62) ->
    $+;
pc(63) ->
    $/.

%% This function seems not to be injective. 
%% If the original author agrees to change it to the above,
%% please remove.
%%
%% cschultz
pack_ints(L) ->
    [$" | pack_ints2(L) ].


pack_ints2([0|T]) ->
    pack_ints2(T);
pack_ints2([H|T]) ->
    X = H band 2#11111,
    Val = X + $A,
    V2 = if 
	     Val > $Z, Val < $a ->
		 Val + ($a-$Z);
	     true ->
		 Val
	 end,
    [V2 |pack_ints2([H bsr 5|T])];
pack_ints2([]) ->
    [$"]. %"


make_content_type_header(no_content_type) ->
    undefined;
make_content_type_header(MimeType) ->
    ["Content-Type: ", MimeType, "\r\n"].


make_content_range_header(all) ->
    undefined;
make_content_range_header({fromto, From, To, Tot}) ->
    ["Content-Range: bytes ", 
     integer_to_list(From), $-, integer_to_list(To),
     $/, integer_to_list(Tot), $\r, $\n].

make_content_length_header(Size) when integer(Size) ->
    ["Content-Length: ", integer_to_list(Size), "\r\n"];
make_content_length_header(FI) ->
    Size = FI#file_info.size,
    ["Content-Length: ", integer_to_list(Size), "\r\n"].


make_connection_close_header(true) ->
    "Connection: close\r\n";
make_connection_close_header(false) ->
    undefined.


make_transfer_encoding_chunked_header(true) ->
    "Transfer-Encoding: chunked\r\n";
make_transfer_encoding_chunked_header(false) ->
    undefined.

make_www_authenticate_header(Realm) ->
    ["WWW-Authenticate: Basic realm=\"", Realm, ["\"\r\n"]].


make_date_header() ->
    N = element(2, now()),
    case get(date_header) of
	{Str, Secs} when (Secs+10) > N ->
	    H = ["Date: ", yaws:universal_time_as_string(), "\r\n"],
	    put(date_header, {H, N}),
	    H;
	{Str, Secs} ->
	    Str;
	undefined ->
	    H = ["Date: ", yaws:universal_time_as_string(), "\r\n"],
	    put(date_header, {H, N}),
	    H
    end.



%% access functions into the outh record

outh_get_status_code() ->
    (get(outh))#outh.status.

outh_get_contlen() ->
    (get(outh))#outh.contlen.

outh_get_act_contlen() ->
    (get(outh))#outh.act_contlen.

outh_inc_act_contlen(Int) ->
    O = get(outh),
    case O#outh.act_contlen of
	undefined ->
	    put(outh, O#outh{act_contlen = Int});
	Len ->    
	    put(outh, O#outh{act_contlen = Len + Int})
    end.

outh_get_doclose() ->
    (get(outh))#outh.doclose.

outh_get_chunked() ->
    (get(outh))#outh.chunked.

    

outh_serialize() ->
    H = get(outh),
    Code = case H#outh.status of
	       undefined -> 200;
	       Int -> Int
	   end,
    StatusLine = ["HTTP/1.1 ", integer_to_list(Code), " ",
		  yaws_api:code_to_phrase(Code), "\r\n"],
    Headers = [noundef(H#outh.connection),
	       noundef(H#outh.server),
	       noundef(H#outh.location),
	       noundef(H#outh.cache_control),
	       noundef(H#outh.date),
	       noundef(H#outh.allow),
	       noundef(H#outh.last_modified),
	       noundef(H#outh.etag),
	       noundef(H#outh.content_range),
	       noundef(H#outh.content_length),
	       noundef(H#outh.content_type),
	       noundef(H#outh.set_cookie),
	       noundef(H#outh.transfer_encoding),
	       noundef(H#outh.www_authenticate),
	       noundef(H#outh.other)
	      ],
    {StatusLine, Headers}.
    
	       
noundef(undefined) ->
    [];
noundef(Str) ->
    Str.

	

accumulate_header({X, erase}) when atom(X) ->
    erase_header(X);

accumulate_header({connection, What}) ->
    DC = case What of
	     "close" ->
		 true;
	     _ ->
		 false
	 end,
    H = get(outh),
    put(outh, (H#outh{connection = ["Connection: ", What, "\r\n"],
		      doclose = DC}));

accumulate_header({location, What}) ->
    put(outh, (get(outh))#outh{location = ["Location: " , What, "\r\n"]});

accumulate_header({cache_control, What}) ->
    put(outh, (get(outh))#outh{cache_control = ["Cache-Control: " , What, "\r\n"]});

accumulate_header({set_cookie, What}) ->
    O = get(outh),
    Old = case O#outh.set_cookie of
	      undefined -> "";
	      X -> X
	  end,
    put(outh, O#outh{set_cookie = ["Set-Cookie: " , What, "\r\n"|Old]});

accumulate_header({content_type, What}) ->
    put(outh, (get(outh))#outh{content_type = ["Content-Type: " , What, "\r\n"]});


%% backwards compatible clause
accumulate_header(Str) when list(Str) ->
    H = get(outh),
    Old = case H#outh.other of
	      undefined ->
		  [];
	      V ->
		  V
	  end,
    H2 = H#outh{other = [Str, "\r\n", Old]},
    put(outh, H2).



erase_header(connection) ->
    put(outh, (get(outh))#outh{connection = undefined});
erase_header(cache_control) ->
    put(outh, (get(outh))#outh{cache_control = undefined});
erase_header(set_cookie) ->
    put(outh, (get(outh))#outh{set_cookie = undefined});
erase_header(content_type) ->
    put(outh, (get(outh))#outh{content_type = undefined});
erase_header(location) ->
    put(outh, (get(outh))#outh{location = undefined}).






	
setuser(undefined) ->	     
    ignore;
setuser(User) ->	     
    erl_ddll:load_driver(filename:dirname(code:which(?MODULE)) ++ 
			 "/../priv/", "setuid_drv"),
    P = open_port({spawn, "setuid_drv " ++ [$s|User]}, []),
    receive
	{P, {data, "ok " ++ IntList}} ->
	    {ok, IntList}
    end.

getuid() ->
    erl_ddll:load_driver(filename:dirname(code:which(?MODULE)) ++ 
			 "/../priv/", "setuid_drv"),
    P = open_port({spawn, "setuid_drv g"},[]),
    receive
	{P, {data, "ok " ++ IntList}} ->
	    {ok, IntList}
    end.

idu(User) ->
    erl_ddll:load_driver(filename:dirname(code:which(?MODULE)) ++ 
			 "/../priv/", "setuid_drv"),
    P = open_port({spawn, "setuid_drv " ++ [$u|User]}, []),
    receive
	{P, {data, "ok " ++ IntList}} ->
	    {ok, IntList}
    end.

user_to_home(User) ->
    erl_ddll:load_driver(filename:dirname(code:which(?MODULE)) ++ 
			 "/../priv/", "setuid_drv"),
    P = open_port({spawn, "setuid_drv " ++ [$h|User]}, []),
    receive
	{P, {data, "ok " ++ Home}} ->
	    Home
    end.
