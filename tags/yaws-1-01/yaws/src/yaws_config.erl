%%----------------------------------------------------------------------
%%% File    : yaws_config.erl
%% Author  : Claes Wikstrom <klacke@bluetail.com>
%%% Purpose : 
%%% Created : 16 Jan 2002 by Claes Wikstrom <klacke@bluetail.com>
%%%----------------------------------------------------------------------

-module(yaws_config).
-author('klacke@bluetail.com').




-include_lib("yaws/include/yaws.hrl").
-include_lib("yaws/include/yaws_api.hrl").
-include("yaws_debug.hrl").


-include_lib("kernel/include/file.hrl").

-compile(export_all).
%%-export([Function/Arity, ...]).

-export([load/3,
	 make_default_gconf/1]).
	 

%% where to look for yaws.conf 
paths() ->
    case yaws:getuid() of
	{ok, "0"} ->    %% root 
	    ["/etc/yaws.conf"];
	_ -> %% developer
	    [filename:join([os:getenv("HOME"), "yaws.conf"]),
	     "./yaws.conf", 
	     "/etc/yaws.conf"]
    end.



%% load the config

load(false, Trace, Debug) ->
    case yaws:first(fun(F) -> exists(F) end, paths()) of
	false ->
	    {error, "Can't find no config file "};
	{ok, _, File} ->
	    load({file, File}, Trace, Debug)
    end;
load({file, File}, Trace, Debug) ->
    error_logger:info_msg("Yaws: Using config file ~s", [File]),
    case file:open(File, [read]) of
	{ok, FD} ->
	    GC = make_default_gconf(Debug),
	    R = (catch fload(FD, globals, GC#gconf{file = File,
						   trace = Trace,
						   debug = Debug
						  }, 
			     undefined, 
			     [], 1, io:get_line(FD, ''))),
	    ?Debug("FLOAD: ~p", [R]),
	    case R of
		{ok, GC2, Cs} ->
		    validate_cs(GC2, Cs);
		Err ->
		    Err
	    end;
	_ ->
	    {error, "Can't open config file" ++ File}
    end.


exists(F) ->
    case file:open(F, [read, raw]) of
	{ok, Fd} ->
	    file:close(Fd),
	    ok;
	_ ->
	    false
    end.



validate_cs(GC, Cs) ->
    L = lists:map(fun(SC) -> {{SC#sconf.listen, SC#sconf.port}, SC} end,Cs),
    L2 = lists:map(fun(X) -> element(2, X) end, lists:sort(L)),
    L3 = arrange(L2, start, [], []),
    case validate_groups(L3) of
	ok ->
	    {ok, GC, L3};
	Err ->
	    Err
    end.

validate_groups([]) ->
    ok;
validate_groups([H|T]) ->
    case (catch validate_group(H)) of
	ok ->
	    validate_groups(T);
	Err ->
	    Err
    end.

validate_group(List) ->
    
    %% first, max one ssl per group
    ?Debug("List = ~p~n", [List]),

    case lists:filter(fun(C) ->
			      C#sconf.ssl /= undefined 
		      end, List) of
	L when length(L) > 1 ->
	    throw({error, ?F("Max one ssl server per IP: ~p", 
			     [(hd(L))#sconf.servername])});
	_ ->
	    ok
    end,
    ok.
    

arrange([C|Tail], start, [], B) ->
    arrange(Tail, {in, C}, [set_server(C)], B);
arrange([], _, [], B) ->
    B;
arrange([], _, A, B) ->
    [A | B];
arrange([C1|Tail], {in, C0}, A, B) ->
    if
	C1#sconf.listen == C0#sconf.listen,
	C1#sconf.port == C0#sconf.port ->
	    arrange(Tail, {in, C0}, [set_server(C1)|A], B);
	true ->
	    arrange(Tail, {in, C1}, [set_server(C1)], [A|B])
    end.


set_server(C) ->
    case {C#sconf.ssl, C#sconf.port, C#sconf.add_port} of
	{undefined, 80, _} ->
	    C;
	{undefined, Port, true} ->
	    add_port(C, Port);
	{_SSL, 443, _} ->
	    C;
	{_SSL, Port, true} ->
	    add_port(C, Port);
	{_,_,_} ->
            C
    end.


add_port(C, Port) ->
    case string:tokens(C#sconf.servername, ":") of
	[Srv, Prt] ->
	    case (catch list_to_integer(Prt)) of
		{'EXIT', _} ->
		    C#sconf{servername = 
			    Srv ++ [$:|integer_to_list(Port)]};
		_Int ->
		    C
	    end;
	[Srv] ->
	  C#sconf{servername =   Srv ++ [$:|integer_to_list(Port)]}
    end.


make_default_gconf(Debug) ->
    Y = yaws_dir(),
    #gconf{yaws_dir = Y,
	   ebin_dir = [filename:join([Y, "examples/ebin"])],
	   include_dir = [filename:join([Y, "examples/include"])],
	   logdir = ".",
	   cache_refresh_secs = if
				    Debug == true ->
					0;
				    true ->
					30
				end,
	   trace = false,
	   uid = element(2, yaws:getuid()),
	   yaws = "Yaws " ++ yaws_vsn:version()}.


make_default_sconf() ->
    Y = yaws_dir(),
    #sconf{docroot = filename:join([Y, "www"])}.


yaws_dir() ->
    P = filename:split(code:which(?MODULE)),
    P1 = del_tail(P),
    filename:join(P1).


del_tail([_H, ".." |Tail]) ->
    del_tail(Tail);
del_tail([_X, _Y]) ->
    [];
del_tail([H|T]) ->
    [H|del_tail(T)].



%% two states, global, server
fload(FD, globals, GC, _C, Cs, _Lno, eof) ->
    file:close(FD),
    {ok, GC, Cs};


fload(FD, _,  _GC, _C, _Cs, Lno, eof) ->
    file:close(FD),
    {error, ?F("Unexpected end of file at line ~w", [Lno])};
 
fload(FD, globals, GC, C, Cs, Lno, Chars) -> 
    %?Debug("Chars: ~s", [Chars]),
    Next = io:get_line(FD, ''),
    case toks(Chars) of
	[] ->
	    fload(FD, globals, GC, C, Cs, Lno+1, Next);
	["trace", '=', Bstr] ->
	    case Bstr of
		"traffic" ->
		    fload(FD, globals, GC#gconf{trace = {true, traffic}},
			  C, Cs, Lno+1, Next);
		"http" ->
		    fload(FD, globals, GC#gconf{trace = {true, http}},
			  C, Cs, Lno+1, Next);
		_ ->
		    {error, ?F("Expect bool at line ~w",[Lno])}
	    end;
	
	["logdir", '=', Logdir] ->
	    Dir = filename:absname(Logdir),
	    case is_dir(Dir) of
		true ->
		    put(logdir, Dir),
		    fload(FD, globals, GC#gconf{logdir = Dir},
			  C, Cs, Lno+1, Next);
		false ->
		    {error, ?F("Expect directory at line ~w", [Lno])}
	    end;

	["ebin_dir", '=', Ebindir] ->
	    Dir = filename:absname(Ebindir),
	    case is_dir(Dir) of
		true ->
		    fload(FD, globals, GC#gconf{ebin_dir = [Dir|GC#gconf.ebin_dir]},
			  C, Cs, Lno+1, Next);
		false ->
		    {error, ?F("Expect directory at line ~w", [Lno])}
	    end;

	["runmod", '=', Mod0] ->
	    Mod = list_to_atom(Mod0),
	    fload(FD, globals, GC#gconf{runmods = [Mod|GC#gconf.runmods]},
		  C, Cs, Lno+1, Next);

	["include_dir", '=', Incdir] ->
	    Dir = filename:absname(Incdir),
	    case is_dir(Dir) of
		true ->
		    fload(FD, globals, GC#gconf{include_dir=[Dir|GC#gconf.include_dir]},
			  C, Cs, Lno+1, Next);
		false ->
		    {error, ?F("Expect directory at line ~w", [Lno])}
	    end;


	%% keep this bugger for backward compat for a while
	["keepalive_timeout", '=', Val] ->
	    case (catch list_to_integer(Val)) of
		 I when integer(I) ->
		    fload(FD, globals, GC#gconf{keepalive_timeout = I},
			  C, Cs, Lno+1, Next);
		_ ->
		     {error, ?F("Expect integer at line ~w", [Lno])}
	     end;

	["read_timeout", '=', Val] ->
	    case (catch list_to_integer(Val)) of
		 I when integer(I) ->
		    fload(FD, globals, GC#gconf{timeout = I},
			  C, Cs, Lno+1, Next);
		_ ->
		     {error, ?F("Expect integer at line ~w", [Lno])}
	     end;

	["max_num_cached_files", '=', Val] ->
	    case (catch list_to_integer(Val)) of
		 I when integer(I) ->
		    fload(FD, globals, GC#gconf{max_num_cached_files = I},
			  C, Cs, Lno+1, Next);
		_ ->
		     {error, ?F("Expect integer at line ~w", [Lno])}
	     end;


	["max_num_cached_bytes", '=', Val] ->
	    case (catch list_to_integer(Val)) of
		 I when integer(I) ->
		    fload(FD, globals, GC#gconf{max_num_cached_bytes = I},
			  C, Cs, Lno+1, Next);
		_ ->
		     {error, ?F("Expect integer at line ~w", [Lno])}
	     end;


	["max_size_cached_file", '=', Val] ->
	    case (catch list_to_integer(Val)) of
		 I when integer(I) ->
		    fload(FD, globals, GC#gconf{max_size_cached_file = I},
			  C, Cs, Lno+1, Next);
		_ ->
		     {error, ?F("Expect integer at line ~w", [Lno])}
	     end;

	["cache_refresh_secs", '=', Val] ->
	    case (catch list_to_integer(Val)) of
		 I when integer(I), I >= 0 ->
		    fload(FD, globals, GC#gconf{cache_refresh_secs = I},
			  C, Cs, Lno+1, Next);
		_ ->
		     {error, ?F("Expect 0 or positive integer at line ~w", [Lno])}
	     end;

	["username", '=' , Uname] ->
	    fload(FD, globals, GC#gconf{username = Uname},
		  C, Cs, Lno+1, Next);

	['<', "server", Server, '>'] ->  %% first server 
	    fload(FD, server, GC, #sconf{servername = Server},
		  Cs, Lno+1, Next);
	[H|_] ->
	    {error, ?F("Unexpected tokens ~p at line ~w", [H, Lno])}
    end;

	
fload(FD, server, GC, C, Cs, Lno, Chars) ->
    Next = io:get_line(FD, ''),
    case toks(Chars) of
	[] ->
	    fload(FD, server, GC, C, Cs, Lno+1, Next);

	["access_log", '=', Bool] ->
	    case is_bool(Bool) of
		{true, Val} ->
		    C2 = C#sconf{access_log = Val},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		false ->
		    {error, ?F("Expect true|false at line ~w", [Lno])}
	    end;
	["dir_listings", '=', Bool] ->
	    case is_bool(Bool) of
		{true, Val} ->
		    C2 = C#sconf{dir_listings = Val},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		false ->
		    {error, ?F("Expect true|false at line ~w", [Lno])}
	    end;
	["port", '=', Val] ->
	    case (catch list_to_integer(Val)) of
		I when integer(I) ->
		    C2 = C#sconf{port = I},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		_ ->
		    {error, ?F("Expect integer at line ~w", [Lno])}
	    end;
	["rmethod", '=', Val] ->
	    case Val of
		"http" -> 
		    C2 = C#sconf{rmethod = Val},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		"https" -> 
		    C2 = C#sconf{rmethod = Val},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		_ ->
		    {error, ?F("Expect http or https at line ~w", [Lno])}
	    end;
	["listen", '=', IP] ->
	    case yaws:parse_ip(IP) of
		error ->
		    {error, ?F("Expect IP address at line ~w:", [Lno])};
		Addr ->
		    C2 = C#sconf{listen = Addr},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next)
	    end;
	["servername", '=', Name] ->
	    C2 = C#sconf{servername = Name, add_port=false},
	    fload(FD, server, GC, C2, Cs, Lno+1, Next);
	["docroot", '=', Rootdir] ->
	    Root = filename:absname(Rootdir),
	    case is_dir(Root) of
		true ->
		    C2 = C#sconf{docroot = Root},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		false ->
		    {error, ?F("Expect directory at line ~w", [Lno])}
	    end;
	["partial_post_size",'=',Size] ->
	    case Size of
		nolimit ->
		    C2 = C#sconf{partial_post_size = nolimit},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		Val ->
		    case (catch list_to_integer(Val)) of
			I when integer(I) ->
			    C2 = C#sconf{partial_post_size = I},
			    fload(FD, server, GC, C2, Cs, Lno+1, Next);
			_ ->
			    {error, ?F("Expect integer or 'nolimit' at line ~w", [Lno])}
		    end
	    end;
	['<', "auth", '>'] ->
	    fload(FD, server_auth, GC, C, Cs, Lno+1, Next, #auth{});

	["default_server_on_this_ip", '=', Bool] ->
	    fload(FD, server, GC, C, Cs, Lno+1, Next);

	[ '<', "ssl", '>'] ->
	    ssl:start(),
	    fload(FD, ssl, GC, C, Cs, Lno+1, Next);
	
	["appmods", '=' | Modules] ->
	    C2 = C#sconf{appmods = Modules},
	    fload(FD, server, GC, C2, Cs, Lno+1, Next);

	["errormod_404", '=' , Module] ->
	    C2 = C#sconf{errormod_404 = list_to_atom(Module)},
	    fload(FD, server, GC, C2, Cs, Lno+1, Next);

	["errormod_crash", '=', Module] ->
	    C2 = C#sconf{errormod_crash = list_to_atom(Module)},
	    fload(FD, server, GC, C2, Cs, Lno+1, Next);

	["arg_rewrite_mod", '=', Module] ->
	    C2 = C#sconf{arg_rewrite_mod = list_to_atom(Module)},
	    fload(FD, server, GC, C2, Cs, Lno+1, Next);

	["tilde_expand", '=', Bool] ->
	    case is_bool(Bool) of
		{true, Val} ->
		    C2 = C#sconf{tilde_expand = Val},
		    fload(FD, server, GC, C2, Cs, Lno+1, Next);
		false ->
		    {error, ?F("Expect true|false at line ~w", [Lno])}
	    end;
	['<', "/server", '>'] ->
	    fload(FD, globals, GC, undefined, [C|Cs], Lno+1, Next);

	['<', "opaque", '>'] ->
	    fload(FD, opaque, GC, C, Cs, Lno+1, Next);

	["start_mod", '=' , Module] ->
	    C2 = C#sconf{start_mod = list_to_atom(Module)},
	    fload(FD, server, GC, C2, Cs, Lno+1, Next);

	[H|T] ->
	    {error, ?F("Unexpected input ~p at line ~w", [[H|T], Lno])}
    end;

	

fload(FD, ssl, GC, C, Cs, Lno, Chars) ->
    Next = io:get_line(FD, ''),
    case toks(Chars) of
	[] ->
	    fload(FD, ssl, GC, C, Cs, Lno+1, Next);

	%% A bunch of ssl options

	["keyfile", '=', Val] ->
	    case is_file(Val) of
		true when  record(C#sconf.ssl, ssl) ->
		    C2 = C#sconf{ssl = (C#sconf.ssl)#ssl{keyfile = Val}},
		    fload(FD, ssl, GC, C2, Cs, Lno+1, Next);
		true ->
		    {error, ?F("Need to set option ssl to true before line ~w",
			       [Lno])};
		_ ->
		    {error, ?F("Expect existing file at line ~w", [Lno])}
	    end;
	["certfile", '=', Val] ->
	    case is_file(Val) of
		true when  record(C#sconf.ssl, ssl) ->
		    C2 = C#sconf{ssl = (C#sconf.ssl)#ssl{certfile = Val}},
		    fload(FD, ssl, GC, C2, Cs, Lno+1, Next);
		true ->
		    {error, ?F("Need to set option ssl to true before line ~w",
			       [Lno])};
		_ ->
		    {error, ?F("Expect existing file at line ~w", [Lno])}
	    end;
	["cacertfile", '=', Val] ->
	    case is_file(Val) of
		true when  record(C#sconf.ssl, ssl) ->
		    C2 = C#sconf{ssl = (C#sconf.ssl)#ssl{cacertfile = Val}},
		    fload(FD, ssl, GC, C2, Cs, Lno+1, Next);
		true ->
		    {error, ?F("Need to set option ssl to true before line ~w",
			       [Lno])};
		_ ->
		    {error, ?F("Expect existing file at line ~w", [Lno])}
	    end;
	["verify", '=', Val] ->
	    case lists:member(Val, [1,2,3]) of
		true when  record(C#sconf.ssl, ssl) ->
		    C2 = C#sconf{ssl = (C#sconf.ssl)#ssl{verify = Val}},
		    fload(FD, ssl, GC, C2, Cs, Lno+1, Next);
		true ->
		    {error, ?F("Need to set option ssl to true before line ~w",
			       [Lno])};
		_ ->
		    {error, ?F("Expect integer at line ~w", [Lno])}
	    end;
	["depth", '=', Val] ->
	    case lists:member(Val, [1,2,3,4,5,6,7]) of
		true when  record(C#sconf.ssl, ssl) ->
		    C2 = C#sconf{ssl = (C#sconf.ssl)#ssl{depth = Val}},
		    fload(FD, ssl, GC, C2, Cs, Lno+1, Next);
		true ->
		    {error, ?F("Need to set option ssl to true before line ~w",
			       [Lno])};
		_ ->
		    {error, ?F("Expect reasonable integer at line ~w", [Lno])}
	    end;
	["password", '=', Val] ->
	    if 
		record(C#sconf.ssl, ssl) ->
		    C2 = C#sconf{ssl = (C#sconf.ssl)#ssl{password = Val}},
		    fload(FD, ssl, GC, C2, Cs, Lno+1, Next);
		true ->
		    {error, ?F("Need to set option ssl to true before line ~w",
			       [Lno])}
	    end;
	["ciphers", '=', Val] ->
	    if 
		record(C#sconf.ssl, ssl) ->
		    C2 = C#sconf{ssl = (C#sconf.ssl)#ssl{ciphers = Val}},
		    fload(FD, ssl, GC, C2, Cs, Lno+1, Next);
		true ->
		    {error, ?F("Need to set option ssl to true before line ~w",
			       [Lno])}
	    end;
	['<', "/ssl", '>'] ->
	    fload(FD, server, GC, C, Cs, Lno+1, Next);
	
	[H|T] ->
	    {error, ?F("Unexpected input ~p at line ~w", [[H|T], Lno])}
    end;


fload(FD, opaque, _GC, _C, _Cs, Lno, eof) ->
    file:close(FD),
    {error, ?F("Unexpected end of file at line ~w", [Lno])};

fload(FD, opaque, GC, C, Cs, Lno, Chars) ->
    %?Debug("Chars: ~s", [Chars]),
    Next = io:get_line(FD, ''),
    case toks(Chars) of
	[] ->
	    fload(FD, opaque, GC, C, Cs, Lno+1, Next);
	['<', "/opaque", '>'] ->
	    fload(FD, server, GC, C, Cs, Lno+1, Next);
	[Key, '=', Value] ->
	    C2 = C#sconf{opaque = [{Key,Value} | C#sconf.opaque]},
	    fload(FD, opaque, GC, C2, Cs, Lno+1, Next);
	[H|T] ->
	    {error, ?F("Unexpected input ~p at line ~w", [[H|T], Lno])}
    end.



fload(FD, server_auth, _GC, _C, _Cs, Lno, eof, _Auth) ->
    file:close(FD),
    {error, ?F("Unexpected end of file at line ~w", [Lno])};

fload(FD, server_auth, GC, C, Cs, Lno, Chars, Auth) ->
    %?Debug("Chars: ~s", [Chars]),
    Next = io:get_line(FD, ''),
    case toks(Chars) of
	[] ->
	    fload(FD, server_auth, GC, C, Cs, Lno+1, Next, Auth);
	["dir", '=', Authdir] ->
	    Dir = filename:absname(Authdir),
    	    case is_dir(Dir) of
		true ->
		    A2 = Auth#auth{dir = [Dir|Auth#auth.dir]},
		    fload(FD, server_auth, GC, C, Cs, Lno+1, Next, A2);
		false ->
		    {error, ?F("Expect directory at line ~w", [Lno])}
	    end;
	["realm", '=', Realm] ->
	    A2 = Auth#auth{realm = Realm},
	    fload(FD, server_auth, GC, C, Cs, Lno+1, Next, A2);
	["user", '=', User] ->
	    case string:tokens(User, ":") of
		[Name, Passwd] ->
		    A2 = Auth#auth{users = [{Name, Passwd}|Auth#auth.users]},
		    fload(FD, server_auth, GC, C, Cs, Lno+1, Next, A2);
		false ->
		    {error, ?F("Invalid user at line ~w", [Lno])}
	    end;
	['<', "/auth", '>'] ->
	    C2 = C#sconf{authdirs = [Auth|C#sconf.authdirs]},
	    fload(FD, server, GC, C2, Cs, Lno+1, Next);
	[H|T] ->
	    {error, ?F("Unexpected input ~p at line ~w", [[H|T], Lno])}
    end.


is_bool("true") ->
    {true, true};
is_bool("false") ->
    {true, false};
is_bool(_) ->
    false.


is_dir(Val) ->
    case file:read_file_info(Val) of
	{ok, FI} when FI#file_info.type == directory ->
	    true;
	_ ->
	    false
    end.


is_file(Val) ->
    case file:read_file_info(Val) of
	{ok, FI} when FI#file_info.type == regular ->
	    true;
	_ ->
	    false
    end.


%% tokenizer
toks(Chars) ->
    toks(Chars, free, [], []). % two accumulators

toks([$#|_T], Mode, Ack, Tack) ->
    toks([], Mode, Ack, Tack);

toks([H|T], free, Ack, Tack) -> 
    %?Debug("Char=~p", [H]),
    case {is_quote(H), is_string_char(H), is_special(H), is_space(H)} of
	{_,_, _, true} ->
	    toks(T, free, Ack, Tack);
	{_,_, true, _} ->
	    toks(T, free, [], [list_to_atom([H]) | Tack]);
	{_,true, _,_} ->
	    toks(T, string, [H], Tack);
	{true,_, _,_} ->
	    toks(T, quote, [], Tack);
	{false, false, false, false} ->
	    %% weird char, let's ignore it
	    toks(T, free, Ack, Tack)
    end;
toks([C|T], string, Ack, Tack) -> 
    %?Debug("Char=~p", [C]),
    case {is_backquote(C), is_quote(C), is_string_char(C), is_special(C), is_space(C)} of
	{true, _, _, _,_} ->
	    toks(T, [backquote,string], Ack, Tack);
	{_, _, true, _,_} ->
	    toks(T, string, [C|Ack], Tack);
	{_, _, _, true, _} ->
	    toks(T, free, [], [list_to_atom([C]), lists:reverse(Ack)|Tack]);
	{_, true, _, _, _} ->
	    toks(T, quote, [], [lists:reverse(Ack)|Tack]);
	{_, _, _, _, true} ->
	    toks(T, free, [], [lists:reverse(Ack)|Tack]);
	{false, false, false, false, false} ->
	    %% weird char, let's ignore it
	    toks(T, free, Ack, Tack)
    end;
toks([C|T], quote, Ack, Tack) -> 
    %?Debug("Char=~p", [C]),
    case {is_quote(C), is_backquote(C)} of
	{true, _} ->
	    toks(T, free, [], [lists:reverse(Ack)|Tack]);
	{_, true} ->
            toks(T, [backquote,quote], [C|Ack], Tack);
	{false, false} ->
            toks(T, quote, [C|Ack], Tack)
    end;
toks([C|T], [backquote,Mode], Ack, Tack) ->
    toks(T, Mode, [C|Ack], Tack);
toks([], string, Ack, Tack) ->
    lists:reverse([lists:reverse(Ack) | Tack]);
toks([], free, _,Tack) ->
    lists:reverse(Tack).

is_quote($") -> true ; 
is_quote(_)  -> false.

is_backquote($\\) -> true ; 
is_backquote(_)  -> false.

is_string_char(C) ->
    if
	$a =< C, C =< $z ->
	     true;
	$A =< C, C =< $Z ->
	    true;
	$0 =< C, C =< $9 ->
	    true;
	true ->
	    lists:member(C, [$., $/, $:, $_, $-])
    end.

is_space(C) ->
    lists:member(C, [$\s, $\n, $\t, $\r]).

is_special(C) ->
    lists:member(C, [$=, $<, $>]).
