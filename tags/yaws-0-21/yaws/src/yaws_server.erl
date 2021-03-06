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
-include("yaws.hrl").
-include_lib("kernel/include/file.hrl").

%% External exports
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-import(filename, [join/1]).
-import(lists, [foreach/2, map/2, flatten/1, flatmap/2]).


-record(gs, {gconf,
	     group,         %% list of #sconf{} s
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
    S = status(),
    {GC, Srvs, _} = S,
    flatmap(
      fun({Pid, SCS}) ->
	      map(
		fun(SC) ->
			
			E = SC#sconf.ets,
			L = ets:match(E, {{urlc_total, '$1'}, '$2'}),
			{SC#sconf.servername,  
			 flatten(yaws:fmt_ip(SC#sconf.listen)),
			 lists:keysort(2,map(fun(P) -> list_to_tuple(P) end, L))}
		end, SCS)
      end, Srvs).

			      

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%----------------------------------------------------------------------
init([]) ->
    case yaws_config:load() of
	{ok, Gconf, Sconfs} ->
	    erase(logdir),
	    ?Debug("Conf = ~p~n", [?format_record(Gconf, gconf)]),
	    
	    yaws_log:setdir(Gconf#gconf.logdir),
	    init2(Gconf, Sconfs);
	{error, E} ->
	    case erase(logdir) of
		undefined ->
		    error_logger:format("Bad conf: ~p", [E]),
		    {stop, E};
		Dir ->
		    yaws_log:setdir(Dir),
		    yaws_log:sync_errlog("bad conf: ~s",[E]),
		    {stop, E}
	    end
    end.


init2(Gconf, Sconfs) ->
    lists:foreach(
      fun(D) ->
	      code:add_pathz(D)
      end, Gconf#gconf.ebin_dir),

    process_flag(trap_exit, true),

    %% start the individual server processes
    L = lists:map(
	  fun(Group) ->
		  proc_lib:start_link(?MODULE, gserv, [Gconf, Group])
	  end, Sconfs),
    L2 = lists:zf(fun({error, F, A}) ->
			  yaws_log:sync_errlog(F, A),
			  false;
		     ({Pid, SCs}) ->
			  true
		  end, L),
    if
	length(L) == length(L2) ->
	    {ok, {Gconf, L2, 0}};
	true ->
	    {stop, "failed to start server "}
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
handle_call(status, From, State) ->
    Reply = State,
    {reply, Reply, State};
handle_call(mnum, From, {GC, Group, Mnum}) ->
    {reply, Mnum+1,   {GC, Group, Mnum+1}}.




%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast(Msg, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------

handle_info(Msg, State) ->
    ?Debug("GOT ~p~n", [Msg]),
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(Reason, State) ->
    ok.


			  



%% One server per IP we listen to
gserv(GC, Group0) ->
    ?TC([{record, GC, gconf}]),
    Group = map(fun(SC) -> 
			E = ets:new(yaws_code, [public, set]),
			ets:insert(E, {num_files, 0}),
			ets:insert(E, {num_bytes, 0}),
			SC#sconf{ets = E}
		end, Group0),
    SC = hd(Group),
    case gen_tcp:listen(SC#sconf.port, opts(SC)) of
	{ok, Listen} ->
	    ?Debug("XX",[]),
	    error_logger:info_msg("Listening to ~s:~w for servers ~p~n",
			      [yaws:fmt_ip(SC#sconf.listen),
			       SC#sconf.port,
			       catch map(fun(S) -> S#sconf.servername end, Group)]),
	    ?Debug("XX",[]),
	    file:make_dir("/tmp/yaws"),
	    {ok, Files} = file:list_dir("/tmp/yaws"),
	    lists:foreach(
	      fun(F) -> file:delete("/tmp/yaws/" ++ F) end, Files),
	    proc_lib:init_ack({self(), Group}),
	    GS = #gs{gconf = GC,
		     group = Group,
		     l = Listen},
	    acceptor(GS),
	    gserv(GS, [], 0);
	Err ->
	    error_logger:format("Failed to listen ~s:~w  : ~p~n",
				[yaws:format_ip(SC#sconf.listen),
				 SC#sconf.port, Err]),
	    proc_lib:init_ack({error, "Can't listen to socket: ~p ",[Err]}),
	    exit(normal)
    end.
			

gserv(GS, Ready, Rnum) ->
    receive
	{From , status} ->
	    From ! {self(), GS},
	    gserv(GS, Ready, Rnum);
	{From, next} when Ready == [] ->
	    acceptor(GS),
	    gserv(GS, Ready, Rnum);
	{From, next} ->
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
	    end
    end.
	    


opts(SC) ->
    [binary, 
     {ip, SC#sconf.listen},
     {packet, http},
     {reuseaddr, true},
     {active, false}
    ].

acceptor(GS) ->
    proc_lib:spawn_link(yaws_server, acceptor0, [GS, self()]).
acceptor0(GS, Top) ->
    ?TC([{record, GS, gs}]),
    L = GS#gs.l,
    X = gen_tcp:accept(L),
    ?Debug("Accept ret:~p L=~p~n", [X,L]),
    Top ! {self(), next},
    case X of
	{ok, Client} ->
	    Res = (catch aloop(Client, GS,  0)),
	    gen_tcp:close(Client),
	    ?Debug("RES = ~p~n", [Res]),
	    case Res of
		{ok, Int} when integer(Int) ->
		    Top ! {self(), done_client, Int};
		Other ->
		    Top ! {self(), done_client, 0}
	    end,
	    %% we cache processes
	    receive
		{Top, stop} ->
		    exit(normal);
		{Top, accept} ->
		    acceptor0(GS, Top)
	    end;
	_ ->
	    exit(normal)
    end.
     


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

aloop(CliSock, GS, Num) ->
    ?TC([{record, GS, gs}]),
    case get_headers(CliSock, GS#gs.gconf) of
	done ->
	    {ok, Num};
	{Req, H} ->
	    Sconf = pick_sconf(H, GS#gs.group),
	    ?Debug("Sconf: ~p", [?format_record(Sconf, sconf)]),
	    ?TC([{record, Sconf, sconf}]),
	    Res = apply(yaws_server, Req#http_request.method, 
			[CliSock, GS#gs.gconf, Sconf, Req, H]),
	    maybe_access_log(CliSock, Sconf, Req),
	    case Res of
		continue ->
		    aloop(CliSock, GS, Num+1);
		done ->
		    {ok, Num+1}
	    end
    end.


pick_sconf(H, Group) ->
    case H#headers.host of
	undefined ->
	    pick_default(Group);
	Host ->
	    pick_host(Host, Group, Group)
    end.

pick_default([]) ->
    yaws_log:errlog("No default host found in server group ",[]),
    exit(normal);
pick_default([H|T]) when H#sconf.default_server_on_this_ip == true ->
    H;
pick_default([_|T]) ->
    pick_default(T).


pick_host(Host, [H|T], Group) when H#sconf.servername == Host ->
    H;
pick_host(Host, [_|T], Group) ->
    pick_host(Host, T, Group);
pick_host(Host, [], Group) ->
    pick_default(Group).






maybe_access_log(CliSock, SC, Req) ->
    ?TC([{record, SC, sconf}]),
    case SC#sconf.access_log of
	true ->
	    {ok, {Ip, Port}} = inet:sockname(CliSock),
	    Status = case erase(status_code) of
			 undefined -> "-";
			 I -> integer_to_list(I)
		     end,
	    Len = case erase(content_length) of
		      undefined ->
			  "-";
		      I2 -> integer_to_list(I2)
		  end,
	    Path = get_path(Req#http_request.path),
	    Meth = atom_to_list(Req#http_request.method),
	    yaws_log:accesslog(Ip, [Meth, $\s, Path] , Status, Len);
	false ->
	    ignore
    end.


get_path({abs_path, Path}) ->
    Path.

get_headers(CliSock, GC) ->
    ?TC([{record, GC, gconf}]),
    inet:setopts(CliSock, [{packet, http}]),
    case gen_tcp:recv(CliSock, 0, GC#gconf.keepalive_timeout) of
	{ok, R} when element(1, R) == http_request ->
	    H = get_headers(CliSock, R, GC, #headers{}),
	    {R, H};
	{error, timeout} ->
	    done;
	Err ->
	    ?Debug("Got ~p~n", [Err]),
	    exit(normal)
    end.

get_headers(CliSock, Req, GC, H) ->
    ?TC([{record, GC, gconf}]),
    case gen_tcp:recv(CliSock, 0, GC#gconf.timeout) of
	{ok, {http_header,  Num, 'Host', _, Host}} ->
	    get_headers(CliSock, Req, GC, H#headers{host = Host});
	{ok, {http_header, Num, 'Connection', _, Conn}} ->
	    get_headers(CliSock, Req, GC, H#headers{connection = Conn});
	{ok, {http_header, Num, 'Accept', _, Accept}} ->
	    get_headers(CliSock, Req, GC, H#headers{accept = Accept});
	{ok, {http_header, Num, 'If-Modified-Since', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{if_modified_since = X});
	{ok, {http_header, Num, 'If-Match', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{if_match = X});
	{ok, {http_header, Num, 'If-None-Match', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{if_none_match = X});
	{ok, {http_header, Num, 'If-Range', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{if_range = X});
	{ok, {http_header, Num, 'If-Unmodified-Since', _, X}} ->
	    get_headers(CliSock, Req, GC, 
			H#headers{if_unmodified_since = X});
	{ok, {http_header, Num, 'Range', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{range = X});
	{ok, {http_header, Num, 'Referer',_, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{referer = X});
	{ok, {http_header, Num, 'User-Agent', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{user_agent = X});
	{ok, {http_header, Num, 'Accept-Ranges', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{accept_ranges = X});
	{ok, {http_header, Num, 'Cookie', _, X}} ->
	    get_headers(CliSock, Req, GC, 
			H#headers{cookie = [X|H#headers.cookie]});
	{ok, {http_header, Num, 'Keep-Alive', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{keep_alive = X});
	{ok, {http_header, Num, 'Content-Length', _, X}} ->
	    get_headers(CliSock, Req, GC, H#headers{content_length = X});
	{ok, http_eoh} ->
	    H;
	{ok, _} ->
	    get_headers(CliSock, Req, GC, H);
	Err ->
	    exit(normal)
    
    end.


%% ret:  continue | done
'GET'(CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    ?Debug("GET ~p", [Req#http_request.path]),
    ok = inet:setopts(CliSock, [{packet, raw}, binary]),
    flush(CliSock, Head#headers.content_length),
    ARG = make_arg(CliSock, Head, Req, GC, SC),
    handle_request(CliSock, GC, SC, Req, Head, ARG).


'POST'(CliSock, GC, SC, Req, Head) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    ?Debug("POST Req=~p H=~p~n", [?format_record(Req, http_request),
				  ?format_record(Head, headers)]),
    ok = inet:setopts(CliSock, [{packet, raw}, binary]),
    Bin = case Head#headers.content_length of
	undefined ->
	    case Head#headers.connection of
		"close" ->
		    get_client_data(CliSock, all);
		_ ->
		    exit(normal)
	    end;
	Len ->
	    get_client_data(CliSock, list_to_integer(Len))
    end,
    ?Debug("POST data = ~s~n", [binary_to_list(Bin)]),
    ARG = make_arg(CliSock, Head, Req, GC, SC),
    ARG2 = ARG#arg{clidata = Bin},
    handle_request(CliSock, GC, SC, Req, Head, ARG2).
    

make_arg(CliSock, Head, Req, GC, SC) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    #arg{clisock = CliSock,
	 h = Head,
	 req = Req,
	 docroot = SC#sconf.docroot}.



-record(urltype, {type,   %% error | yaws | regular | directory | dotdot
		  finfo,
		  path,
		  fullpath,
		  data,    %% Binary | FileDescriptor | DirListing | undefined
		  mime,    %% MIME type
		  q        %% query for GET requests
		 }).


handle_request(CliSock, GC, SC, Req, H, ARG) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    UT =  url_type(GC, SC,P=get_path(Req#http_request.path)),
    case UT#urltype.type of
	error ->
	    deliver_404(CliSock, GC, SC, Req);
	directory ->
	    yaws_ls:list_directory(CliSock, UT#urltype.data, P, GC, SC);
	regular -> 
	    deliver_file(CliSock, GC, SC, Req, H, UT);
	yaws ->
	    do_yaws(CliSock, GC, SC, Req, H, 
		    ARG#arg{querydata = UT#urltype.q}, UT);
	dotdot ->
	    deliver_403(CliSock, Req)
    end.

	


deliver_403(CliSock, Req) ->
    H = make_date_and_server_headers(),
    B = list_to_binary("<html> <h1> 403 Forbidden, no .. paths "
		       "allowed  </h1></html>"),
    D = [make_400(403), H, make_connection_close(true),
	 make_content_length(size(B)), crnl(), B],
    safe_send(true, CliSock, D),
    done.

deliver_404(CliSock, GC, SC,  Req) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    H = make_date_and_server_headers(),
    B = not_found_body(get_path(Req#http_request.path), GC, SC),
    D = [make_400(404), H, make_connection_close(true),
	 make_content_length(size(B)), crnl(), B],
    safe_send(true, CliSock, D),
    done.


do_yaws(CliSock, GC, SC, Req, H, ARG, UT) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    FileAtom = list_to_atom(UT#urltype.fullpath),
    Mtime = mtime(UT#urltype.finfo),
    case ets:lookup(SC#sconf.ets, FileAtom) of
	[{FileAtom, Mtime1, Spec}] when Mtime1 == Mtime ->
	    deliver_dyn_file(CliSock, GC, SC, Req, H, Spec, ARG,UT);
	Other  ->
	    del_old_files(Other),
	    {ok, Spec} = compile_file(UT#urltype.fullpath, GC, SC),
	    ?Debug("Spec for file ~s is:~n~p~n",[UT#urltype.fullpath, Spec]),
	    ets:insert(SC#sconf.ets, {FileAtom, Mtime, Spec}),
	    deliver_dyn_file(CliSock, GC, SC, Req, H, Spec, ARG, UT)
    end.


del_old_files([]) ->
    ok;
del_old_files([{FileAtom, Mtime1, Spec}]) ->
    lists:foreach(
      fun({mod, _, _, _,  Mod, Func}) ->
	      F="/tmp/yaws/" ++ yaws:to_list(Mod) ++ ".erl",
	      file:delete(F);
	 (_) ->
	      ok
      end, Spec).
		     

get_client_data(CliSock, all) ->
    get_client_data(CliSock, all, gen_tcp:recv(CliSock, 4000));
get_client_data(CliSock, Len) ->
    case gen_tcp:recv(CliSock, Len) of
	{ok, B} when size(B) == Len ->
	    B;
	_ ->
	    exit(normal)
    end.

get_client_data(CliSock, all, {ok, B}) ->
    B2 = get_client_data(CliSock, all, gen_tcp:recv(CliSock, 4000)),
    <<B/binary, B2/binary>>;
get_client_data(CliSock, all, eof) ->
    <<>>.


do_dyn_headers(CliSock, GC, SC, Req, Head, [H|T], ARG) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    {DoClose, Chunked} = case Req#http_request.version of
			     {1, 0} -> {true, []};
			     {1, 1} -> {false, make_chunked()}
			 end,
    case H of
	{mod, LineNo, YawsFile, SkipChars, Mod, some_headers} ->
	    MimeType = "text/html",
	    OutH = make_dyn_headers(DoClose, MimeType),
	    case (catch apply(Mod, some_headers, [ARG])) of
		{ok, Out} ->
		    {[make_200(),OutH, Chunked, Out, crnl()], T, DoClose};
		close ->
		    exit(normal);
		Err ->
		    {[make_200(), OutH, crnl(),
		      ?F("<p> yaws code ~w:~w(~p) crashed:"
			 " ~n~p~n", 
			 [Mod, some_headers, [Head], Err])], T, DoClose}
	    end;
	{mod, LineNo, YawsFile, SkipChars, Mod, all_headers} ->
	    case (catch apply(Mod, all_headers, [ARG])) of
		{ok, StatusCode, Out} when integer(StatusCode) ->
		    put(status_code, StatusCode),
		    {[Out, crnl()], T, DoClose};
		close ->
		    exit(normal);
		Err ->
		    MimeType = "text/html",
		    OutH = make_dyn_headers(DoClose, MimeType),
		    {[make_200(), OutH, crnl(),
		      ?F("<p> yaws code ~w:~w(~p) crashed:"
			 " ~n~p~n", 
			 [Mod, all_headers, [Head], Err])], T,  DoClose}
	    end;
	_ ->
	    MimeType = "text/html",
	    OutH = make_dyn_headers(DoClose, MimeType),
	    {[make_200(),OutH, Chunked, crnl()], [H|T], DoClose}
    end.


	   

%% do the header and continue
deliver_dyn_file(CliSock, GC, SC, Req, Head, Specs, ARG, UT) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    Fd = ut_open(UT),
    Bin = ut_read(Fd),
    {S2, Tail, DoClose} = do_dyn_headers(CliSock,GC, SC,Req,Head,Specs,ARG),
    safe_send(true, CliSock, S2),
    deliver_dyn_file(CliSock, GC, SC, Req, Head, UT,
		     DoClose, Bin, Fd, Specs, ARG).



deliver_dyn_file(CliSock, GC, SC, Req, Head, UT, DC, Bin, Fd, [H|T],ARG) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}, {record, UT,urltype}]),
    ?Debug("deliver_dyn_file: ~p~n", [H]),
    case H of
	{mod, LineNo, YawsFile, NumChars, Mod, out} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    safe_call(DC, LineNo, YawsFile, CliSock, Mod, out, [ARG]),
	    deliver_dyn_file(CliSock, GC, SC, Req, Head, UT, DC,
			     Bin2,Fd,T,ARG);
	{data, NumChars} ->
	    {Send, Bin2} = skip_data(Bin, Fd, NumChars),
	    safe_send(DC, CliSock, Send),
	    deliver_dyn_file(CliSock, GC, SC, Req, Bin2,
			     UT, DC, Bin2, Fd, T,ARG);
	{error, NumChars, Str} ->
	    {_, Bin2} = skip_data(Bin, Fd, NumChars),
	    safe_send(DC, CliSock, Str),
	    deliver_dyn_file(CliSock, GC, SC, Req, Bin2,
			     UT, DC, Bin2, Fd, T,ARG)
    end;
deliver_dyn_file(CliSock, GC, SC, Req, Head, UT, DC, Bin, Fd, [],ARG) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    ?Debug("deliver_dyn: done~n", []),
    case DC of
	true ->
	    done;
	false ->
	    tcp_send(CliSock, ["0", crnl(), crnl()]),
	    continue
    end.


%% what about trailers ??

skip_data(List, Fd, Sz) when list(List) ->
    skip_data(list_to_binary(List), Fd, Sz);
skip_data(Bin, Fd, Sz) when binary(Bin) ->
    ?Debug("Skip data ~p bytes ", [Sz]),
     case  Bin of
	 <<Head:Sz/binary ,Tail/binary>> ->
	     {Head, Tail};
	 _ ->
	     case file:read(Fd, 4000) of
		 {ok, Bin2} -> 
		     Bin3 = <<Bin/binary, Bin2/binary>>,
		     skip_data(Bin3, Fd, Sz);
		 Err ->
		     ?Debug("EXIT in skip_data: ~p  ~p~n", [Bin, Sz]),
		     exit(normal)
	     end
     end;
skip_data({bin, Bin}, _, Sz) ->
    <<Head:Sz/binary ,Tail/binary>> = Bin,
    {Head, {bin, Tail}}.



to_binary(B) when binary(B) ->
    B;
to_binary(L) when list(L) ->
    list_to_binary(L).

safe_send(DoClose, Sock, Data) ->
    ?Debug("safe send ~p bytes ", [size(to_binary([Data]))]),
    if
	DoClose == true  ->
	    case tcp_send(Sock, Data) of
		ok ->
		    ok;
		Err ->
		    ?Debug("fail to send: ~p~n", [Err]),
		    exit(normal)
	    end;
	DoClose == false ->
	    B = to_binary(Data),
	    Len = size(B),
	    Data2 = [yaws:integer_to_hex(Len) , crnl(), B],
	    case tcp_send(Sock, Data2) of
		ok ->
		    ok;
		Err ->
		    ?Debug("fail to send: ~p~n", [Err]),
		    exit(normal)
	    end
    end.

		    
safe_call(DoClose, LineNo, YawsFile, CliSock, M, F, A) ->
    ?Debug("safe_call ~w:~w(~p)~n", 
	   [M, F, ?format_record(hd(A), arg)]),
    case (catch apply(M,F,A)) of
	{'EXIT', Err} ->
	    safe_send(DoClose, CliSock, 
		      ?F("~n<pre> ~nERROR erl ~w/1 code  crashed:~n "
			 "File: ~s:~w~n"
			 "Reason: ~p~n</pre>~n",
			 [F, YawsFile, LineNo, Err])),
	    yaws:elog("erl code  ~w/1 crashed: ~n"
		      "File: ~s:~w~n"
		      "Reason: ~p", [F, YawsFile, LineNo, Err]);
	
	{ok, Out} ->
	    safe_send(DoClose, CliSock, Out);
	Other ->
	    safe_send(DoClose, CliSock, 
		      ?F("~n<pre>~nERROR erl code ~w/1 returned bad value: ~n "
			 "File: ~s:~w~n"
			 "Value: ~p~n</pre>~n",
			 [F, YawsFile, LineNo, Other])),
	    yaws:elog("erl code  ~w/1 returned bad value: ~n"
		      "File: ~s:~w~n"
		      "Value: ~p", [F, YawsFile, LineNo, Other]);

	close ->
	    gen_tcp:close(CliSock),
	    exit(normal)
    end.



ut_open(UT) ->
    case UT#urltype.data of
	undefined ->
	    {ok, Fd} = file:open(UT#urltype.fullpath, [read, raw]),
	    Fd;
	B when binary(B) ->
	    {bin, B}
    end.


ut_read(Bin = {bin, B}) ->
    Bin;
ut_read(Fd) ->
    file:read(Fd, 4000).


ut_close({bin, _}) ->
    ok;
ut_close(Fd) ->
    file:close(Fd).

	


deliver_file(CliSock, GC, SC, Req, InH, UT) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}, {record, UT, urltype}]),
    DoClose = do_close(Req, InH),
    OutH = make_static_headers(Req, UT, DoClose),
    Fd = ut_open(UT),
    Bin = ut_read(Fd),
    case Bin of
	{bin, Binary} ->
	    tcp_send(CliSock, [make_200(), OutH, crnl(), Binary]);
	{ok, Binary} ->
	    send_loop(CliSock, [make_200(), OutH, crnl(), Binary], Fd)
    end,
    ut_close(Fd),
    if
	DoClose == true ->
	    done;
	DoClose == false ->
	    continue
    end.


do_close(Req, H) ->
    case Req#http_request.version of
	{1, 0} ->
	     case H#headers.keep_alive of
		 undefined ->
		     true;
		 _ ->
		     false
	     end;
	_ ->
	    false
    end.


send_loop(CliSock, Data, Fd) ->
    case tcp_send(CliSock, Data) of
	ok ->
	    case ut_read(Fd) of
		{ok, Data2} ->
		    send_loop(CliSock, Data2, Fd);
		eof ->
		    ok
	    end;
	Err ->
	    Err
    end.
	     


make_dyn_headers(DoClose, MimeType) ->
    [make_date_header(),
     make_server_header(),
     make_content_type(MimeType),
     make_connection_close(DoClose),
     make_non_cache_able()
    ].


make_non_cache_able() ->
    []. %% FIXME

make_date_and_server_headers() ->
    [make_date_header(),
     make_server_header()
    ].

make_static_headers(Req, UT, DoClose) ->    
    [make_date_and_server_headers(),
     make_last_modified(UT#urltype.finfo),
     make_etag(UT#urltype.finfo),
     make_accept_ranges(),
     make_content_length(UT#urltype.finfo),
     make_content_type(UT#urltype.mime),
     make_connection_close(DoClose)
    ].



make_200() ->
    put(status_code, 200),
    "HTTP/1.1 200 OK\r\n".

make_400(Code) ->
    put(status_code, Code),
    ["HTTP/1.1 ", integer_to_list(Code), " ",
     yaws_api:code_to_phrase(Code), crnl()].



crnl() ->
    "\r\n".



%% FIXME optimize the goddamn date generations
make_date_header() ->
    N = element(2, now()),
    case get(date_header) of
	{Str, Secs} when (Secs+10) > N ->
	    H = ["Date: ", yaws:universal_time_as_string(), crnl()],
	    put(date_header, {H, N}),
	    H;
	{Str, Secs} ->
	    Str;
	undefined ->
	    H = ["Date: ", yaws:universal_time_as_string(), crnl()],
	    put(date_header, {H, N}),
	    H
    end.

make_server_header() ->
    ["Server: Yaws/0.1 Yet Another Web Server", crnl()].
make_last_modified(_) ->
    [];
make_last_modified(FI) ->
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
    UTC = calendar:now_to_universal_time(Then),
    Local = calendar:universal_time_to_local_time(UTC),
    Str = yaws:date_and_time(Local, UTC),
    ["Last-Modified: ", yaws:date_and_time_to_string(Str), crnl()].
make_etag(File) ->
    [].
make_accept_ranges() ->
    "Accept-Ranges: bytes\r\n".
make_content_length(Size) when integer(Size) ->
    put(content_length, Size),
    ["Content-Length: ", integer_to_list(Size), crnl()];
make_content_length(FI) ->
    Size = FI#file_info.size,
    put(content_length, Size),
    ["Content-Length: ", integer_to_list(Size), crnl()].
make_content_type(MimeType) ->
    ["Content-Type: ", MimeType, crnl()].

make_connection_close(true) ->
    "Connection: close\r\n";
make_connection_close(false) ->
    [].
make_chunked() ->
    ["Transfer-Encoding: chunked",  crnl()].



%% a file cache,
url_type(GC, SC, Path) ->
    ?TC([{record, GC, gconf}, {record, SC, sconf}]),
    E = SC#sconf.ets,
    update_total(E, Path),
    case ets:lookup(E, {url, Path}) of
	[] ->
	    UT = do_url_type(SC#sconf.docroot, Path),
	    ?TC([{record, UT, urltype}]),
	    cache_file(GC, SC, Path, UT);
	[{_, When, UT}] ->
	    N = now(),
	    FI = UT#urltype.finfo,
	    if
		When + 30 > N ->
		    %% more than 30 secs old entry
		    ets:delete(E, {url, Path}),
		    ets:delete(E, {urlc, Path}),
		    ets:update_counter(E, num_files, -1),
		    ets:update_counter(E, num_bytes, -FI#file_info.size),
		    url_type(GC, SC, Path);
		true ->
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


cache_file(GC, SC, Path, UT) when UT#urltype.type == regular ;
				  UT#urltype.type == yaws ->
    E = SC#sconf.ets,
    [{num_files, N}] = ets:lookup(E, num_files),
    [{num_bytes, B}] = ets:lookup(E, num_bytes),
    FI = UT#urltype.finfo,
    if
	N + 1 > GC#gconf.max_num_cached_files ->
	    error_logger:info("Max NUM cached files reached for server "
			      "~p", [SC#sconf.servername]),
	    cleanup_cache(E, num),
	    cache_file(GC, SC, Path, UT);
	B + FI#file_info.size > GC#gconf.max_num_cached_bytes ->
	    error_logger:info("Max size cached bytes reached for server "
			      "~p", [SC#sconf.servername]),
	    cleanup_cache(E, size),
	    cache_file(GC, SC, Path, UT);
	true ->
	    if
		FI#file_info.size > GC#gconf.max_size_cached_file ->
		    UT;
		true ->
		    {ok, Bin} = file:read_file(UT#urltype.fullpath),
		    UT2 = UT#urltype{data = Bin},
		    ets:insert(E, {{url, Path}, now(), UT2}),
		    ets:insert(E, {{urlc, Path}, 1}),
		    ets:update_counter(E, num_files, 1),
		    ets:update_counter(E, num_bytes, FI#file_info.size),
		    UT2
	    end
    end;
cache_file(GC, SC, Path, UT) ->
    UT.


cleanup_cache(E, size) ->
    %% remove the largest files with the least hit count  (urlc)
    uhhh;
cleanup_cache(E, num) ->
    %% remove all files with a low hit count
    uhhh.


%% return #urltype{}
do_url_type(Droot, Path) ->
    case split_path(Droot, Path, [], []) of
	slash ->
	    case file:read_file_info([Droot, Path, "/index.yaws"]) of
		{ok, FI} ->
		    #urltype{type = yaws,
			     finfo = FI,
			     mime = "text/html",
			     fullpath = ?f([Droot, Path,"/index.yaws"])};
		_ ->
		    case file:read_file_info([Droot, Path, "/index.html"]) of
			{ok, FI} ->
			    #urltype{type = regular,
				     finfo = FI,
				     mime = "text/html",
				     fullpath =?f([Droot,Path,"/index.html"])};
			_ ->
			    case file:list_dir([Droot, Path]) of
				{ok, List} ->
				    #urltype{type = directory, data=List};
				Err ->
				    #urltype{type=error}
			    end
		    end
	    end;
	dotdot ->  %% generate 403 forbidden
	    #urltype{type=dotdot};
	Other ->
	    Other
    end.


split_path(DR, [$/], Comps, []) ->
    %% its a URL that ends with /
    slash;
split_path(DR, [$/, $/ |Tail], Comps, Part) ->  %% security clause
    split_path(DR, [$/|Tail], Comps, Part);
split_path(DR, [$/, $., $., $/ |Tail], _, [H|T]) ->  %% security clause
    split_path(DR, Tail, [], T);
split_path(DR, [$/, $., $., $/ |Tail], _, []) -> %% security clause
    dotdot;
split_path(DR, [], Comps, Part) ->
    ret_reg_split(DR, Comps, Part, []);
split_path(DR, [$?|Tail], Comps, Part) ->
    ret_reg_split(DR, Comps, Part, Tail);
split_path(DR, [$/|Tail], Comps, Part)  when Part /= [] ->
    ?Debug("Tail=~s Part=~s", [Tail,Part]),
    split_path(DR, [$/|Tail], [lists:reverse(Part) | Comps], []);
split_path(DR, [H|T], Comps, Part) ->
    split_path(DR, T, Comps, [H|Part]).


ret_reg_split(DR, Comms, File, Query) ->
    ?Debug("ret_reg_split(~p)", [[DR, Comms, File]]),
    L = [DR, lists:reverse(Comms), lists:reverse(File)],
    case file:read_file_info(L) of
	{ok, FI} when FI#file_info.type == regular ->
	    {X, Mime} = suffix_type(File),
	    #urltype{type=X, finfo=FI,
		     fullpath = lists:flatten(L),
		     mime=Mime, q=Query};
	{ok, FI} when FI#file_info.type == directory ->
	    case file:list_dir(L) of
		{ok, List} ->
		    #urltype{type=directory, data=List};
		Err ->
		    #urltype{type=error, data=Err}
	    end;
	Err ->
	    #urltype{type=error, data=Err}
    end.

suffix_type("sway." ++ _) ->
    {yaws, "text/html"};
suffix_type("lmth." ++ _) ->
    {regular, "text/html"};
suffix_type("gpj." ++ _) ->
    {regular, "image/jpeg"};
suffix_type("fig." ++ _) ->
    {regular, "image/gif"};
suffix_type("zg.rat" ++ _) ->
    {regular, "application/x-gzip"};
suffix_type(_) ->
    {regular, "application/octet-stream"}.


flush(Sock, undefined) ->
    ok;
flush(Sock, 0) ->
    ok;
flush(Sock, Sz) ->
    gen_tcp:recv(Sock, Sz, 1000).

			

%%  tada !!
%% returns a CodeSpec which is:
%% a list  {data, NumChars} | 
%%         {mod, LineNo, YawsFile, NumSkipChars,  Mod, Func} | 
%%         {error, NumSkipChars, E}}

% each erlang fragment inside <erl> .... </erl> is compiled into
% its own module


-record(comp, {
	  gc,     %% global conf
	  sc,     %% server conf
	  startline = 0,
	  modnum = 1,
	  infile,
	  infd,
	  outfile,
	  outfd}).


comp_opts(GC) ->
    I = lists:map(fun(Dir) -> {i, Dir} end, GC#gconf.include_dir),
    YawsDir = {i, "/home/klacke/yaws/include"},
    I2 = [YawsDir | I],
    Opts = [binary, report_errors | I2],
    ?Debug("Compile opts = ~p~n", [Opts]),
    Opts.


compile_file(File, GC, SC) ->
    case file:open(File, [read]) of
	{ok, Fd} ->
	    Spec = compile_file(#comp{infile = File, 
				      infd = Fd, gc = GC, sc = SC}, 
				1,  
				io:get_line(Fd, ''), html, 0, []);
	Err ->
	    yaws:elog("can't open ~s~n", [File]),
	    exit(normal)
    end.

compile_file(C, LineNo, eof, Mode, NumChars, Ack) ->
    file:close(C#comp.infd),
    {ok, lists:reverse([{data, NumChars} |Ack])};

compile_file(C, LineNo,  Chars = "<erl>" ++ Tail, html,  NumChars, Ack) ->
    ?Debug("start erl:~p",[LineNo]),
    C2 = new_out_file(LineNo, C, C#comp.gc),
    C3 = C2#comp{startline = LineNo},
    L = length(Chars),
    if
	NumChars > 0 ->
	    compile_file(C3, LineNo+1, line(C) , erl,L, 
			 [{data, NumChars} | Ack]);
	true -> %% just ignore zero byte data segments
	    compile_file(C3, LineNo+1, line(C) , erl, L, Ack)
    end;

compile_file(C, LineNo,  Chars = "</erl>" ++ Tail, erl, NumChars, Ack) ->
    ?Debug("stop erl:~p",[LineNo]),
    file:close(C#comp.outfd),
    NumChars2 = NumChars + length(Chars),
    case compile:file(C#comp.outfile, comp_opts(C#comp.gc)) of
	{ok, ModuleName, Binary} ->
	    case code:load_binary(ModuleName, C#comp.outfile, Binary) of
		{module, ModuleName} ->
		    C2 = C#comp{modnum = C#comp.modnum+1},
		    L2 = check_exported(C2, LineNo,NumChars2, ModuleName),
		    compile_file(C, LineNo+1, line(C),html,0,L2++Ack);
		Err ->
		    A2 = gen_err(C, LineNo, NumChars2,
				 ?F("Cannot load module ~p: ~p", 
				    [ModuleName, Err])),
		    compile_file(C, LineNo+1, line(C),
				 html, 0, [A2|Ack])
	    end;
	{error, Errors, Warnings} ->
	    %% FIXME remove outfile here ... keep while debuging
	    A2 = comp_err(C, LineNo, NumChars2, Errors),
	    compile_file(C, LineNo+1, line(C), html, 0, [A2|Ack]);
	error ->  
	    %% this is boring but does actually happen
	    %% in order to get proper user errors here we need to catch i/o
	    %% or hack compiler/parser
	    yaws:elog("Dynamic compile error in file ~s, line~w",
		      [C#comp.infile, LineNo]),
	    A2 = {error, NumChars2, ?F("<xmp> Dynamic compile error in file "
				       " ~s line ~w </xmp>", 
				       [C#comp.infile, LineNo])},
	    compile_file(C, LineNo+1, line(C), html, 0, [A2|Ack])
    end;

compile_file(C, LineNo,  Chars = "<xmp>" ++ Tail, html,  NumChars, Ack) ->
    ?Debug("start xmp:~p",[LineNo]),
    compile_file(C, LineNo+1, line(C) , xmp, NumChars + length(Chars), Ack);

compile_file(C, LineNo,  Chars = "</xmp>" ++ Tail, xmp,  NumChars, Ack) ->
    ?Debug("stop xmp:~p",[LineNo]),
    compile_file(C, LineNo+1, line(C) , html, NumChars + length(Chars), Ack);

compile_file(C, LineNo,  Chars, erl, NumChars, Ack) ->
    io:format(C#comp.outfd, "~s", [Chars]),
    compile_file(C, LineNo+1, line(C), erl, NumChars + length(Chars), Ack);

compile_file(C, LineNo,  Chars, html, NumChars, Ack) ->
    compile_file(C, LineNo+1, line(C), html, NumChars + length(Chars), Ack);

compile_file(C, LineNo,  Chars, xmp, NumChars, Ack) ->
    compile_file(C, LineNo+1, line(C), xmp, NumChars + length(Chars), Ack).





check_exported(C, LineNo, NumChars, Mod) when C#comp.modnum == 1->
    case {is_exported(some_headers, 1, Mod),
	  is_exported(all_headers, 1, Mod),
	  is_exported(all_out, 1, Mod)} of
	{true, true, _} ->
	    [gen_err(C, LineNo, NumChars,
		     ?F("Cannot have both some and the all "
			"headers",[]))];
	
	%% someheaders
	{true, false, true} ->
	    [{mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,some_headers},
	     {mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,out}];
	{true, false, false} ->
	    [{mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,some_headers}];
	
	%% allheaders
	{false, true, true} ->
	    [{mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,all_headers},
	     {mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,out}];
	
	{false, true, false} ->
	    [{mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,all_headers}];
	
	{false, false, true} ->
	    [{mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,out}]
    
    
    end;
check_exported(C, LineNo, NumChars, Mod) ->
    case is_exported(out, 1, Mod) of
	true ->
	    [{mod, C#comp.startline, C#comp.infile, 
	      NumChars,Mod,out}];
	false ->
	    [gen_err(C, LineNo, NumChars,
		     "out/1 is not defined ")]
    end.




line(C) ->
    io:get_line(C#comp.infd, '').

is_exported(Fun, A, Mod) ->
    case (catch Mod:module_info()) of
	List when list(List) ->
	    case lists:keysearch(exports, 1, List) of
		{value, {exports, Exp}} ->
		    lists:member({Fun, A}, Exp);
		_ ->
		    false
	    end;
	_ ->
	    false
    end.

	     
%% this will generate 9 lines
new_out_file(Line, C, GC) ->
    Mnum = gen_server:call(?MODULE, mnum),
    Module = [$m | integer_to_list(Mnum)],
    OutFile = "/tmp/yaws/" ++ Module ++ ".erl",
    ?Debug("Writing outout file~s~n", [OutFile]),
    {ok, Out} = file:open(OutFile, [write]),
    ok = io:format(Out, "-module(~s).~n-compile(export_all).~n~n", [Module]),
    io:format(Out, "%%~n%% code at line ~w from file ~s~n%%~n",
	      [Line, C#comp.infile]),

    io:format(Out, "-import(yaws_api, [f/2, fl/1, parse_post_data/2]). ~n~n", []),
    io:format(Out, '-include("~s/include/yaws_api.hrl").~n', 
	      [GC#gconf.yaws_dir]),
    C#comp{outfd = Out,
	   outfile = OutFile}.



mtime(F) ->
    F#file_info.mtime.

gen_err(C, LineNo, NumChars, Err) ->
    S = io_lib:format("<p> Error in File ~s Erlang code beginning "
		      "at line ~w~n"
		      "Error is: ~p~n", [C#comp.infile, C#comp.startline, 
					 Err]),
    yaws:elog("~s~n", [S]),
    {error, NumChars, S}.


comp_err(C, LineNo, NumChars, Err) ->
    case Err of
	[{FileName, [ErrInfo|_]} |_] ->
	    {Line0, Mod, E}=ErrInfo,
	    Line = Line0 + C#comp.startline - 9,
	    ?Debug("XX ~p~n", [{LineNo, Line0}]),
	    Str = io_lib:format("~s:~w: ~s\n", 
				[C#comp.infile, Line,
				 apply(Mod, format_error, [E])]),
	    HtmlStr = ?F("~n<pre>~nDynamic compile error: ~s~n</pre>~n", 
			[Str]),
	    yaws:elog("Dynamic compiler err ~s", [Str]),
	    {error, NumChars,  HtmlStr};
	Other ->
	    yaws:elog("Dynamic compile error", []),
	    {error, NumChars, ?F("<pre> Compile error - "
				 "Other err ~p</pre>~n", [Err])}
    end.

tcp_send(S, Data) ->
    ?Debug("SEND: ~s", [binary_to_list(to_binary(Data))]),
    ok = gen_tcp:send(S, Data).




not_found_body(Url, GC, SC) ->
    ?Debug("Sconf: ~p", [?format_record(SC, sconf)]),
    L = ["<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">"
	 "<HTML><HEAD>"
	 "<TITLE>404 Not Found</TITLE>"
	 "</HEAD><BODY>"
	 "<H1>Not Found</H1>"
	 "The requested URL ", 
	 Url, 
	 " was not found on this server.<P>"
	 "<HR>",
	 yaws:address(GC, SC),
	 "  </BODY></HTML>"
	],
    list_to_binary(L).


