%%%----------------------------------------------------------------------
%%% File    : yaws_server.erl
%%% Author  : Claes Wikstrom <klacke@hyber.org>
%%% Purpose : 
%%% Created : 16 Jan 2002 by Claes Wikstrom <klacke@hyber.org>
%%%----------------------------------------------------------------------

-module(yaws_server).
-author('klacke@hyber.org').

-compile(export_all).
%%-export([Function/Arity, ...]).

-behaviour(gen_server).

-include_lib("yaws/include/yaws.hrl").
-include_lib("yaws/include/yaws_api.hrl").
-include("yaws_debug.hrl").

-include_lib("kernel/include/file.hrl").

%% External exports
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-import(filename, [join/1]).
-import(lists, [foreach/2, map/2, flatten/1, flatmap/2, reverse/1]).

-import(yaws_api, [ehtml_expand/1]).

-record(gs, {gconf,
	     group,         %% list of #sconf{} s
	     ssl,           %% ssl | nossl
	     l,             %% listen socket
	     mnum = 0,      %% dyn compiled erl module  number
	     sessions = 0,  %% number of HTTP sessions
	     reqs = 0}).    %% number of HTTP requests


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, yaws_server}, yaws_server, [], []).

status() ->
    gen_server:call(?MODULE, status).



stats() -> 
    {S, Time} = status(),
    {_GC, Srvs, _} = S,
    Diff = calendar:time_difference(Time, calendar:local_time()),
    G = fun(L) -> lists:reverse(lists:keysort(2, L)) end,

    R= flatmap(
	 fun({_Pid, SCS}) ->
		 map(
		   fun(SC) ->

			   E = SC#sconf.ets,
			   L = ets:match(E, {{urlc_total, '$1'}, '$2'}),
			   {SC#sconf.servername,  
			    flatten(yaws:fmt_ip(SC#sconf.listen)),
			    G(map(fun(P) -> list_to_tuple(P) end, L))}
		   end, SCS)
	 end, Srvs),
    {Diff, R}.


get_app_args() ->
    AS=init:get_arguments(),
    Debug = case application:get_env(yaws, debug) of
		undefined ->
		    lists:member({yaws, ["debug"]}, AS);
		{ok, Val}  ->
		    Val
	    end,
    Trace = case application:get_env(yaws, trace) of
		undefined ->
		    case {lists:member({yaws, ["trace", "http"]}, AS),
			  lists:member({yaws, ["trace", "traffic"]}, AS)} of
			{true, _} ->
			    {true, http};
			{_, true} ->
			    {true, traffic};
			_ ->
			    false
		    end;
		{ok, http} ->
		    {true, http};
		{ok, traffic} ->
		    {true, traffic};
		_ ->
		    false
	    end,
    TraceOutput = case application:get_env(yaws, traceoutput) of
		undefined ->
		    lists:member({yaws, ["tracedebug"]}, AS);
		{ok, Val3}  ->
		    Val3
	    end,
    Conf = case application:get_env(yaws, conf) of
	       undefined ->
		   find_c(AS);
	       {ok, File} ->
		   {file, File}
	   end,
    RunMod = case application:get_env(yaws, runmod) of
		 undefined ->
		     find_runmod(AS);
		 {ok,Mod} ->
		     {ok,Mod}
	     end,
    Embed = case application:get_env(yaws, embedded) of
		undefined ->
		    false;
		{ok, Val0} ->
		    Val0
	    end,
    {Debug, Trace, TraceOutput, Conf, RunMod, Embed}.

find_c([{conf, [File]} |_]) ->
    {file, File};
find_c([_|T]) ->
    find_c(T);
find_c([]) ->
    false.

find_runmod([{runmod, [Mod]} |_]) ->
    {ok,l2a(Mod)};
find_runmod([_|T]) ->
    find_runmod(T);
find_runmod([]) ->
    false.

l2a(L) when list(L) -> list_to_atom(L);
l2a(A) when atom(A) -> A.



%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%----------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    put(start_time, calendar:local_time()),  %% for uptime
    {Debug, Trace, TraceOut, Conf, RunMod, Embed} = get_app_args(),
    case Embed of 
	false ->
	    case yaws_config:load(Conf, Trace, TraceOut, Debug) of
		{ok, Gconf, Sconfs} ->
		    erase(logdir),
		    ?Debug("Conf = ~p~n", [?format_record(Gconf, gconf)]),
		    yaws_log:setdir(Gconf#gconf.logdir, Sconfs),
		    case Gconf#gconf.trace of
			{true, What} ->
			    yaws_log:open_trace(What),
			    yaws_api:set_tty_trace(Gconf#gconf.tty_trace);
			_ ->
			    ok
		    end,
		    init2(Gconf, Sconfs, RunMod, true);
		{error, E} ->
		    case erase(logdir) of
			undefined ->
			    error_logger:error_msg("Yaws: Bad conf: ~p~n", 
						   [E]),
			    init:stop(),
			    {stop, E};
			Dir ->
			    yaws_log:setdir(Dir, []),
			    error_logger:error_msg("Yaws: bad conf: ~s~n",[E]),
			    init:stop(),
			    {stop, E}
		    end
	    end;
	true ->
	    init2(yaws_config:make_default_gconf(Debug), [], undef, true)
    end.


init2(Gconf, Sconfs, RunMod, FirstTime) ->

    lists:foreach(
      fun(D) ->
	      yaws_debug:format(Gconf, "Add path ~p~n", [D]),
	      code:add_pathz(D)
      end, Gconf#gconf.ebin_dir),


    %% start user provided application
    case RunMod of
	{ok,Mod} -> 
	    runmod(Mod);
	_ -> 
	    false
    end,
    lists:foreach(fun(M) -> runmod(M) end, Gconf#gconf.runmods),

    %% start the individual server processes
    L = lists:map(
	  fun(Group) ->
		  proc_lib:start_link(?MODULE, gserv, [Gconf, Group])
	  end, Sconfs),
    L2 = lists:zf(fun({error, F, A}) ->	
			  error_logger:error_msg(F, A),
			  false;
		     ({error, Reason}) ->
			  error_logger:error_msg("FATAL: ~p~n", [Reason]),
			  false;
		     ({_Pid, _SCs}) ->
			  true;
		     (none) ->
			  false
		  end, L),
    ?Debug("L=~p~n", [yaws_debug:nobin(L)]),
    if
	FirstTime == true ->
	    CTL = proc_lib:spawn_link(yaws_ctl, start, 
				      [self(), Gconf#gconf.uid]),
	    receive
		{CTL, ok} ->
		    ok;
		{CTL, {error, R}} ->
		    error_logger:format("CTL failed ~p~n", [R]),
		    exit(R)
	    end;

	true ->
	    ok
    end,
    Tdir0 = yaws:tmp_dir()++"/yaws/" ,
    file:make_dir(Tdir0),
    set_writeable(Tdir0),
    Tdir = Tdir0 ++ Gconf#gconf.uid,
    file:make_dir(Tdir),
    set_writeable(Tdir),

    case (catch yaws_log:uid_change(Gconf)) of
	ok ->
	    ok;
	ERR ->
	    error_logger:error_msg("Failed to change uid on logfiles:~n~p",
				   [ERR]),
	    exit(error)
    end,

    %% and now finally, we've opened the ctl socket and are
    %% listening to all sockets we can possibly change username


    GC2 = case (catch yaws:setuser(Gconf#gconf.username)) of
	      ignore ->
		  Gconf;
	      {ok, NewUid} ->
		  error_logger:info_msg("Changed uid to ~s~n", [NewUid]),
		  Gconf#gconf{uid = NewUid};
	      Other ->
		  error_logger:error_msg("Failed to set user:~n~p", [Other]),
		  exit(Other)
	  end,
    case (catch setup_tdir(GC2)) of
	ok ->
	    ok;
	_Error ->
	    exit(error)
    end,
    lists:foreach(fun({Pid, _}) -> Pid ! {newuid, GC2#gconf.uid} end, L2),
    {ok, {GC2, L2, 0}}.


%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_call(status, _From, State) ->
    Reply = {State, get(start_time)},
    {reply, Reply, State};
handle_call(pids, _From, State) ->  %% for gprof
    L = lists:map(fun(X) ->element(1, X) end, element(2, State)),
    {reply, [self() | L], State};

handle_call(mnum, _From, {GC, Group, Mnum}) ->
    {reply, Mnum+1,   {GC, Group, Mnum+1}};

handle_call({setconf, GC, Groups}, _From, State) ->
    %% First off, terminate all currently running processes
    Curr = lists:map(fun(X) ->element(1, X) end, element(2, State)),
    lists:foreach(fun(Pid) ->
			  Pid ! {self(), stop},
			  receive
			      {Pid, ok} ->
				  ok
			  end
		  end, Curr),
    case init2(GC, Groups, undef, false) of
	{ok, State2} ->
	    {reply, ok, State2};
	Err ->
	    {reply, Err, {GC, [], 0}}
    end;

handle_call(getconf, _From, State) ->
    {GC, Pairs, _} = State,
    Groups = lists:map(fun({_Pid, SCs}) -> SCs end, Pairs),
    {reply, {ok, GC, Groups}, State}.





%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason},  State) ->
    L = lists:map(fun(X) ->element(1, X) end, element(2, State)),
    case lists:member(Pid, L) of
	true ->
	    %% one of our gservs died
	    error_logger:format("yaws: FATAL gserv died ~p~n", [Reason]),
	    exit(restartme);
	false ->
	    ignore
    end,
    {noreply, State};


handle_info(_Msg, State) ->
    ?Debug("GOT ~p~n", [_Msg]),
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.


%% we search and setup www authenticate for each directory
%% specified as an auth directory. These are merged with server conf.

setup_auth(SC) ->
    ?Debug("setup_auth(~p)", [yaws_debug:nobin(SC)]),
    ?f(lists:map(fun(Auth) ->
	add_yaws_auth(Auth#auth.dir, Auth)
end, SC#sconf.authdirs)).

add_yaws_auth(Dirs, A) ->
    lists:map(
      fun(Dir) ->
	  case file:consult([Dir, [$/|".yaws_auth"]]) of
	      {ok, [{realm, Realm} |TermList]} ->
		  {Dir, A#auth{realm = Realm,
			       users = TermList++A#auth.users}};
	      {ok, TermList} ->
		  {Dir, A#auth{users = TermList++A#auth.users}};
	      {error, enoent} ->
		  {Dir, A};
	      _Err ->
		  error_logger:format("Bad .yaws_auth file in dir ~p~n", [Dir]),
		  {Dir, A}
	  end
      end, Dirs).


do_listen(SC) ->
    case SC#sconf.ssl of
	undefined ->
	    {nossl, gen_tcp_listen(SC#sconf.port, opts(SC))};
	SSL ->
	    {ssl, ssl:listen(SC#sconf.port, ssl_opts(SC, SSL))}
    end.

gen_tcp_listen(Port, Opts) ->
    ?Debug("Listen ~p:~p~n", [Port, Opts]),
    gen_tcp:listen(Port, Opts).


set_writeable(Dir) ->
    set_dir_mode(Dir, 8#777).

set_dir_mode(Dir, Mode) ->
    case file:read_file_info(Dir) of
	{ok, FI} ->
	    file:write_file_info(Dir, FI#file_info{mode = Mode});
	_Err ->
	    error_logger:format("Failed to read_file_info(~s)~n", [Dir])
    end.


gserv(_, []) ->
    proc_lib:init_ack(none);

%% One server per IP we listen to
gserv(GC, Group0) ->
    process_flag(trap_exit, true),
    ?TC([{record, GC, gconf}]),
    Group = map(fun(SC) -> 
			E = ets:new(yaws_code, [public, set]),
			ets:insert(E, {num_files, 0}),
			ets:insert(E, {num_bytes, 0}),
			Auth = setup_auth(SC),
			SC#sconf{ets = E,
				 authdirs = Auth}
		end, Group0),
    SC = hd(Group),
    case do_listen(SC) of
	{SSLBOOL, {ok, Listen}} ->
	    call_start_mod(SC),
	    error_logger:info_msg(
	      "Yaws: Listening to ~s:~w for servers~s~n",
	      [yaws:fmt_ip(SC#sconf.listen),
	       SC#sconf.port,
	       catch map(fun(S) ->  
				 io_lib:format("~n - ~s under ~s",
					       [S#sconf.servername,
						S#sconf.docroot])
			 end, Group)
	      ]),
	    proc_lib:init_ack({self(), Group}),
	    N = receive
		    {newuid, UID} ->
			UID
		end,
	    GS = #gs{gconf = GC#gconf{uid = N},
		     group = Group,
		     ssl = SSLBOOL,
		     l = Listen},
	    acceptor(GS),
	    gserv(GS, [], 0);
	{_,Err} ->
	    error_logger:format("Yaws: Failed to listen ~s:~w  : ~p~n",
				[yaws:fmt_ip(SC#sconf.listen),
				 SC#sconf.port, Err]),
	    proc_lib:init_ack({error, "Can't listen to socket: ~p ",[Err]}),
	    exit(normal)
    end.
			

setup_tdir(GC) ->
    Tdir = yaws:tmp_dir()++"/yaws/" ++ GC#gconf.uid,
    file:make_dir(Tdir),
    set_dir_mode(Tdir, 8#700),
    case file:list_dir(Tdir) of
	{ok, Files0} ->
	    case lists:zf(
		   fun(F) -> 
			   Fname = Tdir ++ "/" ++ F,
			   case file:delete(Fname) of
			       ok ->
				   false;
			       {error, Reason} ->
				   {true, {Fname, Reason}}
			   end
		   end, Files0) of
		[] ->
		    ok;
		[{FF, RR}|_] ->
		    error_logger:format("Failed to delete ~p~n~p", [FF, RR]),
		    {error, RR}
	    end;
	{error, Reason} ->
	    error_logger:format("Failed to list ~p probably "
				"due to permission errs: ~p",
				[Tdir, Reason]),
	    {error, Reason}
    end.




gserv(GS, Ready, Rnum) ->
    receive
	{From , status} ->
	    From ! {self(), GS},
	    gserv(GS, Ready, Rnum);
	{_From, next} when Ready == [] ->
	    acceptor(GS),
	    gserv(GS, Ready, Rnum);
	{_From, next} ->
	    [R|RS] = Ready,
	    R ! {self(), accept},
	    gserv(GS, RS, Rnum-1);
	{From, done_client, Int} ->
	    GS2 = GS#gs{sessions = GS#gs.sessions + 1,
			reqs = GS#gs.reqs + Int},
	    if
		Rnum == 8 ->
		    From ! {self(), stop},
		    gserv(GS2, Ready, Rnum);
		Rnum < 8 ->
		    gserv(GS2, [From | Ready], Rnum+1)
	    end;
	{'EXIT', _Pid, _} ->
	    gserv(GS, Ready, Rnum);
	{From, stop} ->   
	    unlink(From),
	    {links, Ls} = process_info(self(), links),
	    lists:foreach(fun(X) -> unlink(X), exit(X, kill) end, Ls),
	    From ! {self(), ok},
	    exit(normal)
    end.
	    
 
call_start_mod(SC) ->
    case SC#sconf.start_mod of
	undefined ->
	    ok;
	Mod0 ->
	    Mod = l2a(Mod0),
	    case code:ensure_loaded(Mod) of
		{module, Mod} ->
		    spawn(Mod, start, [SC]);
		Err ->
		    error_logger:format("Cannot load module ~p: ~p~n", 
					[Mod,Err])
	    end
    end.



opts(SC) ->
    [binary, 
     {ip, SC#sconf.listen},
     {packet, http},
     {recbuf, 8192},
     {reuseaddr, true},
     {active, false}
    ].



ssl_opts(SC, SSL) ->
    Opts = [
	    binary,
	    {ip, SC#sconf.listen},
	    {packet, 0},
	    {active, false} | ssl_opts(SSL)],
    ?Debug("SSL opts  ~p~n", [Opts]),
    Opts.




ssl_opts(SSL) ->
    L = [if SSL#ssl.keyfile /= undefined ->
		 {keyfile, SSL#ssl.keyfile};
	    true ->
		 false
	 end,
	 
	 if SSL#ssl.certfile /= undefined ->
		 {certfile, SSL#ssl.certfile};
	    true ->
		 false
	 end,

	 if SSL#ssl.cacertfile /= undefined ->
		 {cacertfile, SSL#ssl.cacertfile};
	    true ->
		 false
	 end,
	 
	 if SSL#ssl.verify /= undefined ->
		 {verify, SSL#ssl.verify};
	    true ->
		 false
	 end,
	 
	 if SSL#ssl.password /= undefined ->
		 {password, SSL#ssl.password};
	    true ->
		 false
	 end,
	 if SSL#ssl.ciphers /= undefined ->
		 {ciphers, SSL#ssl.ciphers};
	    true ->
		 false
	 end
	],
    filter_false(L).


filter_false(L) ->
    [X || X <- L, X /= false].

	   
	 
do_accept(GS) when GS#gs.ssl == nossl ->
    ?Debug("wait in accept ... ~n",[]),
    gen_tcp:accept(GS#gs.l);
do_accept(GS) when GS#gs.ssl == ssl ->
    ssl:accept(GS#gs.l).


acceptor(GS) ->
    proc_lib:spawn_link(yaws_server, acceptor0, [GS, self()]).
acceptor0(GS, Top) ->
    ?TC([{record, GS, gs}]),
    X = do_accept(GS),
    ?Debug("do_accept ret: ~p~n", [X]),
    Top ! {self(), next},
    case X of
	{ok, Client} ->
	    case (GS#gs.gconf)#gconf.trace of  %% traffic trace
		{true, _} ->
		    {ok, {IP, Port}} = case GS#gs.ssl of
					   ssl ->
					       ssl:peername(Client);
					   nossl ->
					       inet:peername(Client)
				       end,
		    Str = ?F("New (~p) connection from ~s:~w~n", 
			     [GS#gs.ssl, yaws:fmt_ip(IP),Port]),
		    yaws_log:trace_traffic(from_client, Str);
		_ ->
		    ok
	    end,

	    Res = (catch aloop(Client, GS,  0)),
	    ?Debug("RES = ~p~n", [Res]),
	    if
		GS#gs.ssl == nossl ->
		    gen_tcp:close(Client);
		GS#gs.ssl == ssl ->
		    ssl:close(Client)
	    end,
	    case Res of
		{ok, Int} when integer(Int) ->
		    Top ! {self(), done_client, Int};
		{'EXIT', normal} ->
		    exit(normal);
		{'EXIT', Reason} ->
		    error_logger:error_msg("Yaws process died: ~p~n", [Reason]),
		    exit(normal)
	    end,

	    %% we cache processes
	    receive
		{Top, stop} ->
		    exit(normal);
		{Top, accept} ->
		    acceptor0(GS, Top)
	    end;
	ERR ->
	    yaws_debug:derror(GS#gs.gconf, "Failed to accept: ~p~n", [ERR]),
	    exit(normal)
    end.
     


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

aloop(CliSock, GS, Num) ->
    SSL = GS#gs.ssl,
    ?TC([{record, GS, gs}]),
    case  yaws:http_get_headers(CliSock, GS#gs.gconf, SSL) of
	{Req, H} ->
	    SC = pick_sconf(GS#gs.gconf, H, GS#gs.group, SSL),
	    ?Debug("SC: ~p", [?format_record(SC, sconf)]),
	    ?TC([{record, SC, sconf}]),
	    ?Debug("Headers = ~p~n", [?format_record(H, headers)]),
	    ?Debug("Request = ~p~n", [?format_record(Req, http_request)]),
	    IP = case SC#sconf.access_log of
		     true ->
			 {ok, {Ip, _Port}} = peername(CliSock, SSL),
			 Ip;
		     _ ->
			 undefined
		 end,
	    put(outh, #outh{}),
	    handle_method_result(
	      call_method(Req#http_request.method, CliSock, 
			  GS#gs.gconf, SC, Req, H),
	      CliSock, IP, GS, SC, Req, H, Num);
	closed -> {ok, Num}
    end.


handle_method_result(Res, CliSock, IP, GS, SC, Req, H, Num) ->
    case Res of
	continue ->
	    maybe_access_log(IP, SC, Req, H),
	    erase(post_parse),
	    erase(query_parse),
	    erase(outh),
	    lists:foreach(fun(X) ->
				  case X of
				      {binding, _} ->
					  erase(X);
				      _ ->
					  ok
				  end
			  end, get()),
				      
	    aloop(CliSock, GS, Num+1);
	done ->
	    maybe_access_log(IP, SC, Req, H),
	    {ok, Num+1};
	{page, P} ->		    
	    put(outh, #outh{}),
	    case P of
		{Options, Page} ->
						% We got additional headers
						% for the page to deliver.
						%
						% Might be useful for
						% `Vary' or
						% `Content-Location'.
		    deepforeach(
		      fun(X) -> case X of
				    {header, Header} ->
					yaws:accumulate_header(Header);
				    _Something ->
					?Debug("Got ~p in page option list.",
					    [_Something])
				end
		      end,
		      Options);
		Page ->
		    ok
	    end,
	    handle_method_result(
	      call_method(Req#http_request.method, 
			CliSock, GS#gs.gconf, SC#sconf{appmods=[]}, 
			Req#http_request{path = {abs_path, Page}}, H),
	      CliSock, IP, GS, SC, Req, H, Num)
    end.


peername(CliSock, ssl) ->
    ssl:peername(CliSock);
peername(CliSock, nossl) ->
    inet:peername(CliSock).


deepforeach(_F, []) ->
    ok;
deepforeach(F, [H|T]) ->
    deepforeach(F, H),
    deepforeach(F, T);
deepforeach(F, X) ->
    F(X).


pick_sconf(_GS, _H, Group, ssl) ->
    hd(Group);

pick_sconf(GS, H, Group, nossl) ->
    case H#headers.host of
	undefined ->
	    hd(Group);
	Host ->
	    pick_host(GS, Host, Group, Group)
    end.


pick_host(_GC, Host, [H|_T], _Group) when H#sconf.servername == Host ->
    H;
pick_host(GC, Host, [_|T], Group) ->
    pick_host(GC, Host, T, Group);
pick_host(_GC, _Host, [], Group) ->
    hd(Group).


inet_peername(Sock, SC) ->
    case SC#sconf.ssl of
	undefined ->
	    inet:peername(Sock);
	_SSL ->
	    ssl:peername(Sock)
    end.
	    

maybe_access_log(Ip, SC, Req, H) ->
    ?TC([{record, SC, sconf}]),
    case SC#sconf.access_log of
	true ->
	    Status = case yaws:outh_get_status_code() of
			 undefined -> "-";
			 I -> integer_to_list(I)
		     end,
	    Len = case Req#http_request.method of
		      'HEAD' -> "-";  % ???
		      _ -> case yaws:outh_get_contlen() of
			       undefined ->
				   case yaws:outh_get_act_contlen() of
				       undefined -> "-";
				       Actlen -> integer_to_list(Actlen)
				   end;
			       I2 -> integer_to_list(I2)
			   end
		  end,
	    Ver = case Req#http_request.version of
		      {1,0} ->
			  "HTTP/1.0";
		      {1,1} ->
			  "HTTP/1.1";
		      {0,9} ->
			  "HTTP/0.9" 
		  end,
	    Path = safe_decode_path(Req#http_request.path),
	    Meth = yaws:to_list(Req#http_request.method),
	    Referrer = optional_header(H#headers.referer),
	    UserAgent = optional_header(H#headers.user_agent),
	    yaws_log:accesslog(SC#sconf.servername, Ip, 
			       [Meth, $\s, Path, $\s, Ver], 
			       Status, Len, Referrer, UserAgent);	
	false ->
	    ignore
    end.

safe_decode_path(Path) ->
    case (catch decode_path(Path)) of
	{'EXIT', _} ->
	    "/undecodable_path";
	Val ->
	    Val 
    end.


decode_path({abs_path, Path}) ->
    yaws_api:url_decode(Path).

optional_header(Item) ->
    case Item of
	undefined -> "-";
	Item -> Item
    end.

inet_setopts(SC, S, Opts) when SC#sconf.ssl == undefined ->
    inet:setopts(S, Opts);
inet_setopts(_,_,_) ->
    ok.  %% noop for ssl


%% ret:  continue | done
'GET'(CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    ?Debug("GET ~p", [?format_record(Req, http_request)]),
    ok = inet_setopts(SC, CliSock, [{packet, raw}, binary]),
    flush(SC, CliSock, Head#headers.content_length),
    ARG = make_arg(CliSock, Head, Req, GC, SC, undefined),
    handle_request(CliSock, GC, SC, ARG, 0).


'POST'(CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    ?Debug("POST Req=~p H=~p~n", [?format_record(Req, http_request),
				  ?format_record(Head, headers)]),
    ok = inet_setopts(SC, CliSock, [{packet, raw}, binary]),
    PPS = SC#sconf.partial_post_size,
    Bin = case Head#headers.content_length of
	      undefined ->
		  case Head#headers.connection of
		      "close" ->
			  get_client_data(CliSock, all, GC,
					  is_ssl(SC#sconf.ssl));
		      _ ->
			  ?Debug("No content length header ",[]),
			  exit(normal)
		  end;
	      Len when integer(PPS) ->
		  Int_len = list_to_integer(Len),
		  if 
		      Int_len == 0 ->
			  <<>>;
		      PPS < Int_len ->
			  {partial, get_client_data(CliSock, PPS, GC,
						    is_ssl(SC#sconf.ssl))};
		      true ->
			  get_client_data(CliSock, Int_len, GC, 
					  is_ssl(SC#sconf.ssl))
		  end;
	      Len when PPS == nolimit ->
		  Int_len = list_to_integer(Len),
		  if
		      Int_len == 0 ->
			  <<>>;
		      true ->
			  get_client_data(CliSock, Int_len, GC, 
					  is_ssl(SC#sconf.ssl))
		  end
	  end,
    ?Debug("POST data = ~s~n", [binary_to_list(un_partial(Bin))]),
    ARG = make_arg(CliSock, Head, Req, GC, SC, Bin),
    handle_request(CliSock, GC, SC, ARG, size(un_partial(Bin))).


is_ssl(undefined) ->
    nossl;
is_ssl(R) when record(R, ssl) ->
    ssl.

un_partial({partial, Bin}) ->
    Bin;
un_partial(Bin) ->
    Bin.


call_method(Method, CliSock, GC, SC, Req, H) ->
    case Method of
	F when atom(F) ->
	    ?MODULE:F(CliSock, GC, SC, Req, H);
	L when list(L) ->
	    handle_extension_method(L, CliSock, GC, SC, Req, H)
    end.


'HEAD'(CliSock, GC, SC, Req, Head) ->
    put(acc_content, discard),
    'GET'(CliSock, GC, SC, Req, Head).

not_implemented(CliSock, GC, SC, Req, Head) ->
    ok = inet_setopts(SC, CliSock, [{packet, raw}, binary]),
    flush(SC, CliSock, Head#headers.content_length),
    deliver_501(CliSock, Req, GC, SC).
    

'TRACE'(CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    not_implemented(CliSock, GC, SC, Req, Head).

'PUT'(CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    not_implemented(CliSock, GC, SC, Req, Head).

'DELETE'(CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    not_implemented(CliSock, GC, SC, Req, Head).

'OPTIONS'(CliSock, GC, SC, Req, Head) ->
    ?Debug("OPTIONS", []),
    ok = inet_setopts(SC, CliSock, [{packet, raw}, binary]),
    flush(SC, CliSock, Head#headers.content_length),
 %% _ARG = make_arg(CliSock, Head, Req, GC, SC),
    ?Debug("OPTIONS delivering", []),
    deliver_options(CliSock, Req, GC, SC).

make_arg(CliSock, Head, Req, _GC, SC, Bin) ->
    ?TC([{record, _GC, gconf}, {record, SC, sconf}]),
    ARG = #arg{clisock = CliSock,
	       headers = Head,
	       req = Req,
	       opaque = SC#sconf.opaque,
	       pid = self(),
	       docroot = SC#sconf.docroot,
	       clidata = Bin},
    apply(SC#sconf.arg_rewrite_mod, arg_rewrite, [ARG]).

handle_extension_method(_Method, CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    not_implemented(CliSock, GC, SC, Req, Head).


%% Return values:
%% continue, done, {page, Page}

handle_request(CliSock, GC, SC, ARG, N) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    Req = ARG#arg.req,
    ?Debug("SrvReq=~p~n",[Req]),
    case Req#http_request.path of
	{abs_path, RawPath} ->
	    case (catch yaws_api:url_decode_q_split(RawPath)) of
		{'EXIT', _} ->   %% weird broken cracker requests
		    deliver_400(CliSock, Req, GC, SC);
		{DecPath, QueryPart} ->
		    ?Debug("Test revproxy: ~p and ~p~n", [DecPath, 
			                                  SC#sconf.revproxy]),
		    case {is_auth(DecPath,ARG#arg.headers,SC#sconf.authdirs),
			  is_revproxy(DecPath, SC#sconf.revproxy)} of
			{true, false} ->
			    UT   = url_type(GC, SC, DecPath),
			    ARG2 = ARG#arg{server_path = DecPath,
					   querydata= QueryPart,
					   fullpath=UT#urltype.fullpath,
					   pathinfo=UT#urltype.pathinfo},
			    handle_ut(CliSock, GC, SC, ARG2, UT, N);
			{true, {true, PP}} ->
			    yaws_revproxy:init(CliSock, GC,SC,ARG,
					       DecPath,QueryPart,PP);
			{{false, Realm}, _} ->
			    deliver_401(CliSock, Req, GC, Realm, SC)
		    end
	    end;
	{absoluteURI, Scheme, Host, Port, RawPath} ->
						% FIXME:
						% 
						% We MUST accept this.
						% We cannot fix it at
						% this point alone
						% however, because we
						% may already have
						% picked the wrong
						% sconf.
	    deliver_501(CliSock, Req, GC, SC);
	{scheme, _Scheme, _RequestString} ->
	    deliver_501(CliSock, Req, GC, SC);
	_ ->                                    % for completeness
	    deliver_400(CliSock, Req, GC, SC)
    end.


is_auth(_Req_dir, _H, [] ) -> true;
is_auth(Req_dir, H, [{Auth_dir, #auth{realm=Realm, users=Users}} | T ] ) ->
    case lists:prefix(Auth_dir, Req_dir) of
	true ->
	    case H#headers.authorization of
		undefined ->
		    {false, Realm};
		{User, Password} ->
		    case lists:member({User, Password}, Users) of
			true ->
			    true;
			false ->
			    {false, Realm}
		    end
	    end;
	false ->
	    is_auth(Req_dir, H, T)
    end.


is_revproxy(_,[]) ->
    false;
is_revproxy(Path, [{Prefix, URL} | Tail]) ->
    case yaws:is_prefix(Prefix, Path) of
	{true,_} ->
	    {true, {Prefix,URL}};
	false ->
	    is_revproxy(Path, Tail)
    end.


%% Return values:
%% continue, done, {page, Page}

handle_ut(CliSock, GC, SC, ARG, UT, N) ->
    Req = ARG#arg.req,
    H = ARG#arg.headers,
    case UT#urltype.type of
	error ->
	    yaws:outh_set_dyn_headers(Req, H),
	    deliver_dyn_part(CliSock, GC, SC, 
			     0, "404",
			     N,
			     ARG,
			     fun(A)->(SC#sconf.errormod_404):
					 out404(A,GC,SC) 
			     end,
			     fun(A)->finish_up_dyn_file(CliSock, GC, SC)
			     end
			    );
	directory when SC#sconf.dir_listings == true ->
	    P = UT#urltype.dir,
	    yaws:outh_set_dyn_headers(Req, H),
	    yaws_ls:list_directory(CliSock, UT#urltype.data, P, Req, GC, SC);
	directory ->
	    handle_ut(CliSock, GC, SC, ARG, #urltype{type = error}, N);
	regular ->
	    ETag = yaws:make_etag(UT#urltype.finfo),
	    Range = case H#headers.if_range of
			Range_etag = [$"|_] when Range_etag /= ETag ->
			    all;
			_ ->
			    requested_range(H#headers.range, 
					    (UT#urltype.finfo)#file_info.size)
		    end,
	    case Range of
		error -> deliver_416(CliSock, Req, GC, SC,
				     (UT#urltype.finfo)#file_info.size);
		_ ->
		    case H#headers.if_none_match of
			undefined ->
			    case H#headers.if_match of
				undefined -> 				    
				    yaws:outh_set_static_headers
				      (Req, UT, H, Range),
				    deliver_file
				      (CliSock, GC, SC, Req, UT, Range);

				Line -> 
				    case lists:member(ETag,
						      yaws:split_sep(
							Line, $,)) of
					true -> 
					    yaws:outh_set_static_headers
					      (Req, UT, H, Range),
					    deliver_file(CliSock, GC, SC, 
							 Req, UT, Range);
					false ->
					    deliver_xxx(CliSock, Req, GC, SC, 
							412)
				    end
			    end;
			Line ->
			    case lists:member(ETag,
					      yaws:split_sep(Line, $,)) of
				true ->
				    yaws:outh_set_304_headers(Req, UT, H),
				    deliver_accumulated(CliSock, GC, SC),
				    done_or_continue();
				false ->
				    yaws:outh_set_static_headers
				      (Req, UT, H, Range),
				    deliver_file(CliSock, GC, SC, Req, 
						 UT, Range)
			    end
		    end
	    end;
	yaws ->
	    yaws:outh_set_dyn_headers(Req, H),
	    do_yaws(CliSock, GC, SC, ARG, UT, N);
	forbidden ->
	    yaws:outh_set_dyn_headers(Req, H),
	    deliver_403(CliSock, Req, GC, SC);
	redir_dir ->
	    yaws:outh_set_dyn_headers(Req, H),
	    deliver_302(CliSock, Req, GC, SC, ARG);
	appmod ->
	    yaws:outh_set_dyn_headers(Req, H),
 	    {Mod, PathData} = UT#urltype.data,
 	    A2 = ARG#arg{appmoddata = PathData,
 			 appmod_prepath = UT#urltype.path},
	    deliver_dyn_part(CliSock, GC, SC, 
			     0, "appmod",
			     N,
			     A2,
			     fun(A)->Mod:out(A) end,
			     fun(A)->finish_up_dyn_file(CliSock, GC, SC)
			     end
			    );
	cgi ->
	    yaws:outh_set_dyn_headers(Req, H),
	    deliver_dyn_part(CliSock, GC, SC, 
			     0, "cgi",
			     N,
			     ARG,
			     fun(A)->yaws_cgi:call_cgi(A,
						       UT#urltype.fullpath)
			     end,
			     fun(A)->finish_up_dyn_file(CliSock, GC, SC)
			     end
			    );
	php ->
	    yaws:outh_set_dyn_headers(Req, H),
	    deliver_dyn_part(CliSock, GC, SC, 
			     0, "php",
			     N,
			     ARG,
			     fun(A)->yaws_cgi:call_cgi(A,
						       SC#sconf.phpexe,
						       UT#urltype.fullpath)
			     end,
			     fun(A)->finish_up_dyn_file(CliSock, GC, SC)
			     end
			    )
    end.



done_or_continue() ->
    case yaws:outh_get_doclose() of
	true -> done;
	false -> continue
    end.
	    


%% we may have content, 

new_redir_h(OH, Loc) ->
    new_redir_h(OH, Loc, 302).

new_redir_h(OH, Loc, Status) ->
    OH2 = OH#outh{status = Status,
		  location = Loc},
    put(outh, OH2).



% we must deliver a 302 if the browser asks for a dir
% without a trailing / in the HTTP req
% otherwise the relative urls in /dir/index.html will be broken.


deliver_302(CliSock, Req, GC, SC, Arg) ->
    ?Debug("in redir 302 ",[]),
    H = get(outh),

    Scheme = redirect_scheme(SC),
    Headers = Arg#arg.headers,
    DecPath = decode_path(Req#http_request.path),
    RedirHost = redirect_host(SC, Headers#headers.host),
    Loc = case string:tokens(DecPath, "?") of
	      [P] ->
		  ["Location: ", Scheme,
		   RedirHost, P, "/\r\n"];
	      [P, Q] ->
		  ["Location: ", Scheme,
		   RedirHost, P, "/?", Q, "\r\n"]
	  end,
    
    Ret = case yaws:outh_get_chunked() of
	      true ->
		  accumulate_content([crnl(), "0", crnl2()]),
		  continue;
	      false ->
		  done
	  end,

    new_redir_h(H, Loc),
    deliver_accumulated(CliSock, GC, SC),
    Ret.


redirect_scheme(SC) ->
    case {SC#sconf.ssl,SC#sconf.rmethod} of
	{_, Method} when list(Method) ->
	    Method++"://";
	{undefined,_} ->
	    "http://";
	{_SSl,_} ->
	    "https://"
    end.    

redirect_host(SC, HostHdr) ->
    case SC#sconf.rhost of
	undefined ->
	    if HostHdr == undefined ->
		    servername_sans_port(SC#sconf.servername)++redirect_port(SC);
	       true ->
		    HostHdr
	    end;
	_ ->
	    SC#sconf.rhost
    end.

redirect_port(SC) ->
    case {SC#sconf.rmethod, SC#sconf.ssl, SC#sconf.port} of
	{"https", _, 443} -> "";
	{"http", _, 80} -> "";
	{_, undefined, 80} -> "";
	{_, undefined, Port} -> 
               [$:|integer_to_list(Port)];
	{_, _SSL, 443} ->
               "";
	{_, _SSL, Port} -> 
               [$:|integer_to_list(Port)]
    end.    

redirect_scheme_port(SC) ->
    Scheme = redirect_scheme(SC),
    PortPart = redirect_port(SC),
    {Scheme, PortPart}.

servername_sans_port(Servername) ->
    case string:chr(Servername, $:) of
	0 ->
	    Servername;
	N ->
	    lists:sublist(Servername, N-1)
    end.

deliver_options(CliSock, _Req, GC, SC) ->
    H = #outh{status = 200,
	      doclose = false,
	      chunked = false,
	      server = yaws:make_server_header(),
	      allow = yaws:make_allow_header()},
    put(outh, H),
    deliver_accumulated(CliSock, GC, SC),
    continue.

deliver_xxx(CliSock, _Req, GC, SC, Code) ->
    B = list_to_binary(["<html><h1>",
			integer_to_list(Code), $\ ,
			yaws_api:code_to_phrase(Code),
			"</h1></html>"]),
    H = #outh{status = Code,
	      doclose = true,
	      chunked = false,
	      server = yaws:make_server_header(),
	      connection = yaws:make_connection_close_header(true),
	      content_length = yaws:make_content_length_header(size(B)),
	      contlen = size(B),
	      content_type = yaws:make_content_type_header("text/html")},
    put(outh, H),
    accumulate_content(B),
    deliver_accumulated(CliSock, GC, SC),
    done.

deliver_400(CliSock, Req, GC, SC) ->  
						% Bad Request
    deliver_xxx(CliSock, Req, GC, SC, 400).

deliver_401(CliSock, _Req, GC, Realm, SC) ->
    B = list_to_binary("<html> <h1> 401 authentication needed  "
		       "</h1></html>"),
    H = #outh{status = 401,
	      doclose = true,
	      chunked = false,
	      server = yaws:make_server_header(),
	      connection = yaws:make_connection_close_header(true),
	      content_length = yaws:make_content_length_header(size(B)),
	      www_authenticate = yaws:make_www_authenticate_header(Realm),
	      contlen = size(B),
	      content_type = yaws:make_content_type_header("text/html")},
    put(outh, H),
    accumulate_content(B),
    deliver_accumulated(CliSock, GC, SC),
    done.
    
deliver_403(CliSock, Req, GC, SC) ->
						% Forbidden
    deliver_xxx(CliSock, Req, GC, SC, 403).
    
deliver_416(CliSock, _Req, GC, SC, Tot) ->
    B = list_to_binary(["<html><h1>416 ",
			yaws_api:code_to_phrase(416),
			"</h1></html>"]),
    H = #outh{status = 416,
	      doclose = true,
	      chunked = false,
	      server = yaws:make_server_header(),
	      connection = yaws:make_connection_close_header(true),
	      content_range = ["Content-Range: */", 
			       integer_to_list(Tot), $\r, $\n],
	      content_length = yaws:make_content_length_header(size(B)),
	      contlen = size(B),
	      content_type = yaws:make_content_type_header("text/html")},
    put(outh, H),
    accumulate_content(B),
    deliver_accumulated(CliSock, GC, SC),
    done.

deliver_501(CliSock, Req, GC, SC) ->
						% Not implemented
    deliver_xxx(CliSock, Req, GC, SC, 501).
    


do_yaws(CliSock, GC, SC, ARG, UT, N) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    FileAtom = list_to_atom(UT#urltype.fullpath),
    ?Debug("FileAtom = ~p~nUT=~p~n",[FileAtom, UT]),
    Mtime = mtime(UT#urltype.finfo),
    case ets:lookup(SC#sconf.ets, FileAtom) of
	[{FileAtom, spec, Mtime1, Spec, Es}] when Mtime1 == Mtime,
						  Es == 0 ->
	    deliver_dyn_file(CliSock, GC, SC, Spec, ARG, UT, N);
	Other  ->
	    del_old_files(Other),
	    {ok, [{errors, Errs}| Spec]} = 
		yaws_compile:compile_file(UT#urltype.fullpath, GC, SC),
	    ?Debug("Spec for file ~s is:~n~p~n",[UT#urltype.fullpath, Spec]),
	    ets:insert(SC#sconf.ets, {FileAtom, spec, Mtime, Spec, Errs}),
	    deliver_dyn_file(CliSock, GC, SC, Spec, ARG, UT, N)
    end.


del_old_files([]) ->
    ok;
del_old_files([{_FileAtom, spec, _Mtime1, Spec, _}]) ->
    lists:foreach(
      fun({mod, _, _, _,  Mod, _Func}) ->

	      F=yaws:tmp_dir()++"/yaws/" ++ yaws:to_list(Mod) ++ ".erl",
	      code:purge(Mod),
	      code:purge(Mod),
	      file:delete(F);
	 (_) ->
	      ok
      end, Spec).
		     

get_client_data(CliSock, all, GC, SSlBool) ->
    get_client_data_all(CliSock, [], GC, SSlBool);

get_client_data(CliSock, Len, GC, SSlBool) ->
    get_client_data_len(CliSock, Len, [], GC, SSlBool).


get_client_data_len(_CliSock, 0, Bs, _GC, _SSlBool) ->
    list_to_binary(Bs);
get_client_data_len(CliSock, Len, Bs, GC, SSlBool) ->
    case yaws:cli_recv(CliSock, Len, GC, SSlBool) of
	{ok, B} ->
	    get_client_data_len(CliSock, Len-size(B), [Bs|B], GC, SSlBool);
	_Other ->
	    ?Debug("get_client_data_len: ~p~n", [_Other]),
	    exit(normal)
    end.

get_client_data_all(CliSock, Bs, GC, SSlBool) ->
    case yaws:cli_recv(CliSock, 4000, GC, SSlBool) of
	{ok, B} ->
	    get_client_data_all(CliSock, [Bs|B] , GC, SSlBool);
	eof ->
	    list_to_binary(Bs);
	_Other ->
	    ?Debug("get_client_data_all: ~p~n", [_Other]),
	    exit(normal)
    end.




%% Return values:
%% continue, done, {page, Page}

deliver_dyn_part(CliSock, GC, SC,          % essential params
		 LineNo, YawsFile,         % for diagnostic output
		 CliDataPos,               % for `get_more'
		 Arg,
		 YawsFun,                  % call YawsFun(Arg)
		 DeliverCont               % call DeliverCont(Arg)
						% to continue normally
		) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf},{record, Arg, arg}]),
    Res = (catch YawsFun(Arg)),
    case handle_out_reply(Res, LineNo, YawsFile, SC, [Arg]) of
	{get_more, Cont, State} when 
	      element(1, Arg#arg.clidata) == partial  ->
	    More = get_more_post_data(SC#sconf.partial_post_size, 
				      CliDataPos, SC, GC, Arg),
	    case un_partial(More) of
		Bin when binary(Bin) ->
		    A2 = Arg#arg{clidata = More,
				 cont = Cont,
				 state = State},
		    deliver_dyn_part(
		      CliSock, GC, SC, LineNo, YawsFile, 
		      CliDataPos+size(un_partial(More)), 
		      A2, YawsFun, DeliverCont
		     );
		Err ->
		    A2 = Arg#arg{clidata = Err,
				 cont = undefined,
				 state = State},
		    catch YawsFun(A2),
		    exit(normal)         % ???
	    end;
	break ->
	    finish_up_dyn_file(CliSock, GC, SC);
	{page, Page} ->
	    {page, Page};
        Arg2 = #arg{} ->
	    DeliverCont(Arg2);
	{streamcontent, MimeType, FirstChunk} ->
	    yaws:outh_set_content_type(MimeType),
	    accumulate_chunk(FirstChunk),
	    case deliver_accumulated(CliSock, GC, SC) of
		discard ->
		    stream_loop_discard(CliSock, GC, SC);
		_ -> 
		    stream_loop_send(CliSock, GC, SC)
	    end;
	{streamcontent_with_size, Sz, MimeType, FirstChunk} ->
	    yaws:outh_set_content_type(MimeType),
	    yaws:outh_set_transfer_encoding_off(),
	    yaws:outh_set_content_length(Sz),
	    accumulate_chunk(FirstChunk),
	    case deliver_accumulated(CliSock, GC, SC) of
		discard ->
		    stream_loop_discard(CliSock, GC, SC);
		_ -> 
		    stream_loop_send(CliSock, GC, SC)
	    end,
	    done;
	_ ->
	    DeliverCont(Arg)
    end.

finish_up_dyn_file(CliSock, GC, SC) ->
    case yaws:outh_get_chunked() of
	true ->
	    accumulate_content([crnl(), "0", crnl2()]),
	    deliver_accumulated(CliSock, GC, SC),
	    continue;
	false ->
	    case deliver_accumulated(CliSock, GC, SC) of
		discard -> done_or_continue();
		_ -> done
	    end
    end.



%% do the header and continue
deliver_dyn_file(CliSock, GC, SC, Specs, ARG, UT, N) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    Fd = ut_open(UT),
    Bin = ut_read(Fd),
    deliver_dyn_file(CliSock, GC, SC, Bin, Fd, Specs, ARG, N).



deliver_dyn_file(CliSock, GC, SC, Bin, Fd, [H|T],Arg,N) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}, {record, Arg, arg}]),
    ?Debug("deliver_dyn_file: ~p~n", [H]),
    case H of
	{mod, LineNo, YawsFile, NumChars, Mod, out} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    deliver_dyn_part(CliSock, GC, SC, LineNo, YawsFile,
			     N, Arg, 
			     fun(A)->Mod:out(A) end,
			     fun(A)->deliver_dyn_file(
				      CliSock, GC, SC, 
				      Bin2,Fd,T,A,0)
			     end);
	{data, 0} ->
	    deliver_dyn_file(CliSock, GC, SC, Bin, Fd,T,Arg,N);
	{data, NumChars} ->
	    {Send, Bin2} = skip_data(Bin, Fd, NumChars),
	    accumulate_chunk(Send),
	    deliver_dyn_file(CliSock, GC, SC, Bin2, Fd, T,Arg,N);
	{skip, 0} ->
	    deliver_dyn_file(CliSock, GC, SC, Bin, Fd,T,Arg,N);
	{skip, NumChars} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    deliver_dyn_file(CliSock, GC, SC, Bin2, Fd, T,Arg,N);
	{binding, NumChars} ->
	    {Send, Bin2} = skip_data(Bin, Fd, NumChars),
	    "%%"++Key = binary_to_list(Send),
	    Chunk =
		case get({binding, Key--"%%"}) of
		    undefined -> Send;
		    Value -> Value
		end,
	    accumulate_chunk(Chunk),
	    deliver_dyn_file(CliSock, GC, SC, Bin2, Fd, T, Arg, N);
	{error, NumChars, Str} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    accumulate_chunk(Str),
	    deliver_dyn_file(CliSock, GC, SC, Bin2, Fd, T,Arg,N)
    end;

deliver_dyn_file(CliSock, GC, SC, _Bin, _Fd, [], _ARG,_N) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    ?Debug("deliver_dyn: done~n", []),
    finish_up_dyn_file(CliSock, GC, SC).


stream_loop_send(CliSock, GC, SC) ->
    receive
	{streamcontent, Cont} ->
	    send_streamcontent_chunk(CliSock, GC, SC, Cont),
	    stream_loop_send(CliSock, GC, SC) ;
	{streamcontent_with_ack, From, Cont} ->	% acknowledge after send
	    send_streamcontent_chunk(CliSock, GC, SC, Cont),
	    From ! {self(), streamcontent_ack},
	    stream_loop_send(CliSock, GC, SC) ;
	endofstreamcontent ->
	    case yaws:outh_get_chunked() of
		true ->
		    yaws:gen_tcp_send(CliSock, [crnl(), "0", 
						crnl2()], SC, GC),
		    continue;
		false ->
		    done
	    end
    after 30000 ->
	    exit(normal)
    end.



send_streamcontent_chunk(CliSock, GC, SC, Chunk) ->
    accumulate_chunk(Chunk),
    Data = erase(acc_content),
    ?Debug("send ~p bytes to ~p ~n", 
	[size(list_to_binary(Data)), CliSock]),
    yaws:gen_tcp_send(CliSock, Data, SC, GC).
    

stream_loop_discard(CliSock, GC, SC) ->
						% Eat up everything,
						% who knows, where it
						% might end up if we
						% don't!
    receive
	{streamcontent, _Cont} ->
	    stream_loop_discard(CliSock, GC, SC) ;
	{streamcontent_with_ack, From, _Cont} -> % acknowledge after send
	    From ! {self(), streamcontent_ack},
	    stream_loop_discard(CliSock, GC, SC) ;
	endofstreamcontent ->
	    done_or_continue()
    after 30000 ->
	    exit(normal)
    end.

%% what about trailers ??

skip_data(List, Fd, Sz) when list(List) ->
    skip_data(list_to_binary(List), Fd, Sz);
skip_data(Bin, Fd, Sz) when binary(Bin) ->
    ?Debug("Skip data ~p bytes from", [Sz]),
     case  Bin of
	 <<Head:Sz/binary ,Tail/binary>> ->
	     {Head, Tail};
	 _ ->
	     case (catch file:read(Fd, 4000)) of
		 {ok, Bin2} when binary(Bin2) -> 
		     Bin3 = <<Bin/binary, Bin2/binary>>,
		     skip_data(Bin3, Fd, Sz);
		 _Err ->
		     ?Debug("EXIT in skip_data: ~p  ~p ~p~n", [Bin, Sz, _Err]),
		     exit(normal)
	     end
     end;
skip_data({bin, Bin}, _, Sz) ->
    ?Debug("Skip bin data ~p bytes ", [Sz]),
    <<Head:Sz/binary ,Tail/binary>> = Bin,
    {Head, {bin, Tail}};
skip_data({ok, X}, Fd, Sz) ->
    skip_data(X, Fd, Sz).



to_binary(B) when binary(B) ->
    B;
to_binary(L) when list(L) ->
    list_to_binary(L).


%% binary_size(X) -> size(to_binary(X)).

binary_size(X) -> binary_size(0,X).

binary_size(I, []) ->
    I;
binary_size(I, [H|T]) ->
    J = binary_size(I, H),
    binary_size(J, T);
binary_size(I, B) when binary(B) ->
    I + size(B);
binary_size(I, _Int) when integer(_Int) ->
    I+1.

accumulate_header(Data) ->
    case get(acc_headers) of
	undefined ->
	    put(acc_headers, [Data, crnl()]);
	List ->
	    put(acc_headers, [List, Data, crnl()])
    end.

accumulate_content(Data) ->
    case get(acc_content) of
	undefined ->
	    put(acc_content, [Data]);
	discard ->
	    discard;
	List ->
	    put(acc_content, [List, Data])
    end.

accumulate_chunk(Data) ->
    case yaws:outh_get_chunked() of
	false ->
	    yaws:outh_inc_act_contlen(binary_size(Data)),
	    accumulate_content(Data);
	true ->
	    B = to_binary(Data),
	    yaws:outh_inc_act_contlen(size(B)),
	    case size(B) of
		0 ->
		    skip;
		Len ->
		    CRNL = crnl(),
		    Data2 = [CRNL, yaws:integer_to_hex(Len) , crnl(), B], 
		    accumulate_content(Data2)
	    end
    end.



%% handle_out_reply(R, ...)
%% 
%% R is a reply or a deep list of replies.  The special return values
%% `streamcontent', `get_more_data' etc, which are not handled here
%% completely but returned, have to be the last element of the list.

handle_out_reply(L, LineNo, YawsFile, SC, A) when list (L) ->
    handle_out_reply_l(L, LineNo, YawsFile, SC, A, undefined);

handle_out_reply({html, Html}, _LineNo, _YawsFile, _SC, _A) ->
    accumulate_chunk(Html);

handle_out_reply({ehtml, E}, _LineNo, _YawsFile, SC, A) ->
    case safe_ehtml_expand(E, SC) of
	{ok, Val} ->
	    accumulate_chunk(Val);
	{error, ErrStr} ->
	    handle_crash(A,ErrStr,SC)
    end;

handle_out_reply({content, MimeType, Cont}, _LineNo,_YawsFile, _SC, _A) ->
    yaws:outh_set_content_type(MimeType),
    accumulate_chunk(Cont);

handle_out_reply({streamcontent, MimeType, First}, 
		 _LineNo,_YawsFile, _SC, _A) ->
    yaws:outh_set_content_type(MimeType),
    {streamcontent, MimeType, First};

handle_out_reply(Res = {page, Page},
		 _LineNo,_YawsFile, _SC, _A) ->
    Res;

handle_out_reply({streamcontent_with_size, Sz, MimeType, First}, 
		 _LineNo,_YawsFile, _SC, _A) ->
    yaws:outh_set_content_type(MimeType),
    {streamcontent_with_size, Sz, MimeType, First};

handle_out_reply({header, H},  _LineNo, _YawsFile, _SC, _A) ->
    yaws:accumulate_header(H);

handle_out_reply({allheaders, Hs}, _LineNo, _YawsFile, _SC, _A) ->
    yaws:outh_clear_headers(),
    lists:foreach(fun({header, Head}) -> yaws:accumulate_header(Head) end, Hs);

handle_out_reply({status, Code},_LineNo,_YawsFile,_SC,_A) when integer(Code) ->
    yaws:outh_set_status_code(Code);

handle_out_reply({'EXIT', normal}, _LineNo, _YawsFile, _SC, _A) ->
    exit(normal);

handle_out_reply({ssi, File,Delimiter,Bindings}, LineNo, YawsFile, SC, A) ->
    case ssi(File, Delimiter, Bindings, SC) of
	{error, Rsn} ->
	    L = ?F("yaws code at~s:~p had the following err:~n~p",
		   [YawsFile, LineNo, Rsn]),
	    handle_crash(A, L, SC);
	OutData ->
	    accumulate_chunk(OutData)
    end;

handle_out_reply(break, _LineNo, _YawsFile, _SC, _A) ->
    break;

handle_out_reply({redirect_local, Path}, LN, YF, SC, A) ->
    handle_out_reply({redirect_local, Path, 302}, LN, YF, SC, A);

%% What about:
%%
%% handle_out_reply({redirect_local, Path, Status}, LineNo,
%%		 YawsFile, SC, A) when string(Path) ->
%%   handle_out_reply({redirect_local, {any_path, Path}, Status}, LineNo,
%%		 YawsFile, SC, A);    
%%
%% It would introduce a slight incompatibility with earlier versions,
%% but might be desirable.

handle_out_reply({redirect_local, {any_path, URL}, Status}, LineNo,
		 YawsFile, SC, A) ->
    PathType = 
	case yaws_api:is_absolute_URI(URL) of
	    true -> net_path;
	    false -> case URL of
			 [$/|_] -> abs_path;
			 _ -> rel_path
		     end
	end,
    handle_out_reply({redirect_local, {PathType, URL}, Status}, LineNo,
		     YawsFile, SC, A);

handle_out_reply({redirect_local, {net_path, URL}, Status}, _LineNo,
		  _YawsFile, _SC, _A) ->
    Loc = ["Location: ", URL, "\r\n"],
    OH = get(outh),
    new_redir_h(OH, Loc, Status),
    ok;

handle_out_reply({redirect_local, Path0, Status}, _LineNo, _YawsFile, SC, A) ->
    Arg = hd(A),
    Path = case Path0 of
	       {abs_path, P} ->
		   P;
	       {rel_path, P} ->
		   {abs_path, RP} = (Arg#arg.req)#http_request.path,
		   case string:rchr(RP, $/) of
		       0 ->
			   [$/|P];
		       N ->
			   [lists:sublist(RP, N),P]
		   end;
	       P ->
		   P
	   end,
    Scheme = redirect_scheme(SC),
    Headers = Arg#arg.headers,
    HostPort = redirect_host(SC, Headers#headers.host),
    Loc = ["Location: ", Scheme, HostPort, Path, "\r\n"],
    OH = get(outh),
    new_redir_h(OH, Loc, Status),
    ok;

handle_out_reply({redirect, URL}, LN, YF, SC, A) ->
    handle_out_reply({redirect, URL, 302}, LN, YF, SC, A);

handle_out_reply({redirect, URL, Status}, _LineNo, _YawsFile, _SC, _A) ->
    Loc = ["Location: ", URL, "\r\n"],
    OH = get(outh),
    new_redir_h(OH, Loc, Status),
    ok;

handle_out_reply({bindings, L}, _LineNo, _YawsFile, _SC, _A) ->
    lists:foreach(fun({Key, Value}) -> put({binding, Key}, Value) end, L),
    ok;

handle_out_reply(ok, _LineNo, _YawsFile, _SC, _A) ->
    ok;

handle_out_reply({'EXIT', Err}, LineNo, YawsFile, SC, ArgL) ->
    A = hd(ArgL),
    L = ?F("~n~nERROR erlang  code  crashed:~n "
	   "File: ~s:~w~n"
	   "Reason: ~p~nReq: ~p~n",
	   [YawsFile, LineNo, Err, A#arg.req]),
    handle_crash(A, L, SC);

handle_out_reply({get_more, Cont, State}, _LineNo, _YawsFile, _SC, _A) ->
    {get_more, Cont, State};

handle_out_reply(Arg = #arg{},  _LineNo, _YawsFile, _SC, _A) ->
    Arg;

handle_out_reply(Reply, LineNo, YawsFile, SC, ArgL) ->
    A = hd(ArgL),
    L =  ?F("yaws code at ~s:~p crashed or "
	    "ret bad val:~p ~nReq: ~p",
	    [YawsFile, LineNo, Reply, A#arg.req]),
    handle_crash(A, L, SC).

    

handle_out_reply_l([Reply|T], LineNo, YawsFile, SC, A, _Res) ->		  
    case handle_out_reply(Reply, LineNo, YawsFile, SC, A) of
	break ->
	    break;
	{page, Page} ->
	    {page, Page};
	RetVal ->
	    handle_out_reply_l(T, LineNo, YawsFile, SC, A, RetVal)
    end;
handle_out_reply_l([], _LineNo, _YawsFile, _SC, _A, Res) ->
    Res.


%% fast server side include with macrolike variable bindings expansion
ssi(File, Delimiter, Bindings) ->
    ssi(File, Delimiter, Bindings, get(sc)).
ssi(File, Delimiter, Bindings, SC) ->
    Key = {ssi, File, Delimiter},
    FullPath = [SC#sconf.docroot, [$/|File]],
    Mtime = path_to_mtime(FullPath),
    case ets:lookup(SC#sconf.ets, Key) of
	[{_, Parts, Mtime}] ->
	    expand_parts(Parts, Bindings, []);
	_ ->
	    case prim_file:read_file(FullPath) of
		{ok, Bin} ->
		    D =delim_split_file(Delimiter,binary_to_list(Bin),data,[]),
		    ets:insert(SC#sconf.ets,{Key,D, Mtime}),
		    ssi(File, Delimiter, Bindings, SC);
		{error, Rsn} ->
		    {error,Rsn}
	    end
    end.

path_to_mtime(FullPath) ->
    case prim_file:read_file_info(FullPath) of
	{ok, FI} ->
	    mtime(FI);
	Err ->
	    Err
    end.

		     


expand_parts([{data, D} |T], Bs, Ack) ->	    
    expand_parts(T, Bs, [D|Ack]);
expand_parts([{var, V} |T] , Bs, Ack) ->
    case lists:keysearch(V, 1, Bs) of
	{value, {_, Val}} ->
	    expand_parts(T, Bs, [Val|Ack]);
	false ->
	    {error, ?F("No variable binding found for ~p", [V])}
    end;
expand_parts([], _,Ack) ->
    lists:reverse(Ack).

	    

delim_split_file([], Data, _, Ack) ->
    [{data, Data}];
delim_split_file(Del, Data, State, Ack) ->
    case delim_split(Del, Del, Data, []) of
	{H, []} when State == data ->
	    %% Ok, last chunk
	    lists:reverse([{data, H} | Ack]);
	{H, T} when State == data ->
	    delim_split_file(Del, T, var, [{data, H}|Ack]);
	{H, []} when State == var ->
	    lists:reverse([{var, H} | Ack]);
	{H, T} when State == var ->
	    delim_split_file(Del, T, data, [{var, H}|Ack])
    end.


delim_split([H|T], Odel, [H|T1], Ack) ->
    delim_split(T,Odel,T1,Ack);
delim_split([], _Odel, T, Ack) ->
    {lists:reverse(Ack),T};
delim_split([H|_T],Odel, [H1|T1], Ack) when H /= H1 ->
    delim_split(Odel, Odel, T1, [H1|Ack]);
delim_split(_,_,[],Ack) ->
    {lists:reverse(Ack),[]}.



%% Erlang yaws code crashed, display either the
%% actual crash or a custimized error message 

handle_crash(A, L, SC) ->
    ?Debug("handle_crash(~p)~n", [L]),
    yaws:elog("~s", [L]),
    case catch apply(SC#sconf.errormod_crash, crashmsg, [A, SC, L]) of
	{html, Str} ->
	    accumulate_chunk(Str),
	    break;
	{ehtml, Term} ->
	    case safe_ehtml_expand(Term, SC) of
		{error, Reason} ->
		    yaws:elog("~s", [Reason]),
		    %% Aghhh, yet another user crash :-(
		    T2 = [{h2, [], "Internal error"}, {hr},
			  {p, [], "Customized crash display code crashed !!!"}],
		    accumulate_chunk(ehtml_expand(T2)),
		    break;
		{ok, Out} ->
		    accumulate_chunk(Out),
		    break
	    end;
	Other ->
	    yaws:elog("Bad return value from errmod_crash ~n~p~n",[Other]),
	    T2 = [{h2, [], "Internal error"}, {hr},
		  {p, [], "Customized crash display code returned bad val"}],
	    accumulate_chunk(ehtml_expand(T2)),
	    break
	
    end.


deliver_accumulated(Sock, GC, SC) ->
    Chunked = yaws:outh_get_chunked(),
    Cont = case erase(acc_content) of
	       undefined ->
		   [];
	       Cont2 ->
		   Cont2
	   end,

    case Cont of
	discard ->
	    yaws:outh_set_transfer_encoding_off(),
	    {StatusLine, Headers} = yaws:outh_serialize(),
	    ?Debug("discard accumulated~n", []),
	    All = [StatusLine, Headers, crnl()];
	_ ->
	    {StatusLine, Headers} = yaws:outh_serialize(),
	    ?Debug("deliver accumulated size=~p~n", [binary_size(Cont)]),
	    CRNL = case Chunked of
		       true ->
			   [];
		       false ->
			   crnl()
		   end,
	    All = [StatusLine, Headers, CRNL, Cont]
    end,
    yaws:gen_tcp_send(Sock, All, SC, GC),
    if
	GC#gconf.trace == false ->
	    ok;
	GC#gconf.trace == {true, http} ->
	    yaws_log:trace_traffic(from_server, [StatusLine, Headers]);
	GC#gconf.trace == {true, traffic} ->
	    yaws_log:trace_traffic(from_server, All)
    end,
    Cont.


get_more_post_data(PPS, N, SC, GC, ARG) ->
    Len = list_to_integer((ARG#arg.headers)#headers.content_length),
    if N + PPS < Len ->
	    case yaws:cli_recv(ARG#arg.clisock, PPS, GC, 
			       is_ssl(SC#sconf.ssl)) of
		{ok, Bin} ->
		    {partial, Bin};
		Else ->
		    {error, Else}
	    end;
       true ->
	    case yaws:cli_recv(ARG#arg.clisock, Len - N, GC, 
			       is_ssl(SC#sconf.ssl)) of
		{ok, Bin} ->
		    Bin;
		Else ->
		    {error, Else}
	    end
    end.


do_tcp_close(Sock, SC) ->
    case SC#sconf.ssl of
	undefined ->
	    gen_tcp:close(Sock);
	_SSL ->
	    ssl:close(Sock)
    end.


ut_open(UT) ->
    ?Debug("ut_open() UT.fullpath = ~p~n", [UT#urltype.fullpath]),
    case UT#urltype.data of
	undefined ->
	    
	    ?Debug("ut_open reading\n",[]),
	    {ok, Bin} = file:read_file(UT#urltype.fullpath),
	    ?Debug("ut_open read ~p\n",[size(Bin)]),
	    {bin, Bin};
	B when binary(B) ->
	    {bin, B}
    end.


ut_read({bin, B}) ->
    B;
ut_read(Fd) ->
    file:read(Fd, 4000).


ut_close({bin, _}) ->
    ok;
ut_close(Fd) ->
    file:close(Fd).


parse_range(L, Tot) ->
    case catch parse_range_throw(L, Tot) of
	{'EXIT', _} ->
						% error
	    error;
	R -> R
    end.

parse_range_throw(L, Tot) ->
    case lists:splitwith(fun(C)->C /= $- end, L) of
	{FromS, [$-|ToS]} -> 
	    case FromS of
		[] -> case list_to_integer(ToS) of
			  I when Tot >= I, I>0 ->
			      {fromto, Tot-I, Tot-1, Tot}
		      end;
		_ -> case list_to_integer(FromS) of
			 From when From>=0, From < Tot ->
			     case ToS of
				 [] -> {fromto, From, Tot-1, Tot};
				 _ -> case list_to_integer(ToS) of
					  To when To<Tot ->
					      {fromto, From, To, Tot};
					  _ ->
					      {fromto, From, Tot-1, Tot}
				      end
			     end
		     end
	    end
    end.

			    
%% This is not exactly what the RFC describes, but we do not want to
%% deal with multipart/byteranges.
unite_ranges(all, _) ->
    all;
unite_ranges(error, R) ->
    R;
unite_ranges(_, all) ->
    all;
unite_ranges(R, error) ->
    R;
unite_ranges({fromto, F0, T0, Tot},{fromto,F1,T1, Tot}) ->
    {fromto, 
     if F0 >= F1 -> F1;
	true -> F0
     end,
     if T0 >= T1 -> T0;
	true -> T1
     end,
     Tot
    }.
	 
	     	
%% ret:  all | error | {fromto, From, To, Tot}
requested_range(RangeHeader, TotalSize) ->
    case yaws:split_sep(RangeHeader, $,) of
	["bytes="++H|T] ->
	    lists:foldl(fun(L, R)->
				unite_ranges(parse_range(L, TotalSize), R)
			end, parse_range(H, TotalSize), T);
	_ -> all
    end.


deliver_file(CliSock, GC, SC, Req, UT, Range) ->
    if
	binary(UT#urltype.data) ->
	    %% cached
	    deliver_small_file(CliSock, GC, SC, Req, UT, Range);
	true ->
	    case (UT#urltype.finfo)#file_info.size of
		N when N < GC#gconf.large_file_chunk_size ->
		    deliver_small_file(CliSock, GC, SC, Req, UT, Range);
		_ ->
		    deliver_large_file(CliSock, GC, SC, Req, UT, Range)
	    end
    end.

deliver_small_file(CliSock, GC, SC, _Req, UT, Range) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}, {record, UT, urltype}]),
    Fd = ut_open(UT),
    case Range of
	all ->
	    Bin = ut_read(Fd);
	{fromto, From, To, _Tot} ->
	    Length = To - From + 1,
	    <<_:From/binary, Bin:Length/binary, _/binary>> = ut_read(Fd)
    end,
    accumulate_content(Bin),
    ut_close(Fd),
    deliver_accumulated(CliSock, GC, SC),
    done_or_continue().
    
deliver_large_file(CliSock, GC, SC, _Req, UT, Range) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}, {record, UT, urltype}]),
    case deliver_accumulated(CliSock, GC, SC) of
	discard -> ok;
	_ ->
	    {ok,Fd} = file:open(UT#urltype.fullpath, [raw, binary, read]),
	    send_file(CliSock, Fd, SC, GC, Range)
    end,
    done_or_continue().


send_file(CliSock, Fd, SC, GC, all) ->
    send_file(CliSock, Fd, SC, GC);
send_file(CliSock, Fd, SC, GC, {fromto, From, To, _Tot}) ->
    file:position(Fd, {bof, From}),
    send_file_range(CliSock, Fd, SC, GC, To - From + 1).


send_file(CliSock, Fd, SC, GC) ->
    case file:read(Fd, GC#gconf.large_file_chunk_size) of
	{ok, Bin} ->
	    send_file_chunk(Bin, CliSock, SC, GC),
	    send_file(CliSock, Fd, SC, GC);
	eof ->
	    file:close(Fd),
	    case yaws:outh_get_chunked() of
		true ->
		    yaws:gen_tcp_send(CliSock, [crnl(), "0", crnl2()], SC, GC),
		    done_or_continue();
		false ->
		    done_or_continue()
	    end
    end.

send_file_range(CliSock, Fd, SC, GC, Len) when Len > 0 ->
    {ok, Bin} = file:read(Fd, 
			  case GC#gconf.large_file_chunk_size of
			      S when S < Len -> S;
			      _ -> Len
			  end
			 ),
    send_file_chunk(Bin, CliSock, SC, GC),
    send_file_range(CliSock, Fd, SC, GC, Len - size(Bin));
send_file_range(CliSock, Fd, SC, GC, 0) ->
    file:close(Fd),
    case yaws:outh_get_chunked() of
	true ->
	    yaws:gen_tcp_send(CliSock, [crnl(), "0", crnl2()], SC, GC),
	    done_or_continue();
	false ->
	    done_or_continue()
    end.
    

send_file_chunk(Bin, CliSock, SC, GC) ->
     case yaws:outh_get_chunked() of
	 true ->
	     CRNL = crnl(),
	     Data2 = [CRNL, yaws:integer_to_hex(size(Bin)) , crnl(), Bin],
	     yaws:gen_tcp_send(CliSock, Data2, SC, GC);
	 false ->
	     yaws:gen_tcp_send(CliSock, Bin, SC, GC)
     end.



crnl() ->
    "\r\n".
crnl2() ->
    "\r\n\r\n".

now_secs() ->
    {M,S,_}=now(),
    (M*1000000)+S.


%% a file cache,
url_type(GC, SC, Path) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    E = SC#sconf.ets,
    update_total(E, Path),
    case ets:lookup(E, {url, Path}) of
	[] ->
	    UT = do_url_type(SC, Path),
	    ?TC([{record, UT, urltype}]),
	    ?Debug("UT=~p\n", [UT]),
	    CF = cache_file(GC, SC, Path, UT),
	    ?Debug("CF=~p\n", [yaws_debug:nobin(CF)]),
	    CF;
	[{_, When, UT}] ->
	    N = now_secs(),
	    FI = UT#urltype.finfo,
	    Refresh = GC#gconf.cache_refresh_secs,
	    if 
		((N-When) >= Refresh) ->
		    ?Debug("Timed out entry for ~s ~p~n", [Path, {When, N}]),
		    %% more than 30 secs old entry
		    ets:delete(E, {url, Path}),
		    ets:delete(E, {urlc, Path}),
		    ets:update_counter(E, num_files, -1),
		    ets:update_counter(E, num_bytes, -FI#file_info.size),
		    url_type(GC, SC, Path);
		true ->
		    ?Debug("Serve page from cache ~p", [{When , N, N-When}]),
		    ets:update_counter(E, {urlc, Path}, 1),
		    UT
	    end
    end.


update_total(E, Path) ->
    case (catch ets:update_counter(E, {urlc_total, Path}, 1)) of
	{'EXIT', _} ->
	    ets:insert(E, {{urlc_total, Path}, 1});
	_ ->
	    ok
    end.


cache_file(GC, SC, Path, UT) when 
  UT#urltype.type == regular ;
  UT#urltype.type == yaws  ->

    E = SC#sconf.ets,
    [{num_files, N}] = ets:lookup(E, num_files),
    [{num_bytes, B}] = ets:lookup(E, num_bytes),
    FI = UT#urltype.finfo,
    ?Debug("FI=~p\n", [FI]),
    if
	N + 1 > GC#gconf.max_num_cached_files ->
	    error_logger:info_msg("Max NUM cached files reached for server "
			      "~p", [SC#sconf.servername]),
	    cleanup_cache(E, num),
	    cache_file(GC, SC, Path, UT);
	FI#file_info.size < GC#gconf.max_size_cached_file,
	B + FI#file_info.size > GC#gconf.max_num_cached_bytes ->
	    error_logger:info_msg("Max size cached bytes reached for server "
				  "~p", [SC#sconf.servername]),
	    cleanup_cache(E, size),
	    cache_file(GC, SC, Path, UT);
	true ->
	    ?Debug("Check file size\n",[]),
	    if
		FI#file_info.size > GC#gconf.max_size_cached_file ->
		    ?Debug("Too large\n",[]),
		    UT;
		true ->
		    ?Debug("File fits\n",[]),
		    {ok, Bin} = prim_file:read_file(
				  UT#urltype.fullpath),
		    UT2 = UT#urltype{data = Bin},
		    ets:insert(E, {{url, Path}, now_secs(), UT2}),
		    ets:insert(E, {{urlc, Path}, 1}),
		    ets:update_counter(E, num_files, 1),
		    ets:update_counter(E, num_bytes, 
				       FI#file_info.size),
		    UT2
	    end
    end;
cache_file(_GC, _SC, _Path, UT) ->
    UT.



%% FIXME, should not wipe entire ets table this way
cleanup_cache(E, size) ->
    %% remove the largest files with the least hit count  (urlc)
    ?Debug("Clearing yaws internal content "
	   "cache, size overflow",[]),
    clear_ets(E);

cleanup_cache(E, num) ->
    ?Debug("Clearing yaws internal content "
	   "cache, num overflow",[]),
    clear_ets(E).



clear_ets(E) ->
    ets:match_delete(E, {'_', spec, '_', '_', '_'}),
    ets:match_delete(E, {{url, '_'}, '_', '_'}),
    ets:match_delete(E, {{urlc, '_'}, '_', '_'}),
    ets:insert(E, {num_files, 0}),
    ets:insert(E, {num_bytes, 0}).
    

%% return #urltype{}
do_url_type(SC, Path) ->
    case split_path(SC, Path, [], []) of
	slash ->
	    maybe_return_dir(SC#sconf.docroot, lists:flatten(Path));
	redir_dir ->
	    #urltype{type = redir_dir,
		     dir = [Path, $/]};
	OK ->
	    OK
    end.


maybe_return_dir(DR, FlatPath) ->
    ?Debug("maybe_return_dir(~p, ~p)", [DR, FlatPath]),
    case prim_file:read_file_info([DR, FlatPath, "/index.yaws"]) of
	{ok, FI} ->
	    #urltype{type = yaws,
		     finfo = FI,
		     path = {noflat, [DR, FlatPath]},
		     mime = "text/html",
		     dir = FlatPath,
		     fullpath = ?f([DR, FlatPath, "/index.yaws"])};
	_ ->
	    case prim_file:read_file_info([DR, FlatPath, "/index.html"]) of
		{ok, FI} ->
		    #urltype{type = regular,
			     finfo = FI,
			     path = {noflat, [DR, FlatPath]},
			     mime = "text/html",
			     dir = FlatPath,
			     fullpath = ?f([DR, FlatPath, "/index.html"])};
		_ ->
		    case file:list_dir([DR, FlatPath]) of
			{ok, List} ->
			    #urltype{type = directory,
				     path = {noflat, [DR, FlatPath]},
				     dir = DR ++ [$/|FlatPath],
				     data=List};
			_Err ->
			    #urltype{type=error}
		    end
	    end
    end.


split_path(_SC, [$/], _Comps, []) ->
    %% its a URL that ends with /
    slash;
split_path(SC, [], Comps, Part) ->
    ret_reg_split(SC, Comps, Part);
split_path(SC, [$/|Tail], Comps, Part)  when Part /= [] ->
    ?Debug("Tail=~s Part=~s", [Tail,Part]),
    Component = lists:reverse(Part),
    CName = tl(Component),
    case lists:member(CName, SC#sconf.appmods) of
	true  ->
	    %% we've found an appmod
	    PrePath = conc_path(Comps),
	    ret_app_mod(SC, [$/|Tail], list_to_atom(CName), PrePath);
	_ ->
	    case ret_script(SC, Comps, Part) of
		false -> 
		    split_path(SC, [$/|Tail],
			       [lists:reverse(Part) | Comps], []);
		UT -> UT#urltype{pathinfo=[$/|Tail]}
	    end
    end;
split_path(SC, [$~|Tail], Comps, Part) ->  %% user dir
    ret_user_dir(SC, Comps, Part, Tail);
split_path(SC, [H|T], Comps, Part) ->
    split_path(SC, T, Comps, [H|Part]).



conc_path([]) ->
    [];
conc_path([H|T]) ->
    H ++ conc_path(T).



ret_app_mod(_SC, Path, Mod, PrePath) ->
    #urltype{type = appmod,
	     data = {Mod, Path},
	     path = PrePath}.



%% http://a.b.c/~user URLs
ret_user_dir(SC, [], "/", Upath) when SC#sconf.tilde_expand == true ->
    ?Debug("UserPart = ~p~n", [Upath]),
    case parse_user_path(SC#sconf.docroot, Upath, []) of
	{ok, User, Path} ->
    
	    ?Debug("User=~p Path = ~p~n", [User, Path]),
	    
	    %% FIXME doesn't work if passwd contains :: 
	    %% also this is unix only
	    %% and it ain't the fastest code around.
	    case catch yaws:user_to_home(User) of
		{'EXIT', _} ->
		    #urltype{type=error};
		Home ->
		    DR2 = Home ++ "/public_html/",
		    do_url_type(SC#sconf{docroot=DR2}, Path) %% recurse
	    end;
	redir_dir ->
	    redir_dir
    end;
ret_user_dir(_SC, _, _, _Upath)  ->
    #urltype{type=error}.



parse_user_path(_DR, [], _User) ->
    redir_dir;
parse_user_path(_DR, [$/], User) ->
    {ok, lists:reverse(User), [$/]};
parse_user_path(_DR, [$/|Tail], User) ->
    {ok, lists:reverse(User), [$/|Tail]};
parse_user_path(DR, [H|T], User) ->
    parse_user_path(DR, T, [H|User]).



ret_reg_split(SC, Comps, RevFile) ->
    ?Debug("ret_reg_split(~p)", [[SC#sconf.docroot, Comps, RevFile]]),
    Dir = lists:reverse(Comps),
    FlatDir = {noflat, Dir},
    DR = SC#sconf.docroot,
    File = lists:reverse(RevFile),
    L = [DR, Dir, File],
    ?Debug("ret_reg_split: L =~p~n",[L]),
    case prim_file:read_file_info(L) of
	{ok, FI} when FI#file_info.type == regular ->
	    case suffix_type(SC, RevFile) of
		{forbidden, _} -> 
		    #urltype{type=forbidden};
						% Forbidden script
						% type.  
						%
						% We could also treat
						% it as a plain file.
		{X, Mime} -> 
		    #urltype{type=X, 
			     finfo=FI,
			     path = {noflat, [DR, Dir]},
			     dir = FlatDir,
			     fullpath = lists:flatten(L),
			     mime=Mime}
	    end;
	{ok, FI} when FI#file_info.type == directory, hd(RevFile) == $/ ->
	    maybe_return_dir(DR, lists:flatten(Dir) ++ File);
	{ok, FI} when FI#file_info.type == directory, hd(RevFile) /= $/ ->
	    redir_dir;
	Err ->
	    #urltype{type=error, data=Err}
    end.


ret_script(SC, Comps, RevFile) ->
    ?Debug("ret_script(~p)", [[SC#sconf.docroot, Comps, RevFile]]),
    case suffix_type(SC, RevFile) of
	{regular, _} -> false;
	{forbidden, _} -> false;
	{X, Mime} -> 
	    Dir = lists:reverse(Comps),
	    FlatDir = {noflat, Dir},
	    DR = SC#sconf.docroot,
	    File = lists:reverse(RevFile),
	    L = [DR, Dir, File],
	    ?Debug("ret_script: L =~p~n",[L]),
	    case prim_file:read_file_info(L) of
		{ok, FI} when FI#file_info.type == regular ->
		    #urltype{type=X, 
			     finfo=FI,
			     path = {noflat, [DR, Dir]},
			     dir = FlatDir,
			     fullpath = lists:flatten(L),
			     mime=Mime};
		_ -> false
	    end
    end.


suffix_type(SC, L) ->
    R=suffix_type(L),
    case R of
	{regular, _} ->
	    R;
	{X, _Mime} -> 
	    case lists:member(X, SC#sconf.allowed_scripts) of
		true -> R;
		false -> {forbidden, []}
	    end
    end.

suffix_type(L) ->
    L2 = drop_till_dot(L),
    mime_types:revt(L2).

drop_till_dot([$.|_]) ->
    [];
drop_till_dot([H|T]) ->
    [H|drop_till_dot(T)];
drop_till_dot([]) ->
    [].


flush(SC, Sock, Sz) ->
    case SC#sconf.ssl of
	undefined ->
	    tcp_flush(Sock, Sz);
	_ ->
	    ssl_flush(Sock, Sz)
    end.

	    
strip_list_to_integer(L) ->
    case catch list_to_integer(L) of
	{'EXIT', _} ->
	    list_to_integer(string:strip(L, both));
	Int ->
	    Int
    end.


tcp_flush(_Sock, undefined) ->
    ok;
tcp_flush(_Sock, 0) ->
    ok;
tcp_flush(Sock, Sz) when list(Sz) ->
    tcp_flush(Sock, strip_list_to_integer(Sz));
tcp_flush(Sock, Sz) ->
    gen_tcp:recv(Sock, Sz, 1000).


ssl_flush(_Sock, undefined) ->
    ok;
ssl_flush(_Sock, 0) ->
    ok;
ssl_flush(Sock, Sz) ->
    yaws:split_recv(ssl:recv(Sock, Sz, 1000), Sz).

mtime(F) ->
    F#file_info.mtime.

runmod(Mod) ->
    proc_lib:spawn(?MODULE, load_and_run, [Mod]).

load_and_run(Mod) ->
    case code:ensure_loaded(Mod) of
	{module,Mod} ->
	    Mod:start();
	Error ->
	    error_logger:error_msg("Loading '~w' failed, reason ~p~n",
				   [Mod,Error])
    end.


safe_ehtml_expand(X, SC) ->
    put(sc,SC),
    case (catch ehtml_expand(X)) of
	{'EXIT', R} ->
	    {error, io_lib:format("<pre> ~n~p~n </pre>~n", [R])};
	Val ->
	    {ok, Val}
    end.
