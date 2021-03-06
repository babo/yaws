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

-include("../include/yaws.hrl").
-include("../include/yaws_api.hrl").
-include("yaws_debug.hrl").

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/inet.hrl").

%% External exports
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-import(filename, [join/1]).
-import(lists, [member/2, foreach/2, map/2, 
		flatten/1, flatmap/2, reverse/1]).

-import(yaws_api, [ehtml_expand/1]).

-record(gs, {gconf,         
	     group,         %% list of #sconf{} s
	     ssl,           %% ssl | nossl
	     l,             %% listen socket
	     mnum = 0,      
	     sessions = 0,  %% number of HTTP sessions
	     reqs = 0}).    %% number of HTTP requests


-record(state, {gc,         %% Global conf #gc{} record
		pairs,      %% [{GservPid, ScList}] 
		mnum = 0,   %% dyn compiled erl module  number
		embedded    %% true if in embedded mode, false otherwise
	       }).


-define(elog(X,Y), error_logger:info_msg("*elog ~p:~p: " X,
					 [?MODULE, ?LINE | Y])).


start_link(A) ->
    gen_server:start_link({local, yaws_server}, yaws_server, A, []).

status() ->
    gen_server:call(?MODULE, status).
gs_status() ->
    [_|Pids] = gen_server:call(?MODULE, pids),
    lists:map(
      fun(P) ->
	      P ! {self(), status},
	      receive {P, Stat} -> Stat end
      end, Pids).
getconf() ->		    
     gen_server:call(?MODULE,getconf).

stats() -> 
    {S, Time} = status(),
    Diff = calendar:time_difference(Time, calendar:local_time()),
    {Diff, []}.

l2a(L) when list(L) -> list_to_atom(L);
l2a(A) when atom(A) -> A.



%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%----------------------------------------------------------------------

init(Env) -> %% #env{Trace, TraceOut, Conf, RunMod, Embedded, Id}) ->
    process_flag(trap_exit, true),
    put(start_time, calendar:local_time()),  %% for uptime
    case Env#env.embedded of 
	false ->
	    Config = (catch yaws_config:load(Env)),
	    case Config of
		{ok, Gconf, Sconfs} ->
		    erase(logdir),
		    ?Debug("GC = ~s~n", [?format_record(Gconf, gconf)]),
		    lists:foreach(
		      fun(Group) ->
			      lists:foreach(
				fun(_SC) ->
					?Debug("SC = ~s~n",
					       [?format_record(_SC, sconf)])
				end, Group)
		      end, Sconfs),
		    yaws_log:setdir(Gconf, Sconfs),
		    case Gconf#gconf.trace of
			{true, What} ->
			    yaws_log:open_trace(What),
			    yaws_api:set_tty_trace(?gc_has_tty_trace(Gconf));
			_ ->
			    ok
		    end,
		    init2(Gconf, Sconfs, Env#env.runmod, Env#env.embedded, true);
		{error, E} ->
		    case erase(logdir) of
			undefined ->
			    error_logger:error_msg("Yaws: Bad conf: ~p~n",[E]),
			    init:stop(),
			    {stop, E};
			Dir ->
			    GC = yaws_config:make_default_gconf(true, Env#env.id),
			    yaws_log:setdir(GC#gconf{logdir = Dir}, []),
			    error_logger:error_msg("Yaws: bad conf: ~s "
						   "terminating~n",[E]),
			    init:stop(),
			    {stop, E}
		    end;
		EXIT ->
		    error_logger:format("FATAL ~p~n", [EXIT]),
		    erlang:fault(badconf)
	    end;
	true ->
	    {ok, #state{gc = undefined,
			embedded = Env#env.embedded,
			pairs = [],
			mnum = 0}}
    end.


init2(GC, Sconfs, RunMod, Embedded, FirstTime) ->
    put(gc, GC),
    foreach(
      fun(D) ->
	      yaws_debug:format("Add path ~p~n", [D]),
	      code:add_pathz(D)
      end, GC#gconf.ebin_dir),
    yaws_debug:format("Running with id=~p~n"
		      "Running with debug checks turned on (slower server) ~n"
		      "Logging to directory ~p~n",
		      [GC#gconf.id, GC#gconf.logdir]),

    setup_dirs(GC),

    case Embedded of
	false ->
	    yaws_ctl:start(GC, FirstTime);
        true -> 
	    ok
    end,

    runmod(RunMod, GC),
   
    L2 = lists:zf(
	   fun(Group) -> start_group(GC, Group) end,
	   Sconfs),
    {ok, #state{gc = GC,
		pairs = L2,
		mnum = 0,
		embedded = Embedded}}.



start_group(GC, Group) ->
    FailOnBind = ?gc_fail_on_bind_err(GC),
    case proc_lib:start_link(?MODULE, gserv, [self(), GC, Group]) of
	{error, F, A} when FailOnBind == false ->
	    error_logger:error_msg(F, A),
	    false;
	{error, F, A} ->
	    error_logger:error_msg(F, A),
	    erlang:fault(badbind);
	{error, Reason} when FailOnBind == false ->
	    error_logger:error_msg("FATAL: ~p~n", [Reason]),
	    false;
	{error, Reason} ->
	    error_logger:error_msg("FATAL: ~p~n", [Reason]),
	    erlang:fault(badbind);
	{Pid, SCs} ->
	    {true, {Pid, SCs}};
	none ->
	    false
    end.




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

handle_call(id, _From, State) ->
    {reply, (State#state.gc)#gconf.id, State};

handle_call(pids, _From, State) ->  %% for gprof
    L = map(fun(X) ->element(1, X) end, State#state.pairs),
    {reply, [self() | L], State};

handle_call(mnum, _From, State) ->
    Mnum = State#state.mnum +1,
    {reply, Mnum, State#state{mnum = Mnum}};



%% This is a brutal restart of everything
handle_call({setconf, GC, Groups}, _From, State) ->
    %% First off, terminate all currently running processes
    Curr = map(fun(X) ->element(1, X) end, State#state.pairs),
    foreach(fun(Pid) ->
		    gserv_stop(Pid)
	    end, Curr),
    case init2(GC, Groups, undef, State#state.embedded, false) of
	{ok, State2} ->
	    {reply, ok, State2};
	Err ->
	    {reply, Err, #state{gc=GC, pairs=[], mnum=0}}
    end;

handle_call(getconf, _From, State) ->
    Groups = map(fun({_Pid, SCs}) -> SCs end, State#state.pairs),
    {reply, {ok, State#state.gc, Groups}, State};


handle_call({update_sconf, NewSc}, From, State) ->
    case yaws_config:search_sconf(NewSc, State#state.pairs) of
	{Pid, OldSc, _Group} ->
	    case yaws_config:eq_sconfs(OldSc,NewSc) of
		true ->
		    error_logger:info_msg("Keeping conf for ~s intact\n",
					  [yaws:sconf_to_srvstr(OldSc)]),
		    {reply, ok, State};
		false ->
		    Pid ! {update_sconf, NewSc, OldSc, From, self()},
		    receive
			{updated_sconf, NewSc2} ->			
			    P2 = yaws_config:update_sconf(NewSc2, State#state.pairs),
			    {noreply, State#state{pairs = P2}}
		    after 1000 ->
			    {reply, {error, "Failed to update new conf"}, State}
		    end
	    end;
	false ->
	    {reply, {error, "No matching group"}, State}
    end;


handle_call({delete_sconf, SC}, From, State) ->
    case yaws_config:search_sconf(SC, State#state.pairs) of
	{Pid, OldSc, Group} when length(Group) == 1 ->
	    error_logger:info_msg("Terminate whole ~s virt server group \n", 
				  [yaws:sconf_to_srvstr(OldSc)]),
	    gserv_stop(Pid),
	    NewPairs = lists:keydelete(Pid, 1, State#state.pairs),
	    {reply, ok, State#state{pairs = NewPairs}};
	{Pid, OldSc, _Group} ->
	    Pid ! {delete_sconf, OldSc, From},
	    P2 = yaws_config:delete_sconf(OldSc, State#state.pairs),
	    {noreply, State#state{pairs = P2}};
	false ->
	    {reply, {error, "No matching group"}, State}
    end;

handle_call({add_sconf, SC}, From, State) ->
    case yaws_config:search_group(SC, State#state.pairs) of
	[{Pid, Group}] ->
	    Pid ! {add_sconf, From, SC},
	    P2 = lists:keyreplace(Pid, 1, State#state.pairs,
				  {Pid, [SC|Group]}),
	    {noreply, State#state{pairs = P2}};
	[] ->
	    %% Need to create a new group
	    error_logger:info_msg("Creating new virt server ~s\n",
				 [yaws:sconf_to_srvstr(SC)]),
	    GC = State#state.gc,
	    case start_group(GC, [SC]) of
		false ->
		    {reply, ok, State};
		{true, Pair} ->
		    %Pid = element(1, Pair),
		    %Pid ! {newuid, GC#gconf.uid},
		    P2 = [Pair | State#state.pairs],
		    {reply, ok, State#state{pairs = P2}}
	    end
    end;

handle_call({update_gconf, GC}, _From, State) ->
    lists:foreach(fun({Pid, _Group}) ->
			  Pid ! {update_gconf, GC}
		  end, State#state.pairs),
    %% no need to tell yaws_log, new vals must be compatible
    put(gc, GC),
    {reply, ok, State#state{gc = GC}}.





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
    ?Debug("got EXIT Pid = ~p~n"
           " pairs = ~p~n", [Pid, State#state.pairs]),
    case lists:keysearch(Pid, 1, State#state.pairs) of
	{value, _} ->
	    %% one of our gservs died 
	    error_logger:format("yaws: FATAL gserv died ~p~n", [Reason]),
	    erlang:fault(restartme);
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

do_listen(GC, SC) ->
    case SC#sconf.ssl of
	undefined when ?gc_use_fdsrv(GC) ->
	    %% Use fdsrv kit from jungerl, requires fdsrv
	    %% to be properly installed
	    fdsrv:start(),
	    case fdsrv:bind_socket(tcp, SC#sconf.port) of
		{ok, Fd} ->
		    {nossl, gen_tcp_listen(SC#sconf.port,[{fd, Fd}|opts(SC)])};
		Err ->
		    {nossl, Err}
	    end;
	undefined ->
	    {nossl, gen_tcp_listen(SC#sconf.port, opts(SC))};
	SSL ->
	    {ssl, ssl:listen(SC#sconf.port, ssl_opts(SC, SSL))}
    end.

gen_tcp_listen(Port, Opts) ->
    ?Debug("Listen ~p:~p~n", [Port, Opts]),
    gen_tcp:listen(Port, Opts).


gserv(_Top, _, []) ->
    proc_lib:init_ack(none);

%% One server per IP we listen to
gserv(Top, GC, Group0) ->
    process_flag(trap_exit, true),
    ?TC([{record, GC, gconf}]),
    put(gc, GC),
    put(top, Top),
    Group = map(fun(SC) -> setup_ets(SC)
		end, Group0),
    SC = hd(Group),
    case do_listen(GC, SC) of
	{SSLBOOL, {ok, Listen}} ->
	    lists:foreach(fun(XSC) -> call_start_mod(XSC) end, Group),
	    error_logger:info_msg(
	      "Yaws: Listening to ~s:~w for servers~s~n",
	      [inet_parse:ntoa(SC#sconf.listen),
	       SC#sconf.port,
	       catch map(
		       fun(S) ->  
			       io_lib:format("~n - ~s under ~s",
					     [yaws:sconf_to_srvstr(S),
					      S#sconf.docroot])
		       end, Group)
	      ]),
	    proc_lib:init_ack({self(), Group}),
	    GS = #gs{gconf = GC,
		     group = Group,
		     ssl = SSLBOOL,
		     l = Listen},
	    Last = initial_acceptor(GS),
	    gserv_loop(GS, [], 0, Last);
	{_,Err} ->
	    error_logger:format("Yaws: Failed to listen ~s:~w  : ~p~n",
				[inet_parse:ntoa(SC#sconf.listen),
				 SC#sconf.port, Err]),
	    proc_lib:init_ack({error, "Can't listen to socket: ~p ",[Err]}),
	    exit(normal)
    end.
			

setup_dirs(GC) ->
    TD0 = filename:join([GC#gconf.tmpdir,"yaws"]),
    file:make_dir(TD0),
    TD1 = filename:join([TD0, GC#gconf.id]),
    file:make_dir(TD1),
    case file:list_dir(TD1) of
	{ok, LL} ->
	    foreach(
	      fun(F) ->
		      file:delete(filename:join([TD1, F]))
	      end, LL -- ["ctl"]);
	{error, RSN} ->
	    error_logger:format("Failed to list ~p probably "
				"due to permission errs: ~p",
				[TD1, RSN]),
	    erlang:fault(RSN)
    end.


setup_ets(SC) ->
    E = ets:new(yaws_code, [public, set]),
    ets:insert(E, {num_files, 0}),
    ets:insert(E, {num_bytes, 0}),
    SC#sconf{ets = E}.

clear_ets_complete(SC) ->
    case SC#sconf.ets of
	undefined ->
 	    setup_ets(SC);
 	E ->
 	    ets:match_delete(E,'_'),
 	    ets:insert(E, {num_files, 0}),
 	    ets:insert(E, {num_bytes, 0}),
 	    SC
     end.


gserv_loop(GS, Ready, Rnum, Last) ->
    receive
	{From , status} ->
	    From ! {self(), GS},
	    gserv_loop(GS, Ready, Rnum, Last);
	{_From, next} when Ready == [] ->
	    New = acceptor(GS),
	    gserv_loop(GS, Ready, Rnum, New);
	{_From, next} ->
	    [{_Then, R}|RS] = Ready,
	    R ! {self(), accept},
	    gserv_loop(GS, RS, Rnum-1, R);
	{From, done_client, Int} ->
	    GS2 = if
		      Int == 0 -> GS;
		      Int > 0 -> GS#gs{sessions = GS#gs.sessions + 1,
				       reqs = GS#gs.reqs + Int}
		  end,
	    if
		Rnum == 8 ->
		    From ! {self(), stop},
		    gserv_loop(GS2, Ready, Rnum, Last);
		Rnum < 8 ->
		    %% cache this process for 10 secs
		    gserv_loop(GS2, [{now(), From} | Ready], Rnum+1, Last)
	    end;
	{'EXIT', Pid, Reason} ->
	    case get(top) of
		Pid when Reason /= shutdown -> 
		    error_logger:format("Top proc died, terminate gserv",[]),
		    {links, Ls} = process_info(self(), links),
		    foreach(fun(X) -> unlink(X), exit(X, shutdown) end, Ls),
		    exit(noserver);
		Pid ->
		    {links, Ls} = process_info(self(), links),
		    foreach(fun(X) -> unlink(X), exit(X, shutdown) end, Ls),
		    exit(normal);
		_ ->
		    gserv_loop(GS, Ready, Rnum, Last)
	    end;
	{From, stop} ->   
	    unlink(From),
	    {links, Ls} = process_info(self(), links),
	    foreach(fun(X) -> unlink(X), exit(X, shutdown) end, Ls),
	    From ! {self(), ok},
	    exit(normal);


	%% This code will shutdown all ready procs as well as the
	%% acceptor() 
	{update_sconf, NewSc, OldSc, From, Updater} ->
	    case lists:member(OldSc, GS#gs.group) of
		false ->
		    error_logger:error_msg("gserv: No found SC ~p/~p~n",
					   [OldSc, GS#gs.group]),
		    erlang:fault(nosc);
		true ->
		    stop_ready(Ready, Last),
		    NewSc2 = clear_ets_complete(NewSc),
		    GS2 = GS#gs{group = [ NewSc2 | 
					 lists:delete(OldSc,GS#gs.group)]},
		    Ready2 = [],
		    Updater ! {updated_sconf, NewSc2},
		    gen_server:reply(From, ok),
		    error_logger:info_msg("Updating sconf for server ~s~n",
					  [yaws:sconf_to_srvstr(NewSc2)]),
		    New = acceptor(GS2),
		    gserv_loop(GS2, Ready2, 0, New)
	    end;

	{delete_sconf, OldSc, From} ->
	    
	    case lists:member(OldSc, GS#gs.group) of
		false ->
		    error_logger:error_msg("gserv: No found SC ~n",[]),
		    erlang:fault(nosc);
		true ->
		    stop_ready(Ready, Last),
		    GS2 = GS#gs{group =  lists:delete(OldSc,GS#gs.group)},
		    Ready2 = [],
		    ets:delete(OldSc#sconf.ets),
		    gen_server:reply(From, ok),
		    error_logger:info_msg("Deleting sconf for server ~s~n",
					  [yaws:sconf_to_srvstr(OldSc)]),
		    New = acceptor(GS2),
		    gserv_loop(GS2, Ready2, 0, New)
	    end;

	{add_sconf, From, SC} ->
	    stop_ready(Ready, Last),
	    GS2 = GS#gs{group =  [setup_ets(SC) |GS#gs.group]},
	    Ready2 = [],
	    gen_server:reply(From, ok),
	    error_logger:info_msg("Adding sconf for server ~s~n",
				  [yaws:sconf_to_srvstr(SC)]),
	    New = acceptor(GS2),
	    gserv_loop(GS2, Ready2, 0, New);
 
	{update_gconf, GC} ->
	    stop_ready(Ready, Last),
	    GS2 = GS#gs{gconf = GC},
	    Ready2 = [],
	    put(gc, GC),
	    error_logger:info_msg("Updating gconf \n",[]),
	    New = acceptor(GS2),
	    gserv_loop(GS2, Ready2, 0, New)
    after (10 * 1000) ->
	    %% collect old procs, to save memory
	    {NowMega, NowSecs, _} = now(),
	    R2 = lists:filter(fun({{ThenMega, ThenSecs, _}, Pid}) ->
				      if
					  NowMega > ThenMega;
					  (NowSecs > (ThenSecs + 8)) ->
					      Pid ! {self(), stop},
					      false;
					  true ->
					      true
				      end
			      end, Ready),
	    gserv_loop(GS, R2, Rnum, Last)
    end.


stop_ready(Ready, Last) ->
    unlink(Last),
    exit(Last, shutdown),
    
    lists:foreach(
      fun({_,Pid}) -> 
	      Pid ! {self(), stop}
      end, Ready).






gserv_stop(Gpid) ->
    Gpid ! {self(), stop},
    receive
	{Gpid, ok} ->
	    ok
    end.


call_start_mod(SC) ->
    case SC#sconf.start_mod of
	undefined ->
	    ok;
	Mod0 ->
	    Mod = l2a(Mod0),
	    case code:ensure_loaded(Mod) of
		{module, Mod} ->
		    error_logger:info_msg(
		      "Yaws: calling start_mod: ~p:start/1~n", [Mod]),
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
	    {packet, http},
	    {active, false} | ssl_opts(SSL)],
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
    ssl:accept(GS#gs.l,10000).



initial_acceptor(GS) ->
    if
	GS#gs.ssl == nossl ->
	    acceptor(GS);
	GS#gs.ssl == ssl ->
	    GC = GS#gs.gconf,
	    PoolSize = if
			   ?gc_use_large_ssl_pool(GC) -> 50;
			   true -> 8
		       end,
	    initial_acceptor(GS, PoolSize)
    end.


% an SSL connection might include user interaction.
% So while one person has a dialog box on the screen asking him to review
% the server's certificate, no other person is able to establish a new
% connnection to the server.
% unless we run multiple SSL acceptor processes
% Therefore, the code below!

initial_acceptor(_GS, 0) ->
    ok;
initial_acceptor(GS, 1) ->
    acceptor(GS);
initial_acceptor(GS, N) when N>1 ->
    Self = self(),
    proc_lib:spawn_link(fun() ->
				receive
				after (N-1)*2000 ->
					acceptor0(GS, Self)
				end
			end),
    initial_acceptor(GS, N-1).



acceptor(GS) ->
    proc_lib:spawn_link(yaws_server, acceptor0, [GS, self()]).
acceptor0(GS, Top) ->
    ?TC([{record, GS, gs}]),
    put(gc, GS#gs.gconf),
    X = do_accept(GS),
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
			[GS#gs.ssl, inet_parse:ntoa(IP),Port]),
		    yaws_log:trace_traffic(from_client, Str);
		_ ->
		    ok
	    end,
	    Res = (catch aloop(Client, GS,  0)),
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
	        {'EXIT', shutdown} ->
                    exit(shutdown);
		{'EXIT', {error, einval}} ->
		    %% Typically clients that close their end of the socket
		    %% don't log. Happens all the time.
		    exit(normal);
		{'EXIT', {{error, einval}, _}} ->
		    exit(normal);
		{'EXIT', {error, closed}} ->
		    exit(normal);
		{'EXIT', {{error, closed}, _}} ->
		    exit(normal);
		{'EXIT', {{error, econnreset},_}} ->
		    exit(normal);
		{'EXIT', Reason} ->
		    error_logger:error_msg("Yaws process died: ~p~n", 
					   [Reason]),
		    exit(shutdown)
	    end,
	    
	    %% we cache processes
	    receive
		{Top, stop} ->
		    exit(normal);
		{Top, accept} ->
		    erase_transients(),
		    acceptor0(GS, Top)
	    end;
	{error, timeout} ->
	    Top ! {self(), done_client, 0},
	    receive
		{Top, stop} ->
		    exit(normal);
		{Top, accept} ->
		    acceptor0(GS, Top)
	    end;
	ERR ->
	    yaws_debug:derror("Failed to accept: ~p~n", [ERR]),
	    exit(normal)
    end.



%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

aloop(CliSock, GS, Num) ->
    put(init_db, get()),
    SSL = GS#gs.ssl,
    case  yaws:http_get_headers(CliSock, SSL) of
	{Req0, H0} ->
	    {Req, H} = fix_abs_uri(Req0, H0),
	    SC = pick_sconf(GS#gs.gconf, H, GS#gs.group, SSL),
	    ?Debug("SC: ~s", [?format_record(SC, sconf)]),
	    ?TC([{record, SC, sconf}]),
	    ?Debug("Headers = ~s~n", [?format_record(H, headers)]),
	    ?Debug("Request = ~s~n", [?format_record(Req, http_request)]),
	    IP = case ?sc_has_access_log(SC) of
		     true ->
			 {ok, {Ip, _Port}} = peername(CliSock, SSL),
			 Ip,
			 case ?gc_log_has_resolve_hostname((GS#gs.gconf)) of
			     true ->
				 case inet:gethostbyaddr(Ip) of
				     {ok, HE} ->
					 HE#hostent.h_name;
				     _ ->
					 Ip
				 end;
			     false ->
				 Ip
			 end;
		     _ ->
			 undefined
		 end,
	    put(outh, #outh{}),
	    put(sc, SC),
	    Call = call_method(Req#http_request.method, CliSock, Req, H),
	    handle_method_result(Call, CliSock, IP, GS, Req, H, Num);
	closed -> 
	    {ok, Num}
    end.


erase_transients() ->
    I = get(init_db),
    erase(),
    if I == undefined ->
	    ok;
       list(I) ->
	    lists:foreach(fun({K,V}) -> put(K,V) end, I)
    end.


handle_method_result(Res, CliSock, IP, GS, Req, H, Num) ->
    case Res of
	continue ->
	    maybe_access_log(IP, Req, H),
	    erase_transients(),
	    aloop(CliSock, GS, Num+1);
	done ->
	    maybe_access_log(IP, Req, H),
	    erase_transients(),
	    {ok, Num+1};
	{page, P} ->		    
	    %% keep post_parse
	    erase(query_parse),
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
	    put (sc, (get(sc))#sconf{appmods = []}),
	    Call = call_method(Req#http_request.method, 
			       CliSock, 
			       Req#http_request{path = {abs_path, Page}}, H),
	    handle_method_result(Call, CliSock, IP, GS, Req, H, Num)
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


fix_abs_uri(Req, H) ->
    case Req#http_request.path of
	{absoluteURI, _Scheme, Host0, Port, RawPath} ->
	    Host = case Port of
		       P when integer(P) ->
			   Host0 ++ [$: | integer_to_list(P)];
						% Is this ok?
		       _ ->
			   Host0
		   end,
	    {Req#http_request{path={abs_path, RawPath}},
	     H#headers{host=Host}};
	_ -> {Req, H}
    end.


%% compare servername and ignore any optional
%% :Port postfix
comp_sname([$:|_], _) -> true;
comp_sname(_, [$:|_]) -> true;
comp_sname([H|T], [H|T1]) -> comp_sname(T,T1);
comp_sname([],[])-> true;
comp_sname(_,_)-> false.
   
    


pick_sconf(GC, H, [SC|_Group], ssl) ->
    case comp_sname(H#headers.host, SC#sconf.servername) of
	true -> 
	    SC;
	false when ?gc_pick_first_virthost_on_nomatch(GC)  ->
	    SC;
	false ->
	    yaws_debug:format("Drop req since ~p =/ ~p \n", 
			      [H#headers.host, SC#sconf.servername]),
	    exit(normal)
    end;


pick_sconf(GC, H, Group, nossl) ->
    case H#headers.host of
	undefined when ?gc_pick_first_virthost_on_nomatch(GC) ->
	    hd(Group);
	Host ->
	    pick_host(GC, Host, Group, Group)
    end.


pick_host(GC, Host, [SC|T], Group) ->
    case comp_sname(Host, SC#sconf.servername) of
	true -> SC;
	false -> pick_host(GC, Host, T, Group)
    end;
pick_host(GC, Host, [], Group) ->
    if ?gc_pick_first_virthost_on_nomatch(GC) ->
	    hd(Group);
       true ->
	    yaws_debug:format("Drop req since ~p doesn't match any servername \n", 
			      [Host]),
	    exit(normal)
    end.




inet_peername(Sock, SC) ->
    case SC#sconf.ssl of
	undefined ->
	    inet:peername(Sock);
	_SSL ->
	    ssl:peername(Sock)
    end.
	    


maybe_auth_log(Item, ARG) ->
    GC=get(gc),
    SC=get(sc),
    case ?gc_has_auth_log(GC) of
	false ->
	    ok;
	true ->
	    Req = ARG#arg.req,
	    {IP,_} = ARG#arg.client_ip_port,
	    Path = safe_decode_path(Req#http_request.path),
	    yaws_log:authlog(SC#sconf.servername, IP, Path, Item)
    end.



maybe_access_log(Ip, Req, H) ->
    SC=get(sc),
    case ?sc_has_access_log(SC) of
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
	    User = case H#headers.authorization of
		       {User0, _Pass, _OrigString} ->
			   User0;
		       _ ->
			   "-"
		   end,
	    yaws_log:accesslog(SC#sconf.servername, Ip, User,
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




%% This is a request that is completely
%% broken, it can either be evil, but the most
%% probable cause is a broken (perl) test script that
%% tries to to talk to us ... albeit in a bad way ...
%% so let's log a small entry. I see no good reason to 
%% play nice and reply to this ...

bad_request(CliSock, Req, _Head) ->
    From = if
	       port(CliSock) ->
		   case inet:peername(CliSock) of
		       {ok, {IP, _Port}} ->
			   inet_parse:ntoa(IP);
		       _ ->
			   "unknown"
		   end;
	       true ->
		   case ssl:peername(CliSock) of
		       {ok, {IP, _Port}} ->
			   inet_parse:ntoa(IP);
		       _ ->
			   "unknown"
		   end
	   end,
    error_logger:info_msg("Bad req: ~p from ~s~n", [Req, From]),
    done.


%% ret:  continue | done
'GET'(CliSock, Req, Head) ->
    SC=get(sc),
    ok = yaws:setopts(CliSock, [{packet, raw}, binary], is_ssl(SC#sconf.ssl)),
    flush(CliSock, Head#headers.content_length),
    ARG = make_arg(CliSock, Head, Req, undefined),
    handle_request(CliSock, ARG, 0).


'POST'(CliSock, Req, Head) ->
    ?Debug("POST Req=~s~n H=~s~n", [?format_record(Req, http_request),
				    ?format_record(Head, headers)]),
    SC=get(sc),
    ok = yaws:setopts(CliSock, [{packet, raw}, binary], is_ssl(SC#sconf.ssl)),
    PPS = SC#sconf.partial_post_size,
    CT = 
	case yaws:lowercase(Head#headers.content_type) of
	    "multipart/form-data"++_ -> multipart;
	    _ -> urlencoded
	end,
    Bin = case Head#headers.content_length of
	      undefined ->
		  Chunked = Head#headers.transfer_encoding == "chunked",
		  case Head#headers.connection of
		      "close" when Chunked == false->
			  get_client_data(CliSock, all, is_ssl(SC#sconf.ssl));
		      _ when Chunked == true ->
			  get_chunked_client_data(CliSock,[],
						  is_ssl(SC#sconf.ssl))
		  end;
	      Len when integer(PPS) ->
		  Int_len = list_to_integer(Len),
		  if 
		      Int_len == 0 ->
			  <<>>;
		      PPS < Int_len, CT == multipart ->
			  {partial, get_client_data(CliSock, PPS,
						    is_ssl(SC#sconf.ssl))};
		      true ->
			  get_client_data(CliSock, Int_len,  
					  is_ssl(SC#sconf.ssl))
		  end;
	      Len when PPS == nolimit ->
		  Int_len = list_to_integer(Len),
		  if
		      Int_len == 0 ->
			  <<>>;
		      true ->
			  get_client_data(CliSock, Int_len, 
					  is_ssl(SC#sconf.ssl))
		  end
	  end,
    ?Debug("POST data = ~s~n", [binary_to_list(un_partial(Bin))]),
    ARG = make_arg(CliSock, Head, Req, Bin),
    handle_request(CliSock, ARG, size(un_partial(Bin))).


is_ssl(undefined) ->
    nossl;
is_ssl(R) when record(R, ssl) ->
    ssl.

un_partial({partial, Bin}) ->
    Bin;
un_partial(Bin) ->
    Bin.


call_method(Method, CliSock, Req, H) ->
    case Method of
	F when atom(F) ->
	    ?MODULE:F(CliSock, Req, H);
	L when list(L) ->
	    handle_extension_method(L, CliSock, Req, H)
    end.


'HEAD'(CliSock, Req, Head) ->
    put(acc_content, discard),
    'GET'(CliSock, Req, Head).

not_implemented(CliSock, Req, Head) ->
    SC=get(sc),
    ok = yaws:setopts(CliSock, [{packet, raw}, binary], is_ssl(SC#sconf.ssl)),
    flush(CliSock, Head#headers.content_length),
    deliver_501(CliSock, Req).
    

'TRACE'(CliSock, Req, Head) ->
    not_implemented(CliSock, Req, Head).

'OPTIONS'(CliSock, Req, Head) ->
    ?Debug("OPTIONS", []),
    SC=get(sc),
    ok = yaws:setopts(CliSock, [{packet, raw}, binary], is_ssl(SC#sconf.ssl)),
    flush(CliSock, Head#headers.content_length),
    ?Debug("OPTIONS delivering", []),
    deliver_options(CliSock, Req).

'PUT'(CliSock, Req, Head) ->
    ?Debug("PUT Req=~p~n H=~p~n", [?format_record(Req, http_request),
				   ?format_record(Head, headers)]),
    SC=get(sc),
    ok = yaws:setopts(CliSock, [{packet, raw}, binary], is_ssl(SC#sconf.ssl)),
    body_method(CliSock, Req, Head).
    

'DELETE'(CliSock, Req, Head) ->
    no_body_method(CliSock, Req, Head).


%%%
%%% WebDav specifics: PROPFIND, MKCOL,....
%%% 
'PROPFIND'(CliSock, Req, Head) ->
    %%?elog("PROPFIND Req=~p H=~p~n", 
    %%                   [?format_record(Req, http_request),
    %%                    ?format_record(Head, headers)]),
    body_method(CliSock, Req, Head).

'MOVE'(CliSock, Req, Head) ->
    no_body_method(CliSock, Req, Head).

'COPY'(CliSock, Req, Head) ->
    no_body_method(CliSock, Req, Head).


body_method(CliSock, Req, Head) ->
    SC=get(sc),
    ok = yaws:setopts(CliSock, [{packet, raw}, binary], is_ssl(SC#sconf.ssl)),
    PPS = SC#sconf.partial_post_size,
    Bin = case Head#headers.content_length of
             undefined ->
                 case Head#headers.connection of
                     "close" ->
                         get_client_data(CliSock, all, is_ssl(SC#sconf.ssl));
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
                         {partial, get_client_data(CliSock, PPS,
                                                   is_ssl(SC#sconf.ssl))};
                     true ->
                         get_client_data(CliSock, Int_len,  
                                         is_ssl(SC#sconf.ssl))
                 end;
             Len when PPS == nolimit ->
                 Int_len = list_to_integer(Len),
                 if
                     Int_len == 0 ->
                         <<>>;
                     true ->
                         get_client_data(CliSock, Int_len, 
                                         is_ssl(SC#sconf.ssl))
                 end
         end,
    ARG = make_arg(CliSock, Head, Req, Bin),
    handle_request(CliSock, ARG, size(un_partial(Bin))).


'MKCOL'(CliSock, Req, Head) ->
    no_body_method(CliSock, Req, Head).

no_body_method(CliSock, Req, Head) ->
    SC=get(sc),
    ok = yaws:setopts(CliSock, [{packet, raw}, binary], is_ssl(SC#sconf.ssl)),
    flush(CliSock, Head#headers.content_length),
    ARG = make_arg(CliSock, Head, Req, undefined),
    handle_request(CliSock, ARG, 0).


make_arg(CliSock, Head, Req, Bin) ->
    SC = get(sc),
    IP = if
	     port(CliSock) ->
		 case inet:peername(CliSock) of
		     {ok, IpPort} ->
			 IpPort;
		     _ ->
			 {unknown, unknown}
		 end;
	     true ->
		 case ssl:peername(CliSock) of
		     {ok, IpPort} ->
			 IpPort;
		     _ ->
			 {unknown, unknown}
		 end
	 end,
    ARG = #arg{clisock = CliSock,
	       client_ip_port = IP,
	       headers = Head,
	       req = Req,
	       opaque = SC#sconf.opaque,
	       pid = self(),
	       docroot = SC#sconf.docroot,
	       clidata = Bin},
    apply(SC#sconf.arg_rewrite_mod, arg_rewrite, [ARG]).


handle_extension_method("PROPFIND", CliSock, Req, Head) ->
    'PROPFIND'(CliSock, Req, Head);   
handle_extension_method("MKCOL", CliSock, Req, Head) ->                      
    'MKCOL'(CliSock, Req, Head);                                             
handle_extension_method("MOVE", CliSock, Req, Head) ->                      
    'MOVE'(CliSock, Req, Head);                                             
handle_extension_method("COPY", CliSock, Req, Head) ->                      
    'COPY'(CliSock, Req, Head);                                             
handle_extension_method(_Method, CliSock, Req, Head) ->
    not_implemented(CliSock, Req, Head).


%% Return values:
%% continue, done, {page, Page}

handle_request(CliSock, ARG, N) ->
    Req = ARG#arg.req,
    ?Debug("SrvReq=~s~n",[?format_record(Req, http_request)]),
    case Req#http_request.path of
	{abs_path, RawPath} ->
	    case (catch yaws_api:url_decode_q_split(RawPath)) of
		{'EXIT', _} ->   %% weird broken cracker requests
		    deliver_400(CliSock, Req);
		{DecPath, QueryPart} ->
		    SC=get(sc),
		    ?Debug("Test revproxy: ~p and ~p~n", 
			[DecPath, SC#sconf.revproxy]),
		    IsAuth = is_auth(ARG, DecPath,ARG#arg.headers,
				     SC#sconf.authdirs),
		    case {IsAuth, 
			  is_revproxy(DecPath, SC#sconf.revproxy),
			  is_redirect_map(DecPath, SC#sconf.redirect_map)} of
			{{appmod, Mod}, _, _} ->
			    UT = #urltype{type = appmod, 
			    		  data = {Mod, DecPath},
			     		  path = DecPath},
			    ARG2 = ARG#arg{server_path = DecPath,
					   querydata= QueryPart,
					   fullpath=UT#urltype.fullpath,
					   pathinfo=UT#urltype.pathinfo},
			    handle_ut(CliSock, ARG2, UT, N);
			{_, _, {true, MethodHostPort}} ->
			    deliver_302_map(CliSock, Req, ARG, MethodHostPort);
			{true, false, _} ->
			    UT   = url_type(DecPath, ARG#arg.docroot),
			    ARG2 = ARG#arg{server_path = DecPath,
					   querydata= QueryPart,
					   fullpath=UT#urltype.fullpath,
					   pathinfo=UT#urltype.pathinfo},
			    handle_ut(CliSock, ARG2, UT, N);
			{true, {true, PP}, _} ->
			    yaws_revproxy:init(CliSock, ARG,
					       DecPath,QueryPart,PP, N);
			{false, _, _} ->
			    deliver_403(CliSock, Req);
			{{false, Realm}, _, _} ->
			    deliver_401(CliSock, Req, Realm)
		    end
	    end;
	%%{absoluteURI, _Scheme, _Host, _Port, _RawPath}
	%%will not make it here.
	{scheme, _Scheme, _RequestString} ->
	    deliver_501(CliSock, Req);
	_ ->                                    % for completeness
	    deliver_400(CliSock, Req)
    end.


is_auth(_ARG, _Req_dir, _H, [] ) -> 
    true;
is_auth(ARG, Req_dir,H,[{Auth_dir, 
			 Auth=#auth{realm=Realm, users=Users, 
				    pam=Pam, mod=Mod}}|T] ) ->
    case lists:prefix(Auth_dir, Req_dir) of
	true when Mod /= [] ->
	    case catch Mod:auth(ARG, Auth) of
		{'EXIT', _} ->
		    {false, ""};
		{appmod, AppMod} ->
		    {appmod, AppMod};
		true -> 
		    true;
		{false, Realm} ->
		    maybe_auth_log({401, Realm}, ARG),
		    {false, Realm};
		_ ->
		    maybe_auth_log(403, ARG),
		    false
	    end;
	true ->
	    case H#headers.authorization of
		undefined ->
		    maybe_auth_log({401, Realm}, ARG),
		    {false, Realm};
		{User, Password, _OrigString} ->
		    case member({User, Password}, Users) of
			true ->
			    maybe_auth_log({ok, User}, ARG),
			    true;
			false when Pam == false ->
			    maybe_auth_log({401, User, Password}, ARG),
			    {false, Realm};
			false when Pam /= false ->
			    case yaws_pam:auth(User, Password) of
				{yes, _} ->
				    maybe_auth_log({ok, User}, ARG),
				    true;
				{no, _Rsn} ->
				    maybe_auth_log({401, User, Password}, ARG),
				    {false, Realm}
			    end
		    end
	    end;
	false ->
	    is_auth(ARG, Req_dir, H, T)
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

is_redirect_map(_, []) ->
    false;
is_redirect_map(Path, [E={Prefix, _}|Tail]) ->
    case yaws:is_prefix(Prefix, Path) of
	{true, _} ->
	    {true, E};
	false ->
	    is_redirect_map(Path, Tail)
    end;
is_redirect_map(Path, [E={Prefix,_,_}|Tail]) ->
    case yaws:is_prefix(Prefix, Path) of
	{true, _} ->
	    {true, E};
	false ->
	    is_redirect_map(Path, Tail)
    end.

%% Return values:
%% continue, done, {page, Page}

handle_ut(CliSock, ARG, UT, N) ->
    Req = ARG#arg.req,
    H = ARG#arg.headers,
    SC=get(sc),GC=get(gc),
    case UT#urltype.type of
	error when SC#sconf.xtra_docroots == [] ->
	    yaws:outh_set_dyn_headers(Req, H, UT),
	    deliver_dyn_part(CliSock, 
			     0, "404",
			     N,
			     ARG,UT,
			     fun(A)->(SC#sconf.errormod_404):
					 out404(A,GC,SC) 
			     end,
			     fun(A)->finish_up_dyn_file(A, CliSock)
			     end
			    );
	error ->
	    SC2 = SC#sconf{docroot = hd(SC#sconf.xtra_docroots),
			   xtra_docroots = tl(SC#sconf.xtra_docroots)},
	    put(sc, SC2),
	    ARG2 = ARG#arg{docroot = SC2#sconf.docroot},
	    handle_request(CliSock, ARG2, N);
	directory when ?sc_has_dir_listings(SC) ->
	    P = UT#urltype.dir,
	    yaws:outh_set_dyn_headers(Req, H, UT),
	    yaws_ls:list_directory(ARG, CliSock, UT#urltype.data, P, Req,
				   ?sc_has_dir_all_zip(SC));
	directory ->
	    handle_ut(CliSock, ARG, #urltype{type = error}, N);
	regular ->
	    ETag = yaws:make_etag(UT#urltype.finfo),
	    Range = case H#headers.if_range of
%			[$"|_] = Range_etag when Range_etag /= ETag -> 
			[34|_] = Range_etag when Range_etag /= ETag -> 
			    all; 
			_ ->
			    requested_range(H#headers.range, 
					    (UT#urltype.finfo)#file_info.size)
		    end,
	    case Range of
		error -> deliver_416(CliSock, Req, 
				     (UT#urltype.finfo)#file_info.size);
		_ ->
		    case H#headers.if_none_match of
			undefined ->
			    case H#headers.if_match of
				undefined -> 				    
				    yaws:outh_set_static_headers
				      (Req, UT, H, Range),
				    deliver_file
				      (CliSock, Req, UT, Range);

				Line -> 
				    case member(ETag,
						yaws:split_sep(Line, $,)) of
					true -> 
					    yaws:outh_set_static_headers
					      (Req, UT, H, Range),
					    deliver_file(CliSock, 
							 Req, UT, Range);
					false ->
					    deliver_xxx(CliSock, Req, 412) 
				    end
			    end;
			Line ->
			    case member(ETag,yaws:split_sep(Line, $,)) of
				true ->
				    yaws:outh_set_304_headers(Req, UT, H),
				    deliver_accumulated(CliSock),
				    done_or_continue();
				false ->
				    yaws:outh_set_static_headers
				      (Req, UT, H, Range),
				    deliver_file(CliSock, Req, UT, Range)
			    end
		    end
	    end;
	yaws ->
	    ?Debug("UT = ~s~n", [?format_record(UT, urltype)]),
	    yaws:outh_set_dyn_headers(Req, H, UT),
	    do_yaws(CliSock, ARG, UT, N);
	redir ->
	    yaws:outh_set_dyn_headers(Req, H, UT),
	    deliver_302(CliSock, Req, ARG, UT#urltype.path);
	appmod ->
	    yaws:outh_set_dyn_headers(Req, H, UT),
 	    {Mod, PathData} = UT#urltype.data,
 	    A2 = ARG#arg{appmoddata = PathData,  % trail
 			 appmod_prepath = UT#urltype.path}, % head
	    deliver_dyn_part(CliSock, 
			     0, "appmod",
			     N,
			     A2,UT,
			     fun(A)->Mod:out(A) end,
			     fun(A)->finish_up_dyn_file(A, CliSock)
			     end
			    );
	cgi ->
	    yaws:outh_set_dyn_headers(Req, H, UT),
	    deliver_dyn_part(CliSock, 
			     0, "cgi",
			     N,
			     ARG,UT,
			     fun(A)->yaws_cgi:call_cgi(
				       A,flatten(UT#urltype.fullpath))
			     end,
			     fun(A)->finish_up_dyn_file(A, CliSock)
			     end
			    );
	php ->
	    yaws:outh_set_dyn_headers(Req, H, UT),
	    deliver_dyn_part(CliSock, 
			     0, "php",
			     N,
			     ARG,UT,
			     fun(A)->yaws_cgi:call_cgi(
				       A,
				       GC#gconf.phpexe,
				       flatten(UT#urltype.fullpath))
			     end,
			     fun(A)->finish_up_dyn_file(A, CliSock)
			     end
			    );
	dav ->
	    Next =
		if
		    Req#http_request.method == 'PUT' ->
			fun(A) -> yaws_dav:put(SC, A) end;
		    Req#http_request.method == 'DELETE' ->
			fun(A) -> yaws_dav:delete(A) end;
		    Req#http_request.method == "PROPFIND" ->
			fun(A)-> yaws_dav:propfind(A) end;
		    Req#http_request.method == "MOVE" ->
			fun(A)-> yaws_dav:move(A) end;
		    Req#http_request.method == "COPY" ->
			fun(A)-> yaws_dav:copy(A) end;
		    Req#http_request.method == "MKCOL" ->
			fun(A)-> yaws_dav:mkcol(A) end;
		    Req#http_request.method == 'GET';
		    Req#http_request.method == 'HEAD' ->
			case prim_file:read_file_info(UT#urltype.fullpath) of
			    {ok, FI} when FI#file_info.type == regular ->
				{regular, FI};
			    _ ->
				error
			end;
		    true ->
			error
		end,
	    case Next of
		error ->
		    handle_ut(CliSock, ARG, #urltype{type = error}, N);
		{regular, Finfo} ->
		    handle_ut(CliSock, ARG, UT#urltype{type = regular,
						       finfo = Finfo}, N);
		_ ->
		    yaws:outh_set_dyn_headers(Req, H, UT),
		    deliver_dyn_part(CliSock, 
				     0, "dav",
				     N,
				     ARG,UT,
				     Next,
				     fun(A)->finish_up_dyn_file(A, CliSock)  end
				    )
	    end
    end.

done_or_continue() ->
    case yaws:outh_get_doclose() of
	true -> done;
	false -> continue;
	keep_alive -> continue 
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


deliver_302(CliSock, _Req, Arg, Path) ->
    ?Debug("in redir 302 ",[]),
    H = get(outh),
    SC=get(sc),
    Scheme = yaws:redirect_scheme(SC),
    Headers = Arg#arg.headers,
    DecPath = yaws_api:url_decode(Path),
    RedirHost = yaws:redirect_host(SC, Headers#headers.host),
    Loc = case string:tokens(DecPath, "?") of
	      [P] ->
		  ["Location: ", Scheme,
		   RedirHost, P, "\r\n"];
	      [P, Q] ->
		  ["Location: ", Scheme,
		   RedirHost, P, "?", Q, "\r\n"]
	  end,

    new_redir_h(H, Loc),
    deliver_accumulated(CliSock),
    done_or_continue().


deliver_302_map(CliSock, Req, Arg, MethodHostPort) ->
    ?Debug("in redir 302 ",[]),
    H = get(outh),
    SC=get(sc),
    DecPath = safe_decode_path(Req#http_request.path),
    {Scheme, RedirHost} =
	case MethodHostPort of
	    {_,Method,HostPort} ->
		{Method, HostPort};
	    {_,HostPort} ->
		{yaws:redirect_scheme(SC), HostPort}
	end,
    Loc = case string:tokens(DecPath, "?") of
	      [P] ->
		  ["Location: ", Scheme,
		   RedirHost, P, "\r\n"];
	      [P, Q] ->
		  ["Location: ", Scheme,
		   RedirHost, P, "?", Q, "\r\n"]
	  end,


    Headers = Arg#arg.headers,

    {DoClose, _Chunked} = yaws:dcc(Req, Headers),

    new_redir_h(H#outh{
		  connection  = yaws:make_connection_close_header(DoClose),
		  doclose = DoClose,
		  server = yaws:make_server_header(),
		  chunked = false,
		  date = yaws:make_date_header()
		 }, Loc),

    deliver_accumulated(CliSock),
    done_or_continue().

deliver_options(CliSock, _Req) ->
    H = #outh{status = 200,
	      doclose = false,
	      chunked = false,
	      server = yaws:make_server_header(),
	      allow = yaws:make_allow_header()},
    put(outh, H),
    deliver_accumulated(CliSock),
    continue.

deliver_xxx(CliSock, _Req, Code) ->
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
    deliver_accumulated(CliSock),
    done.

deliver_400(CliSock, Req) ->  
    deliver_xxx(CliSock, Req, 400).% Bad Request

deliver_401(CliSock, _Req, Realm) ->
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
    deliver_accumulated(CliSock),
    done.
    
deliver_403(CliSock, Req) ->
    deliver_xxx(CliSock, Req, 403).	% Forbidden
    
deliver_416(CliSock, _Req, Tot) ->
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
    deliver_accumulated(CliSock),
    done.

deliver_501(CliSock, Req) ->
    deliver_xxx(CliSock, Req, 501). % Not implemented
						
    


do_yaws(CliSock, ARG, UT, N) ->
    Key = UT#urltype.getpath, %% always flat
    Mtime = mtime(UT#urltype.finfo),
    SC=get(sc),
    case ets:lookup(SC#sconf.ets, Key) of
	[{_Key, spec, Mtime1, Spec, Es}] when Mtime1 == Mtime,
					      Es == 0 ->
	    deliver_dyn_file(CliSock, Spec, ARG, UT, N);
	Other  ->
	    del_old_files(get(gc),Other),
	    {ok, [{errors, Errs}| Spec]} = 
		yaws_compile:compile_file(UT#urltype.fullpath),
	    ?Debug("Spec for file ~s is:~n~p~n",[UT#urltype.fullpath, Spec]),
	    ets:insert(SC#sconf.ets, {Key, spec, Mtime, Spec, Errs}),
	    deliver_dyn_file(CliSock, Spec, ARG, UT, N)
    end.


del_old_files(_, []) ->
    ok;
del_old_files(GC, [{_FileAtom, spec, _Mtime1, Spec, _}]) ->
    foreach(
      fun({mod, _, _, _,  Mod, _Func}) ->
	      F=filename:join([GC#gconf.tmpdir, "yaws", 
			       yaws:to_list(Mod) ++ ".erl"]),
	      code:purge(Mod),
	      code:purge(Mod),
	      file:delete(F);
	 (_) ->
	      ok
      end, Spec).
		     

get_client_data(CliSock, all, SSlBool) ->
    get_client_data_all(CliSock, [], SSlBool);

get_client_data(CliSock, Len, SSlBool) ->
    get_client_data_len(CliSock, Len, [], SSlBool).


%% not nice to support this for ssl sockets
get_chunked_client_data(CliSock,Bs,SSL) ->
    yaws:setopts(CliSock, [binary, {packet, line}],SSL),
    N = yaws_revproxy:get_chunk_num(CliSock,SSL),
    yaws:setopts(CliSock, [binary, {packet, raw}],SSL),
    if
	N == 0 ->
	    _Tmp=yaws:do_recv(CliSock, 2, SSL),%% flush last crnl
	    list_to_binary(Bs);
	true ->
	    B = yaws_revproxy:get_chunk(CliSock, N, 0,SSL),
	    yaws_revproxy:eat_crnl(CliSock,SSL),
	    get_chunked_client_data(CliSock, [Bs,B], SSL)
    end.


get_client_data_len(_CliSock, 0, Bs, _SSlBool) ->
    list_to_binary(Bs);
get_client_data_len(CliSock, Len, Bs, SSlBool) ->
    case yaws:cli_recv(CliSock, Len, SSlBool) of
	{ok, B} ->
	    get_client_data_len(CliSock, Len-size(B), [Bs,B], SSlBool);
	_Other ->
	    ?Debug("get_client_data_len: ~p~n", [_Other]),
	    exit(normal)
    end.

get_client_data_all(CliSock, Bs, SSlBool) ->
    case yaws:cli_recv(CliSock, 4000, SSlBool) of
	{ok, B} ->
	    get_client_data_all(CliSock, [Bs|B] , SSlBool);
	eof ->
	    list_to_binary(Bs);
	_Other ->
	    ?Debug("get_client_data_all: ~p~n", [_Other]),
	    exit(normal)
    end.

%% Return values:
%% continue, done, {page, Page}

deliver_dyn_part(CliSock,                  % essential params
		 LineNo, YawsFile,         % for diagnostic output
		 CliDataPos,               % for `get_more'
		 Arg,UT,
		 YawsFun,                  % call YawsFun(Arg)
		 DeliverCont               % call DeliverCont(Arg)
						% to continue normally
		) ->
    Res = (catch YawsFun(Arg)),
    case handle_out_reply(Res, LineNo, YawsFile, UT, [Arg]) of
	{get_more, Cont, State} when 
	      element(1, Arg#arg.clidata) == partial  ->
	    More = get_more_post_data(CliDataPos, Arg),
	    case un_partial(More) of
		Bin when binary(Bin) ->
		    A2 = Arg#arg{clidata = More,
				 cont = Cont,
				 state = State},
		    deliver_dyn_part(
		      CliSock, LineNo, YawsFile, 
		      CliDataPos+size(un_partial(More)), 
		      A2, UT, YawsFun, DeliverCont
		     );
		Err ->
		    A2 = Arg#arg{clidata = Err,
				 cont = undefined,
				 state = State},
		    catch YawsFun(A2),
		    exit(normal)         % ???
	    end;
	break ->
	    finish_up_dyn_file(Arg, CliSock);
	{page, Page} ->
	    {page, Page};
        Arg2 = #arg{} ->
	    DeliverCont(Arg2);
	{streamcontent, MimeType, FirstChunk} ->
	    yaws:outh_set_content_type(MimeType),
	    accumulate_content(FirstChunk),
	    Priv = deliver_accumulated(Arg, CliSock, 
				       decide, undefined, stream),
	    stream_loop_send(Priv, CliSock);
	{streamcontent_with_size, Sz, MimeType, FirstChunk} ->
	    yaws:outh_set_content_type(MimeType),
	    accumulate_content(FirstChunk),
	    Priv = deliver_accumulated(Arg, CliSock, 
				       decide, Sz, stream),
	    stream_loop_send(Priv, CliSock);
	_ ->
	    DeliverCont(Arg)
    end.

finish_up_dyn_file(Arg, CliSock) ->
    deliver_accumulated(Arg, CliSock, decide, undefined, final),
    done_or_continue().



%% do the header and continue
deliver_dyn_file(CliSock, Specs, ARG, UT, N) ->
    Fd = ut_open(UT),
    Bin = ut_read(Fd),
    deliver_dyn_file(CliSock, Bin, Fd, Specs, ARG, UT, N).



deliver_dyn_file(CliSock, Bin, Fd, [H|T],Arg, UT, N) ->
    ?Debug("deliver_dyn_file: ~p~n", [H]),
    case H of
	{mod, LineNo, YawsFile, NumChars, Mod, out} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    deliver_dyn_part(CliSock, LineNo, YawsFile,
			     N, Arg, UT,
			     fun(A)->Mod:out(A) end,
			     fun(A)->deliver_dyn_file(
				       CliSock,Bin2,Fd,T,A,UT,0)
			     end);
	{data, 0} ->
	    deliver_dyn_file(CliSock, Bin, Fd,T,Arg,UT,N);
	{data, NumChars} ->
	    {Send, Bin2} = skip_data(Bin, Fd, NumChars),
	    accumulate_content(Send),
	    deliver_dyn_file(CliSock, Bin2, Fd, T,Arg,UT,N);
	{skip, 0} ->
	    deliver_dyn_file(CliSock, Bin, Fd,T,Arg,UT,N);
	{skip, NumChars} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    deliver_dyn_file(CliSock, Bin2, Fd, T,Arg,UT,N);
	{binding, NumChars} ->
	    {Send, Bin2} = skip_data(Bin, Fd, NumChars),
	    "%%"++Key = binary_to_list(Send),
	    Chunk =
		case get({binding, Key--"%%"}) of
		    undefined -> Send;
		    Value -> Value
		end,
	    accumulate_content(Chunk),
	    deliver_dyn_file(CliSock, Bin2, Fd, T, Arg, UT, N);
	{error, NumChars, Str} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    accumulate_content(Str),
	    deliver_dyn_file(CliSock, Bin2, Fd, T,Arg,UT, N);
	{verbatim, NumChars, Data} ->
	    {_Send, Bin2} = skip_data(Bin, Fd, NumChars),
	    accumulate_content(Data),
	    deliver_dyn_file(CliSock, Bin2, Fd, T,Arg,UT,N);
	yssi ->
	    ok
    end;


deliver_dyn_file(CliSock, _Bin, _Fd, [], ARG,_UT,_N) ->
    ?Debug("deliver_dyn: done~n", []),
    finish_up_dyn_file(ARG, CliSock).


stream_loop_send(Priv, CliSock) ->
    stream_loop_send(Priv, CliSock, unflushed).

stream_loop_send(Priv, CliSock, FlushStatus) ->
    TimeOut = case FlushStatus of
		  flushed -> 30000;
		  unflushed -> 300
	      end,
    receive
	{streamcontent, Cont} ->
	    P = send_streamcontent_chunk(Priv, CliSock, Cont),
	    stream_loop_send(P, CliSock, unflushed) ;
	{streamcontent_with_ack, From, Cont} ->	% acknowledge after send
	    P = send_streamcontent_chunk(Priv, CliSock, Cont),
	    From ! {self(), streamcontent_ack},
	    stream_loop_send(P, CliSock, unflushed) ;
	endofstreamcontent ->
	    end_streaming(Priv, CliSock)
    after TimeOut ->
	    case FlushStatus of
		flushed ->
		    erlang:fault(stream_timeout);
		unflushed ->
		    P = sync_streamcontent(Priv, CliSock),
		    stream_loop_send(P, CliSock, flushed)
	    end
    end.


make_chunk(Data) ->
    case yaws:outh_get_chunked() of
	true ->
	    case binary_size(Data) of
		0 ->
		    empty;
		S ->
		    CRNL = crnl(),
		    {S, [yaws:integer_to_hex(S), CRNL, Data, CRNL]}
	    end;
	false ->
	    {binary_size(Data), Data}
    end.

make_final_chunk(Data) ->
    case yaws:outh_get_chunked() of
	true ->
	    CRNL = crnl(),
	    case binary_size(Data) of
		0 ->
		    {0, ["0",CRNL,CRNL]};
		S ->
		    {S, [yaws:integer_to_hex(S), CRNL, Data, CRNL, 
			 "0", CRNL, CRNL]}
	    end;
	false ->
	    {binary_size(Data), Data}
    end.

send_streamcontent_chunk(discard, _, _) ->
    discard;
send_streamcontent_chunk(undeflated, CliSock, Data) ->
    case make_chunk(Data) of
	empty -> ok;
	{Size, Chunk} ->
	    ?Debug("send ~p bytes to ~p ~n", 
		[Size, CliSock]),
	    yaws:outh_inc_act_contlen(Size),
	    yaws:gen_tcp_send(CliSock, Chunk)
    end,
    undeflated;
send_streamcontent_chunk({Z, Priv}, CliSock, Data) ->
    ?Debug("send ~p bytes to ~p ~n", 
		[binary_size(Data), CliSock]),
    {ok, P, D} = yaws_zlib:gzipDeflate(Z, Priv, to_binary(Data), none),
    case make_chunk(D) of
	empty -> ok;
	{Size, Chunk} ->
	    yaws:outh_inc_act_contlen(Size),
	    yaws:gen_tcp_send(CliSock, Chunk)
    end,
    {Z, P}.


sync_streamcontent(discard, _CliSock) ->
    discard;
sync_streamcontent(undeflated, _CliSock) ->
    undeflated;
sync_streamcontent({Z, Priv}, CliSock) ->
    ?Debug("syncing~n", []),
    {ok, P, D} = yaws_zlib:gzipDeflate(Z, Priv, <<>>, sync),
    case make_chunk(D) of
	empty -> ok;
	{Size, Chunk} ->
	    yaws:outh_inc_act_contlen(Size),
	    yaws:gen_tcp_send(CliSock, Chunk)
    end,
    {Z, P}.
    

end_streaming(discard, _) ->
    done_or_continue();
end_streaming(undeflated, CliSock) ->
    ?Debug("end_streaming~n", []),
    {_, Chunk} = make_final_chunk(<<>>),
    yaws:gen_tcp_send(CliSock, Chunk),
    done_or_continue();
end_streaming({Z, Priv}, CliSock) ->
    ?Debug("end_streaming~n", []),
    {ok, _P, Data} = yaws_zlib:gzipDeflate(Z, Priv, <<>>, finish),
    {Size, Chunk} = make_final_chunk(Data),
    yaws:outh_inc_act_contlen(Size),
    yaws:gen_tcp_send(CliSock, Chunk),
    yaws_zlib:gzipEnd(Z),
    zlib:close(Z),
    done_or_continue().

    
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

accumulate_content(Data) ->
    case get(acc_content) of
	undefined ->
	    put(acc_content, [Data]);
	discard ->
	    discard;
	List ->
	    put(acc_content, [List, Data])
    end.


%% handle_out_reply(R, ...)
%% 
%% R is a reply or a deep list of replies.  The special return values
%% `streamcontent', `get_more_data' etc, which are not handled here
%% completely but returned, have to be the last element of the list.

handle_out_reply(L, LineNo, YawsFile, UT, A) when list (L) ->
    handle_out_reply_l(L, LineNo, YawsFile, UT, A, undefined);




%% yssi, yaws include
handle_out_reply({yssi, Yfile}, LineNo, YawsFile, UT, [ARG]) ->
    SC = get(sc),
    
    % special case for abs paths
    UT2=case Yfile of
	    [$/|_] ->
               url_type( Yfile, ARG#arg.docroot);
           _Else ->
               url_type(lists:flatten(UT#urltype.dir) ++ [$/|Yfile],
                        ARG#arg.docroot)
       end, 

    case UT2#urltype.type of
	yaws ->
	    Mtime = mtime(UT2#urltype.finfo),
	    Key = UT2#urltype.getpath,
	    CliSock = ARG#arg.clisock,
	    N = 0,
	    case ets:lookup(SC#sconf.ets, Key) of
		[{_Key, spec, Mtime1, Spec, Es}] when Mtime1 == Mtime,
						      Es == 0 ->
		    deliver_dyn_file(CliSock, Spec ++ [yssi], ARG, UT2, N);
		Other  ->
		    del_old_files(get(gc), Other),
		    {ok, [{errors, Errs}| Spec]} = 
			yaws_compile:compile_file(UT2#urltype.fullpath),
		    ?Debug("Spec for file ~s is:~n~p~n",
			   [UT2#urltype.fullpath, Spec]),
		    ets:insert(SC#sconf.ets, {Key, spec, Mtime, Spec, Errs}),
		    deliver_dyn_file(CliSock, Spec ++ [yssi], ARG, UT2, N)
	    end;
	error when SC#sconf.xtra_docroots /= [] ->
	    SC2 = SC#sconf{docroot = hd(SC#sconf.xtra_docroots),
				   xtra_docroots = tl(SC#sconf.xtra_docroots)},
	    put(sc, SC2), ARG2 = ARG#arg{docroot = SC2#sconf.docroot},
	    Ret = handle_out_reply({yssi, Yfile}, LineNo, YawsFile,UT, [ARG2]),
	    put(sc, SC),
	    Ret;
	_ ->
	    error_logger:format("Failed to yssi ~p~n", [Yfile]),
	    ok
    end;


handle_out_reply({html, Html}, _LineNo, _YawsFile,  _UT, _A) ->
    accumulate_content(Html);

handle_out_reply({ehtml, E}, _LineNo, _YawsFile,  UT, A) ->
    put(yaws_ut, UT),
    Res = case safe_ehtml_expand(E) of
	{ok, Val} ->
	    accumulate_content(Val);
	{error, ErrStr} ->
	    handle_crash(A,ErrStr)
    end,
    erase(yaws_ut),
    Res;

handle_out_reply({content, MimeType, Cont}, _LineNo,_YawsFile, _UT, _A) ->
    yaws:outh_set_content_type(MimeType),
    accumulate_content(Cont);

handle_out_reply({streamcontent, MimeType, First}, 
		 _LineNo,_YawsFile, _UT, _A) ->
    yaws:outh_set_content_type(MimeType),
    {streamcontent, MimeType, First};

handle_out_reply(Res = {page, _Page},
		 _LineNo,_YawsFile, _UT, _A) ->
    Res;

handle_out_reply({streamcontent_with_size, Sz, MimeType, First}, 
		 _LineNo,_YawsFile, _UT, _A) ->
    yaws:outh_set_content_type(MimeType),
    {streamcontent_with_size, Sz, MimeType, First};

handle_out_reply({header, H},  _LineNo, _YawsFile, _UT, _A) ->
    yaws:accumulate_header(H);

handle_out_reply({allheaders, Hs}, _LineNo, _YawsFile, _UT, _A) ->
    yaws:outh_clear_headers(),
    foreach(fun({header, Head}) -> yaws:accumulate_header(Head) end, Hs);

handle_out_reply({status, Code},_LineNo,_YawsFile,_UT,_A) when integer(Code) ->
    yaws:outh_set_status_code(Code);

handle_out_reply({'EXIT', normal}, _LineNo, _YawsFile, _UT, _A) ->
    exit(normal);

handle_out_reply({ssi, File, Delimiter, Bindings}, LineNo, YawsFile, UT, A) ->
    [ARG] = A,
    case ssi(File, Delimiter, Bindings, UT#urltype.dir, ARG#arg.docroot) of
	{error, Rsn} ->
	    L = ?F("yaws code at~s:~p had the following err:~n~p",
		   [YawsFile, LineNo, Rsn]),
	    handle_crash(A, L);
	OutData ->
	    accumulate_content(OutData)
    end;


handle_out_reply(break, _LineNo, _YawsFile, _UT, _A) ->
    break;

handle_out_reply({redirect_local, Path}, LN, YF, UT, A) ->
    handle_out_reply({redirect_local, Path, 302}, LN, YF, UT,A);

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
		 YawsFile, _UT, A) ->
    PathType = 
	case yaws_api:is_absolute_URI(URL) of
	    true -> net_path;
	    false -> case URL of
			 [$/|_] -> abs_path;
			 _ -> rel_path
		     end
	end,
    handle_out_reply({redirect_local, {PathType, URL}, Status}, LineNo,
		     YawsFile, _UT, A);

handle_out_reply({redirect_local, {net_path, URL}, Status}, _LineNo,
		  _YawsFile,  _UT, _A) ->
    Loc = ["Location: ", URL, "\r\n"],
    new_redir_h(get(outh), Loc, Status),
    ok;

handle_out_reply({redirect_local, Path0, Status}, _LineNo, _YawsFile, _UT,A) ->
    Arg = hd(A),
    SC=get(sc),
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
    Scheme = yaws:redirect_scheme(SC),
    Headers = Arg#arg.headers,
    HostPort = yaws:redirect_host(SC, Headers#headers.host),
    Loc = ["Location: ", Scheme, HostPort, Path, "\r\n"],
    new_redir_h(get(outh), Loc, Status),
    ok;

handle_out_reply({redirect, URL}, LN, YF, UT,A) ->
    handle_out_reply({redirect, URL, 302}, LN, YF, UT, A);

handle_out_reply({redirect, URL, Status}, _LineNo, _YawsFile, _UT, _A) ->
    Loc = ["Location: ", URL, "\r\n"],
    new_redir_h(get(outh), Loc, Status),
    ok;

handle_out_reply({bindings, L}, _LineNo, _YawsFile, _UT,_A) ->
    foreach(fun({Key, Value}) -> put({binding, Key}, Value) end, L),
    ok;

handle_out_reply(ok, _LineNo, _YawsFile, _UT,_A) ->
    ok;

handle_out_reply({'EXIT', Err}, LineNo, YawsFile, _UT,ArgL) ->
    A = hd(ArgL),
    L = ?F("~n~nERROR erlang  code  crashed:~n "
	   "File: ~s:~w~n"
	   "Reason: ~p~nReq: ~p~n",
	   [YawsFile, LineNo, Err, A#arg.req]),
    handle_crash(A, L);

handle_out_reply({get_more, Cont, State}, _LineNo, _YawsFile, _UT,_A) ->
    {get_more, Cont, State};

handle_out_reply(Arg = #arg{},  _LineNo, _YawsFile, _UT, _A) ->
    Arg;

handle_out_reply(Reply, LineNo, YawsFile, _UT, ArgL) ->
    A = hd(ArgL),
    L =  ?F("yaws code at ~s:~p crashed or "
	    "ret bad val:~p ~nReq: ~p",
	    [YawsFile, LineNo, Reply, A#arg.req]),
    handle_crash(A, L).

    

handle_out_reply_l([Reply|T], LineNo, YawsFile, UT, A, _Res) ->		  
    case handle_out_reply(Reply, LineNo, YawsFile, UT, A) of
	break ->
	    break;
	{page, Page} ->
	    {page, Page};
	RetVal ->
	    handle_out_reply_l(T, LineNo, YawsFile, UT, A, RetVal)
    end;
handle_out_reply_l([], _LineNo, _YawsFile, _UT, _A, Res) ->
    Res.




%% fast server side include with macrolike variable bindings expansion
ssi(File, Delimiter, Bindings, Dir) ->
    SC = get(sc),
    ssi(File, Delimiter, Bindings, Dir, SC#sconf.docroot, SC ).
ssi(File, Delimiter, Bindings, Dir, Docroot) ->
    ssi(File, Delimiter, Bindings, Dir, Docroot, get(sc)).
ssi(File, Delimiter, Bindings, Dir, Docroot, SC) ->
    Key = {ssi, File, Delimiter},
    FullPath =
	case File of
	    {rel_path, FileName} ->
		[Docroot, Dir,[$/|FileName]];
	    {abs_path, FileName} ->
		[Docroot, [$/|FileName]];
	    FileName when list(FileName) ->
		[Docroot, [$/|FileName]]
	end,
    Mtime = path_to_mtime(FullPath),
    case ets:lookup(SC#sconf.ets, Key) of
	[{_, Parts, Mtime}] ->
	    case (catch expand_parts(Parts, Bindings, [])) of
		{'EXIT', ErrStr} ->
		    {error, ErrStr};
		Value ->
		    Value
	    end;
	_ ->
	    case prim_file:read_file(FullPath) of
		{ok, Bin} ->
		    D =delim_split_file(Delimiter,binary_to_list(Bin),data,[]),
		    ets:insert(SC#sconf.ets,{Key,D, Mtime}),
		    ssi(File, Delimiter, Bindings, Dir, Docroot, SC);
		{error, _} when SC#sconf.xtra_docroots /= [] ->
		    SC2 = SC#sconf{docroot = hd(SC#sconf.xtra_docroots),
				   xtra_docroots = tl(SC#sconf.xtra_docroots)},
		    ssi(File, Delimiter, Bindings, Dir, SC2#sconf.docroot, SC2);
		{error, Rsn} ->
		    error_logger:format("Failed to read/ssi file ~p~n", 
					[FullPath]),
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
	{value, {_, {ehtml, E}}} ->
	    case safe_ehtml_expand(E) of
		{ok, Val} ->
		    expand_parts(T, Bs, [Val|Ack]);
		{error, ErrStr} ->
		    erlang:fault(ErrStr)
	    end;
	{value, {_, Val}} ->
	    expand_parts(T, Bs, [Val|Ack]);
	false ->
	    expand_parts(T, Bs, Ack)
	    %%{error, ?F("No variable binding found for ~p", [V])}
    end;
expand_parts([], _,Ack) ->
    lists:reverse(Ack).

	    

delim_split_file([], Data, _, _Ack) ->
    [{data, Data}];
delim_split_file(Del, Data, State, Ack) ->
    case delim_split(Del, Del, Data, [], []) of
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


delim_split([H|T], Odel, [H|T1], Ack, DAcc) ->
    delim_split(T,Odel,T1,Ack, [H|DAcc]);
delim_split([], _Odel, T, Ack, _DAcc) ->
    {lists:reverse(Ack),T};
delim_split([H|_T],Odel, [H1|T1], Ack, []) when H /= H1 ->
    delim_split(Odel, Odel, T1, [H1|Ack], []);
delim_split([H|_T],Odel, [H1|T1], Ack, DAcc) when H /= H1 ->
    delim_split(Odel, Odel, T1, [H1|DAcc++Ack], []);
delim_split(_,_,[],Ack,[]) ->
    {lists:reverse(Ack),[]};
delim_split(_,_,[],Ack,DAcc) ->
    {lists:reverse(DAcc++Ack),[]}.



%% Erlang yaws code crashed, display either the
%% actual crash or a custimized error message 

handle_crash(A, L) ->
    ?Debug("handle_crash(~p)~n", [L]),
    SC=get(sc),
    yaws:elog("~s", [L]),
    case catch apply(SC#sconf.errormod_crash, crashmsg, [A, SC, L]) of
	{html, Str} ->
	    accumulate_content(Str),
	    break;
	{ehtml, Term} ->
	    case safe_ehtml_expand(Term) of
		{error, Reason} ->
		    yaws:elog("~s", [Reason]),
		    %% Aghhh, yet another user crash :-(
		    T2 = [{h2, [], "Internal error"}, {hr},
			  {p, [], "Customized crash display code crashed !!!"}],
		    accumulate_content(ehtml_expand(T2)),
		    break;
		{ok, Out} ->
		    accumulate_content(Out),
		    break
	    end;
	Other ->
	    yaws:elog("Bad return value from errmod_crash ~n~p~n",[Other]),
	    T2 = [{h2, [], "Internal error"}, {hr},
		  {p, [], "Customized crash display code returned bad val"}],
	    accumulate_content(ehtml_expand(T2)),
	    break
	
    end.

%% Ret: true | false | {data, Data}
decide_deflate(false, _, _, _, _) ->
    false;
decide_deflate(_, _, _, no, _) ->
    false;
decide_deflate(true, _, _, deflate, stream) ->
    true;
decide_deflate(true, Arg, Data, decide, Mode) ->
    case yaws:outh_get_content_encoding_header() of
	undefined ->
	    ?Debug("No Content-Encoding defined~n",[]),
	    Mime = yaws:outh_get_content_type(),
	    ?Debug("Mime-Type: ~p~n", [Mime]),
	    case compressible_mime_type(Mime) of
		true ->
		    case yaws:accepts_gzip(Arg#arg.headers,
					   Mime) of
			true -> 
			    case Mode of 
				final ->
				    case yaws_zlib:gzip(to_binary(Data)) of
					{ok, DB} ->
					    {data, DB};
					_Err -> 
					    ?Debug(
						"gzip Err: ~p~n", [_Err]),
						false
					end;
				    stream ->
					true
				end;
			false -> false
		    end;
		false ->
		    false
	    end;
	_CE -> ?Debug("Content-Encoding: ~p~n",[_CE]),
	       false
    end.


deliver_accumulated(Sock) ->
    deliver_accumulated(undefined, Sock, no, undefined, final).

%% Mode = final | stream
%% Encoding = deflate    (gzip content)
%%          | no         (keep as is)
%%          | decide     (do as you like)
%% ContentLength = Int | undefined
%% Mode = final | stream
%%
%% For Mode==final: (all content has been accumulated before calling
%%                   deliver_accumulated)
%%     Ret: can be ignored
%%
%% For Mode==stream:
%%     Ret: opaque value to be threaded through 
%%                   send_streamcontent_chunk / end_streaming
deliver_accumulated(Arg, Sock, Encoding, ContentLength, Mode) ->
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
	    All = [StatusLine, Headers, crnl()],
	    Ret = discard;
	_ ->
	    SC = get(sc),
	    case decide_deflate(?sc_has_deflate(SC), 
				Arg, Cont, Encoding, Mode) of
		{data, Data} -> % implies Mode==final
		    yaws:outh_set_content_encoding(deflate),
		    Size = binary_size(Data),
		    Ret = ok;
		true -> % implies Mode==stream
		    yaws:outh_set_content_encoding(deflate),
		    Z = zlib:open(),
		    {ok, Priv, Data} = 
			yaws_zlib:gzipDeflate(Z, yaws_zlib:gzipInit(Z), 
					      to_binary(Cont), none),
		    Ret = {Z, Priv},
		    Size = undefined;
		false ->
		    Ret = undeflated,
		    Data = Cont,
		    Size = case Mode of
			       final ->
				   binary_size(Data);
			       stream ->
				   ContentLength
			   end
	    end,
	    case Size of 
		undefined -> 
		    yaws:outh_fix_doclose();
		_ -> yaws:accumulate_header({content_length, Size})
	    end,
	    {StatusLine, Headers} = yaws:outh_serialize(),
	    case make_chunk(Data) of
		empty ->
		    Chunk = [];
		{S, Chunk} ->
		    case Mode of
			stream -> yaws:outh_inc_act_contlen(S);
			_ -> ok
		    end
	    end,		    
	    All = [StatusLine, Headers, crnl(), Chunk]
    end,
    yaws:gen_tcp_send(Sock, All),
    GC=get(gc),
    if
	GC#gconf.trace == false ->
	    ok;
	GC#gconf.trace == {true, http} ->
	    yaws_log:trace_traffic(from_server, ["\n",StatusLine, Headers]);
	GC#gconf.trace == {true, traffic} ->
	    yaws_log:trace_traffic(from_server, ["\n",All])
    end,
    Ret.


get_more_post_data(PPS, ARG) ->
    SC = get(sc),
    N = SC#sconf.partial_post_size,
    Len = list_to_integer((ARG#arg.headers)#headers.content_length),
    if N + PPS < Len ->
	    case get_client_data(ARG#arg.clisock, N, 
			       is_ssl(SC#sconf.ssl)) of
		Bin when binary(Bin) ->
		    {partial, Bin};
		Else ->
		    {error, Else}
	    end;
       true ->
	    case get_client_data(ARG#arg.clisock, Len - PPS, 
			       is_ssl(SC#sconf.ssl)) of
		Bin when binary(Bin) ->
		    Bin;
		Else ->
		    {error, Else}
	    end
    end.


do_tcp_close(Sock) when port(Sock) ->
    gen_tcp:close(Sock);
do_tcp_close(Sock) ->
    ssl:close(Sock).



ut_open(UT) ->
    ?Debug("ut_open() UT.fullpath = ~p~n", [UT#urltype.fullpath]),
    case yaws:outh_get_content_encoding() of
	identity ->
	    case UT#urltype.data of
		undefined ->

		    ?Debug("ut_open reading\n",[]),
		    {ok, Bin} = file:read_file(UT#urltype.fullpath),
		    ?Debug("ut_open read ~p\n",[size(Bin)]),
		    {bin, Bin};
		B when binary(B) ->
		    {bin, B}
	    end;
	deflate -> 
	    case UT#urltype.deflate of
		B when binary(B) ->
		    ?Debug("ut_open using deflated binary of size ~p~n", 
			[size(B)]),
		    {bin, B}
	    end
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


deliver_file(CliSock, Req, UT, Range) ->
    if
	binary(UT#urltype.data) ->
	    %% cached
	    deliver_small_file(CliSock, Req, UT, Range);
	true ->
	    deliver_large_file(CliSock, Req, UT, Range)
    end.

deliver_small_file(CliSock, _Req, UT, Range) ->
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
    deliver_accumulated(CliSock),
    done_or_continue().
    
deliver_large_file(CliSock,  _Req, UT, Range) ->
    case deliver_accumulated(undefined, CliSock, 
			     case Range of
				all -> 
				     case yaws:outh_get_content_encoding() of
					identity -> no;
					D -> D
				     end;
				_ -> no
			     end, 
			     undefined, stream) of
	discard -> 
	    ok;
	Priv ->
	    {ok,Fd} = file:open(UT#urltype.fullpath, [raw, binary, read]),
	    send_file(CliSock, Fd, Range, Priv)
    end,
    done_or_continue().


send_file(CliSock, Fd, all, Priv) ->
    send_file(CliSock, Fd, Priv);
send_file(CliSock, Fd,  {fromto, From, To, _Tot}, undeflated) ->
    file:position(Fd, {bof, From}),
    send_file_range(CliSock, Fd, To - From + 1).


send_file(CliSock, Fd, Priv) ->
    ?Debug("send_file(~p,~p, ...)~n", 
	[CliSock, Fd]),
    case file:read(Fd, (get(gc))#gconf.large_file_chunk_size) of
	{ok, Bin} ->
	    Priv1 = send_streamcontent_chunk(Priv, CliSock, Bin),
	    send_file(CliSock, Fd, Priv1);
	eof ->
	    file:close(Fd),
	    end_streaming(Priv, CliSock)
    end.

send_file_range(CliSock, Fd, Len) when Len > 0 ->
    {ok, Bin} = file:read(Fd, 
			  case (get(gc))#gconf.large_file_chunk_size of
			      S when S < Len -> S;
			      _ -> Len
			  end
			 ),
    send_streamcontent_chunk(undeflated, CliSock, Bin),
    send_file_range(CliSock, Fd, Len - size(Bin));
send_file_range(CliSock, Fd, 0) ->
    file:close(Fd),
    end_streaming(undeflated, CliSock).
    




crnl() ->
    "\r\n".
crnl2() ->
    "\r\n\r\n".

now_secs() ->
    {M,S,_}=now(),
    (M*1000000)+S.


%% a file cache,
url_type(GetPath, ArgDocroot) ->
    SC=get(sc),
    GC=get(gc),
    E = SC#sconf.ets,
    case ets:lookup(E, {url, GetPath}) of
	[] ->
	    UT = do_url_type(SC, GetPath, ArgDocroot),
	    ?TC([{record, UT, urltype}]),
	    ?Debug("UT=~s\n", [?format_record(UT, urltype)]),
	    CF = cache_file(SC, GC, GetPath, UT),
	    ?Debug("CF=~s\n", [?format_record(CF, urltype)]),
	    CF;
	[{_, When, UT}] ->
	    N = now_secs(),
	    Refresh = GC#gconf.cache_refresh_secs,
	    if 
		((N-When) >= Refresh) ->
		    ?Debug("Timed out entry for ~s ~p~n", 
			[GetPath, {When, N}]),
		    %% more than 30 secs old entry
		    UT2 = do_url_type(SC, GetPath, ArgDocroot),
		    case file_changed(UT, UT2) of
			true ->
			    ?Debug("Recaching~n", []),
			    ets:delete(E, {url, GetPath}),
			    ets:delete(E, {urlc, GetPath}),
			    ets:update_counter(E, num_files, -1),
			    ets:update_counter(E, num_bytes, -cache_size(UT)),
			    cache_file(SC, GC, GetPath, UT2);
			false ->
			    ?Debug("Using unchanged cached version~n", []),
			    ets:update_counter(E, {urlc, GetPath}, 1),
			    UT
		    end;
		true ->
		    ?Debug("Serve page from cache ~p", [{When , N, N-When}]),
		    ets:update_counter(E, {urlc, GetPath}, 1),
		    UT
	    end
    end.


file_changed(UT1, UT2) ->
    case {UT1#urltype.type, UT2#urltype.type} of
	{T, T} when T==yaws; T==regular->
	    F1 = UT1#urltype.finfo,
	    F2 = UT2#urltype.finfo,
	    {F1#file_info.inode, F1#file_info.mtime} 
		/= {F2#file_info.inode, F2#file_info.mtime};
	_ ->
	    true % don't care too much
    end.
	
	    

cache_size(UT) when binary(UT#urltype.deflate), 
		    binary(UT#urltype.data) ->
    size(UT#urltype.deflate) + size(UT#urltype.data);
cache_size(UT) when binary(UT#urltype.data) ->
    size(UT#urltype.data);
cache_size(_UT) ->
    0.




cache_file(SC, GC, Path, UT) when 
  UT#urltype.type == regular ;
  UT#urltype.type == yaws,
  UT#urltype.pathinfo == undefined ->
    E = SC#sconf.ets,
    [{num_files, N}] = ets:lookup(E, num_files),
    [{num_bytes, B}] = ets:lookup(E, num_bytes),
    FI = UT#urltype.finfo,
    ?Debug("FI=~s\n", [?format_record(FI, file_info)]),
    if
	N + 1 > GC#gconf.max_num_cached_files ->
	    error_logger:info_msg("Max NUM cached files reached for server "
				  "~p", [SC#sconf.servername]),
	    cleanup_cache(E, num),
	    cache_file(SC, GC, Path, UT);
	FI#file_info.size < GC#gconf.max_size_cached_file,
	B + FI#file_info.size > GC#gconf.max_num_cached_bytes ->
	    error_logger:info_msg("Max size cached bytes reached for server "
				  "~p", [SC#sconf.servername]),
	    cleanup_cache(E, size),
	    cache_file(SC, GC, Path, UT);
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
		    Deflated = 
			case ?sc_has_deflate(SC)
			    and (UT#urltype.type==regular) of
			    true ->
				case yaws_zlib:gzip(Bin) of
				    {ok, DB} when binary(DB), 
						  size(DB)*10<size(Bin)*9 ->
					?Debug("storing deflated version "
					    "of ~p~n",
					[UT#urltype.fullpath]),
					DB;
				    _ -> undefined
				end;
			    false -> undefined
			end,
		    UT2 = UT#urltype{data = Bin, 
				     deflate = Deflated},
		    ets:insert(E, {{url, Path}, now_secs(), UT2}),
		    ets:insert(E, {{urlc, Path}, 1}),
		    ets:update_counter(E, num_files, 1),
		    ets:update_counter(E, num_bytes, 
				       cache_size(UT2)),
		    UT2
	    end
    end;
cache_file(_SC, _GC, _Path, UT) ->
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



%% Clear everything, but *not* the Yaws specs, because otherwise we
%% would have orphan modules loaded.
clear_ets(E) ->
    ets:match_delete(E, {{url, '_'}, '_', '_'}),
    ets:match_delete(E, {{urlc, '_'}, '_', '_'}),
    ets:insert(E, {num_files, 0}),
    ets:insert(E, {num_bytes, 0}).
    

%% return #urltype{}
do_url_type(SC, GetPath, ArgDocroot) ->
    ?Debug("do_url_type SC=~s~nGetPath=~p~n", 
	   [?format_record(SC,sconf), GetPath]),
    case GetPath of
	_ when ?sc_has_dav(SC) ->
	    {Comps, RevFile} = split(GetPath, [], []),
	    {_Type, Mime} = suffix_type(RevFile),
	    DR = ArgDocroot,
	    FullPath = [DR, GetPath],
	    #urltype{type = dav, 
		     dir = Comps,
		     getpath = GetPath,
		     path = GetPath,
		     fullpath = FullPath,
		     mime = Mime};
	"/" -> %% special case 
	    case lists:keysearch("/", 1, SC#sconf.appmods) of
		{value, {_, Mod}} ->
		    #urltype{type = appmod, 
			     data = {Mod, []}};
		_ ->
		    maybe_return_dir(ArgDocroot, GetPath)
	    end;
	[$/, $~ |Tail] ->
	    ret_user_dir(Tail);
	_ ->
	    {Comps, RevFile} = split(GetPath, [], []),
	    ?Debug("Comps = ~p RevFile = ~p~n",[Comps, RevFile]),

	    case check_appmods(SC#sconf.appmods, Comps, RevFile) of
		false ->
		    DR = ArgDocroot,
		    FullPath = [DR, GetPath],
		    ?Debug("FullPath = ~p~n", [FullPath]),
		    case prim_file:read_file_info(FullPath) of
			{ok, FI} when FI#file_info.type == regular ->
			    {Type, Mime} = suffix_type(SC, RevFile),
			    #urltype{type=Type, 
				     finfo=FI,
				     deflate=deflate_q(?sc_has_deflate(SC), 
						       Type, Mime),
				     dir = Comps,
				     path = GetPath,
				     getpath = GetPath,
				     fullpath = FullPath,
				     mime=Mime};
			{ok, FI} when FI#file_info.type == directory ->
			    case RevFile of
				[] ->
				    %% dir urls without trailing /
				    maybe_return_dir(DR, GetPath);
				_ ->
				    #urltype{type = redir,
					     path = [GetPath, "/"]}
			    end;
			_Err ->
			    %% non-optimal, on purpose
			    maybe_return_path_info(SC, Comps, RevFile)
		    end;
		{ok, Head, {PathElem, Mod}, Trail} ->
		    File = lists:reverse(RevFile),
		    ?Debug("PathElem = ~p Trail = ~p File = ~p~n", 
			   [PathElem, Trail, File]),
		    #urltype{type = appmod, 
			     data = {Mod, if
					      Trail==[], PathElem == File ->
						  [];
					      hd(File) == $/, 
					      PathElem == tl(File) ->
						  [];
					      true ->
						  case conc_path(Trail) ++ File of
						      X when hd(X) == $/ ->
							  X;
						      X ->
							  X
						  end
					  end},
			     path = conc_path(Head)}
	    
	    end
    end.
			    

split([$/|Tail], Comps, Part) when Part /= [] ->
    NewComp = lists:reverse([$/|Part]),
    split(Tail,  [NewComp | Comps], []);
split([H|T], Comps, Part)  ->
    split(T, Comps, [H|Part]);
split([], Comps, Part) ->
    {lists:reverse(Comps), Part}.


check_appmods([], _, _) ->
    false;
check_appmods(AppMods, Comps, RevFile) ->
    case check_comps(AppMods, Comps) of
	false ->
	    %% check last elem last
	    File = lists:reverse(RevFile),
	    case check_comps(AppMods, [File]) of
		false ->
		    false;
		{ok, _, AM, _} ->
		    {ok, Comps, AM,[]}
	    end;
	RET ->
	    RET
    end.
			      


check_comps([], _) ->
    false;
check_comps([Pair |Tail], Comps) ->
    case split_at(Pair, Comps,[]) of
	false ->
	    check_comps(Tail, Comps);
	RET ->
	    RET
    end.
    
				      
split_at(_, [], _Ack) ->
    false;
split_at(AM={"/", _Mod}, [PEslash|Tail], Ack) ->
    {ok, lists:reverse(Ack), AM, [PEslash|Tail]};
split_at(AM={PE, _Mod}, [PEslash|Tail], Ack) ->
    ?Debug("AM=~p PEslash=~p~n", [AM, PEslash]),
    case no_slash_eq(PE, PEslash) of
	true ->
	    {ok, lists:reverse(Ack), AM, Tail};
	false ->
	    split_at(AM, Tail, [PEslash|Ack])
    end.


%% ignore slashes in the comparision
no_slash_eq([H1|T1], [H1|T2]) ->
    no_slash_eq(T1, T2);
no_slash_eq(X, [$/|T]) ->
    no_slash_eq(X,T);
no_slash_eq([],[]) ->
    true;
no_slash_eq(_,_) ->
    false.


try_index_file(DR, GetPath) ->
     case prim_file:read_file_info([DR, GetPath, "index.yaws"]) of
	{ok, FI} when FI#file_info.type == regular ->
	    do_url_type(get(sc), GetPath ++ "index.yaws", DR);
	_ ->
	    case prim_file:read_file_info([DR, GetPath, "index.html"]) of
		{ok, FI} when FI#file_info.type == regular ->
		    do_url_type(get(sc), GetPath ++ "index.html", DR);
		_ ->
		    case prim_file:read_file_info([DR, GetPath,"index.php"]) of
			{ok, FI} when FI#file_info.type == regular ->
			    do_url_type(get(sc), GetPath ++ "index.php", DR);
			_ ->
			    noindex
		    end
	    end
     end.
		

maybe_return_dir(DR, GetPath) ->
    case try_index_file(DR, GetPath) of
	noindex ->
	    case file:list_dir([DR, GetPath]) of
		{ok, List} ->
		    #urltype{type = directory,
			     dir = [DR , GetPath],
			     data = List -- [".yaws_auth"]};
		_Err ->
		    #urltype{type=error}
	    end;
	UT ->
	    UT
    end.




% sick apache style urls http://www.x.com/a/foo.yaws/c/d/
% where /c/d/ ends up in pathinfo

% neither is this entirely correct since the /c/d/ files may exists
% and in that case we'll deliver em :-(

% Comment from Carsten:
%
% Theses urls may be a matter of taste, but since they are mentioned in
% cgi doc it seemed good to implement them.  Besides, I find them handy.
%
% If the current behaviour is correct is hard to tell without first
% writing a specification :-) To treat foo.yaws as a directory if it
% is one, was intentional.  I find it nice to be able to change the
% implementation from a script to a real directory and did not want to
% break anyones site, just because they might have a directory called
% `examples.yaws'.  There is one inconsistency though:
%
%   http://www.x.com/a/foo.yaws/b/bar.yaws/c/d
%
% will not work, if a/foo.yaws is a directory and
% /a/foo.yaws/b/bar.yaws a script.  Possibly, this used to be
% different and may again be changed in the future.

maybe_return_path_info(SC, Comps, RevFile) ->
    case path_info_split(Comps,[]) of
	{false, Type} ->
	     #urltype{type=Type};
	{ok, HeadComps, File, TrailComps, Type, Mime} ->
	    DR = SC#sconf.docroot,
	    {Type2, Mime2} = 
		case member(Type, SC#sconf.allowed_scripts) of
		    true ->
			{Type, Mime};
		    false ->
			{regular, "text/plain"}
		end,

	    FullPath = [DR, HeadComps, $/, File],
	    ?Debug("FullPath = ~p~n", [FullPath]),
	    case prim_file:read_file_info(FullPath) of
		{ok, FI} when FI#file_info.type == regular ->
		    Trail = [$/ | conc_path(TrailComps ++ 
					    [lists:reverse(RevFile)])],
		    #urltype{type = Type2,
			     finfo=FI,
			     deflate=deflate_q(?sc_has_deflate(SC), 
					       Type, Mime),
			     dir = HeadComps,
			     path = [HeadComps, $/, File],
			     fullpath = FullPath,
			     pathinfo = Trail,
			     getpath = case HeadComps of
					   [] -> [$/|File];
					   [_|_] ->
					       conc_path(
						 HeadComps++[File])
				       end,
			     mime = Mime2};
		_ ->
		    #urltype{type = error}
	    end
    end.


path_info_split([H|T], Ack) ->
    [$/|RevPath] = lists:reverse(H),
    case suffix_from_rev(RevPath) of
	[] ->   % shortcut clause, not necessary
	    path_info_split(T, [H|Ack]);
	Suff ->
	    {Type, Mime} = mime_types:t(Suff),
	    case Type of
		regular ->
		    path_info_split(T, [H|Ack]);
		X ->
		    {ok, lists:reverse(Ack), yaws:delall($/, H), T, X, Mime}
	    end
    end;
path_info_split([], _Ack) ->
    {false, error}.


suffix_from_rev(R) ->
    suffix_from_rev(R, []).

suffix_from_rev([$.|_], A) ->
    A;
suffix_from_rev([C|T], A) ->
    suffix_from_rev(T, [C|A]);
suffix_from_rev([], _A) ->
    [].



conc_path([]) ->
    [];
conc_path([H|T]) ->
    H ++ conc_path(T).



ret_app_mod(Path, Mod, PrePath) ->
    #urltype{type = appmod,
	     data = {Mod, Path},
	     path = PrePath}.



%% http://a.b.c/~user URLs
ret_user_dir(Upath)  ->
    ?Debug("ret_user_dir ~p~n", [Upath]),
    SC = get(sc),
    if ?sc_has_tilde_expand(SC) ->
	    case parse_user_path(SC#sconf.docroot, Upath, []) of
		{ok, User, Path} ->
		    %% FIXME doesn't work if passwd contains :: 
		    %% also this is unix only
		    %% and it ain't the fastest code around.
		    case catch yaws:user_to_home(User) of
			{'EXIT', _} ->
			    #urltype{type=error};
			Home ->
			    DR2 = Home ++ "/public_html/",
			    SC2 = SC#sconf{
				    allowed_scripts = [],
				    docroot=DR2},
			    put(sc, SC2),
			    redir_user(do_url_type(SC2, Path, DR2), User)%% recurse
		    end;
		{redir_dir, User} ->
		    #urltype {type = redir,
			      path = ["/~", User, "/"]}
	    end;
       true ->
	    #urltype{type=error}
    end.


redir_user(UT, User) ->
    case UT#urltype.type of
	redir ->
	    UT#urltype{path = ["/~", User, UT#urltype.path]};
	_ ->
	    UT
    end.




parse_user_path(_DR, [], User) ->
    {redir_dir, reverse(User)};
parse_user_path(_DR, [$/], User) ->
    {ok, reverse(User), [$/]};
parse_user_path(_DR, [$/|Tail], User) ->
    {ok, reverse(User), [$/|Tail]};
parse_user_path(DR, [H|T], User) ->
    parse_user_path(DR, T, [H|User]).


deflate_q(true, regular, Mime) ->
    case compressible_mime_type(Mime) of
	true -> dynamic;
	false -> undefined
    end;
deflate_q(_, _, _) ->
    undefined.


suffix_type(SC, L) ->
    R=suffix_type(L),
    case R of
	{regular, _} ->
	    R;
	{X, _Mime} -> 
	    case member(X, SC#sconf.allowed_scripts) of
		true -> R;
		false -> {regular, "text/plain"}
	    end
    end.

suffix_type(L) ->
    L2 = yaws:upto_char($., L),
    mime_types:revt(L2).

		     

%% Some silly heuristics.

compressible_mime_type("text/"++_) ->
    true;
compressible_mime_type("application/rtf") ->
    true;
compressible_mime_type("application/msword") ->
    true;
compressible_mime_type("application/postscript") ->
    true;
compressible_mime_type("application/pdf") ->
    true;
compressible_mime_type("application/x-dvi") ->
    true;
compressible_mime_type(_) ->
    false.


flush(Sock, Sz) ->
    case (get(sc))#sconf.ssl of
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
ssl_flush(Sock, Sz) when list(Sz) ->
    ssl_flush(Sock, strip_list_to_integer(Sz));
ssl_flush(Sock, Sz) ->
    case ssl:recv(Sock, Sz, 1000) of
	{ok, Bin} ->
	    ssl_flush(Sock, Sz - size(Bin));
	_ ->
	    ok
    end.

mtime(F) ->
    F#file_info.mtime.

runmod({ok, Mod}, GC) ->
    runmod2(GC, [Mod | GC#gconf.runmods]);
runmod(_, GC) ->
    runmod2(GC, GC#gconf.runmods).

runmod2(GC, Mods) ->
    foreach(fun(M) -> 
		    proc_lib:spawn(?MODULE, load_and_run, 
				   [M, ?gc_has_debug(GC)])
	    end, Mods).



load_and_run(Mod, Debug) ->
    case code:ensure_loaded(Mod) of
	{module,Mod} when Debug == false ->
	    Mod:start();
	{module,Mod} when Debug == true  ->
	    error_logger:info_msg("sync call ~p:start ~n",[Mod]),
	    Mod:start();
	Error ->
	    error_logger:error_msg("Loading '~w' failed, reason ~p~n",
				   [Mod,Error])
    end.


safe_ehtml_expand(X) ->
    case (catch ehtml_expand(X)) of
	{'EXIT', R} ->
	    {error, err_pre(R)};
	Val ->
	    {ok, Val}
    end.

err_pre(R) ->
    io_lib:format("<pre> ~n~p~n </pre>~n", [R]).
