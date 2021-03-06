%%%----------------------------------------------------------------------
%%% File    : mime_type_c.erl
%%% Author  : Claes Wikstrom <klacke@hyber.org>
%%% Purpose : 
%%% Created : 10 Jul 2002 by Claes Wikstrom <klacke@hyber.org>
%%%----------------------------------------------------------------------

-module(mime_type_c).
-author('klacke@hyber.org').
-compile(export_all).


%% this module reads the mime.types file and creates
%% the mod mime_types.erl
%% default type is text/plain

compile() ->
    R = (catch c()),
    io:format("~p~n ",[R]),
    erlang:halt().


c() ->
    {ok, F} = file:open("mime.types", [read]),
    io:format("Compiling mime.types ... > mime_types.erl ~n", []),
    {ok, B} = file:read_file("charset.def"),
    case string:strip(binary_to_list(B)) of
	[] ->
	    put(charset, []);
	CharSet0 ->
	    CharSet = string:strip(CharSet0, both, 10),
	    put(charset, ";charset=" ++ CharSet)
    end,
    T = ets:new(aa, [set, public]),
    c(F, T, io:get_line(F, '')).

c(F, T, eof) ->
    file:close(F),
    gen(T);
c(F, T, {error, terminated}) ->
    file:close(F),
    gen(T);
c(F, T, Line) ->
    case Line of
	[$#|_] ->
	    ignore;
	[$\s|_ ] ->
	    ignore;
	L ->
	    case string:tokens(L, [$\s, $\t]) of
		[] ->
		    ignore;
		[_] ->  
		    ignore;
		[MimeType | Exts] ->
		    lists:foreach(
		      fun(E) ->
			      ets:insert(T, {E, MimeType}),
			      ets:insert(T, {up(E), MimeType})
		      end, Exts)
	    end
    
    end,
    c(F, T, io:get_line(F, '')).

up(L) ->
    lists:map(fun(C) -> upper(C) end, L).
upper(C) ->
    if
	C >= $a, C =< $z ->
	    C - ($a - $A);
	true ->
	    C
    end.

nonl([]) ->
    [];
nonl([$\n|T]) ->
    nonl(T);
nonl([H|T]) ->
    [H|nonl(T)].

special(Fd, Ext, Type) ->
    io:format(Fd, "t(~p) -> {~p, ~p};~n", 
	      [Ext, Type, "text/html" ++ get(charset)]).
    

revspecial(Fd, Ext, Type) ->
    io:format(Fd, "revt(~p) -> {~p, ~p};~n", 
	      [lists:reverse(Ext), Type, "text/html" ++ get(charset)]).
    

gen(T) ->
    {ok, Fd} = file:open("mime_types.erl", [write]),
    io:format(Fd, 
	      "-module(mime_types). ~n"
	      "-compile(export_all). ~n", []),
   
    L = lists:sort(ets:tab2list(T)),
    special(Fd, "yaws", yaws),
    special(Fd, "php", php),
    special(Fd, "cgi", cgi),
    special(Fd, "PHP", php),
    special(Fd, "CGI", cgi),
    lists:foreach(
      fun({Ext, MT0}) ->
	      MT = case MT0 of
		       "text/" ++ _ ->
			   MT0 ++ get(charset);
		       _ ->
			   MT0
		   end,
	      io:format(Fd, "t(~p) -> {regular, ~p};~n", [nonl(Ext), MT])
      end, L),
    io:format(Fd, "t(_) -> {regular, \"text/plain" ++ get(charset) 
	      ++ "\"}.~n~n~n", []),



    revspecial(Fd, "yaws", yaws),
    revspecial(Fd, "php", php),
    revspecial(Fd, "cgi", cgi),
    revspecial(Fd, "PHP", php),
    revspecial(Fd, "CGI", cgi),
    lists:foreach(
      fun({Ext, MT0}) ->
	      MT = case MT0 of
		       "text/" ++ _ ->
			   MT0 ++ get(charset);
		       _ ->
			   MT0
		   end,
	      io:format(Fd, "revt(~p) -> {regular, ~p};~n", 
			[nonl(lists:reverse(Ext)), MT])
      end, L),
    io:format(Fd, "revt(_) -> {regular, 
                               \"text/plain" ++ get(charset) ++
	      "\"}.~n~n~n", []).

    
		  
		 
			  


		      
