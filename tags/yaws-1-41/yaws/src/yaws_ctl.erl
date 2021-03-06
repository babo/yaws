%%%----------------------------------------------------------------------
%%% File    : yaws_ctl.erl
%%% Author  : Claes Wikstrom <klacke@bluetail.com>
%%% Purpose : 
%%% Created : 29 Apr 2002 by Claes Wikstrom <klacke@bluetail.com>
%%%----------------------------------------------------------------------


%% some code to remoteley control a running yaws server

-module(yaws_ctl).
-author('klacke@bluetail.com').

-compile(export_all).
-include_lib("kernel/include/file.hrl").
-include_lib("yaws/include/yaws.hrl").
-include_lib("yaws/include/yaws_api.hrl").
-include("yaws_debug.hrl").

ctl_file("0") ->
    "/var/run/yaws.ctl";
ctl_file(Id) ->
    Tmp = yaws:tmp_dir_fstr(),
    io_lib:format(Tmp ++ "/yaws.ctl.~s",[Id]).


start(Top, Id) ->
    case catch start0(Top, Id) of
	{'EXIT', Reason} ->
	    error_logger:format("Faild to start ctl : ~p~n", [Reason]),
	    Top ! {self(), {error, Reason}};
	Other ->
	    Other
    end.

start0(Top, Id) ->
    case gen_tcp:listen(0, [{packet, 2},
			    {active, false},
			    binary,
			    {ip, {127,0,0,1}},
			    {reuseaddr, true}]) of 
	{ok,  L} ->
	    case inet:sockname(L) of
		{ok, {_, Port}} ->
		    F = ctl_file(Id),
		    ?Debug("Ctlfile : ~s~n", [F]),
		    file:write_file(F, io_lib:format("~w", [Port])),
		    {ok, FI} = file:read_file_info(F),
		    M = FI#file_info.mode,
		    M2 = M bor (8#00222),
		    file:write_file_info(F, FI#file_info{mode = M2}), %%ign ret
		    Top ! {self(), ok},
		    aloop(L);
		Err ->
		    error_logger:format("Cannot get sockname for ctlsock",[]),
		    Top ! {self(), {error, Err}}
	    end;
	Err ->
	    error_logger:format("Cannot listen on ctl socket ",[]),
	    Top ! {self(), {error, Err}}

    end.


aloop(L) ->
    case gen_tcp:accept(L) of
	{ok, A} ->
	    handle_a(A);
	_Err ->
	    ignore
    end,
    ?MODULE:aloop(L).

handle_a(A) ->
    case gen_tcp:recv(A, 0) of
	{ok, Data} ->
	    case binary_to_term(Data) of
		hup ->
		    Res = yaws:dohup(A),
		    Res;
		stop ->
		    gen_tcp:send(A, "stopping\n"),
		    init:stop();
		status ->
		    a_status(A),
		    gen_tcp:close(A);
		{load, Mods} ->
		    a_load(A, Mods),
		    gen_tcp:close(A);
		Other ->
		    gen_tcp:send(A, io_lib:format("Other: ~p~n", [Other])),
		    gen_tcp:close(A)
	    
	    end;
	_Err ->
	    ignore
    end.



f(Fmt, As) ->
    io_lib:format(Fmt, As).

a_status(Sock) ->
    {UpTime, L} = yaws_server:stats(),
    {Days, {Hours, Minutes, _Secs}} = UpTime,
    H = f("~n Uptime: ~w Days, ~w Hours, ~w Minutes  ~n",
           [Days, Hours, Minutes]),
    
    T =lists:map(
	 fun({Host,IP,Hits}) ->
		 L1= f("stats for ~p at ~p  ~n",
		       [Host,IP]),
		 T = "\n"
                     "URL                  Number of hits\n",
		 L2=lists:map(
		      fun({Url, Hits2}) ->
			      f("~-30s ~-7w ~n",
				[Url, Hits2])
		      end, Hits),
		 END = "\n",
		 [L1, T, L2, END]
	 end, L),
    gen_tcp:send(Sock, [H, T]),
    
    %% Now lets' figure out the status of loaded modules
    ok.

a_load(A, Mods) ->
    case purge(Mods) of
	ok ->
	    gen_tcp:send(A, f("~p~n", [loadm(Mods)]));
	Err ->
	    gen_tcp:send(A, f("~p~n", [Err]))
    end.

loadm([]) ->
    [];
loadm([M|Ms]) ->
    [code:load_file(M)|loadm(Ms)].

purge(Ms) ->
    case purge(Ms, []) of 
	[] -> ok;
	L -> {cannot_purge, L}
    end.

purge([], Ack) ->
    Ack;
purge([M|Ms], Ack) ->
    case code:soft_purge(M) of
	true ->
	    purge(Ms, Ack);
	false ->
	    purge(Ms, [M|Ack])
    end.



actl(Term, Uid) ->
    CtlFile = ctl_file(Uid),
    case file:read_file(CtlFile) of
	{ok, B} ->
	    L = binary_to_list(B),
	    I = list_to_integer(L),
	    case gen_tcp:connect({127,0,0,1}, I,
				 [{active, false},
				  {reuseaddr, true},
				  binary,
				  {packet, 2}]) of
		{ok, Fd} ->
		    gen_tcp:send(Fd, term_to_binary(Term)),
		    Res = gen_tcp:recv(Fd, 0),
		    case Res of
			{ok, Bin} ->
			    io:format("~s~n", [binary_to_list(Bin)]);
			Err ->
			    io:format("yaws server for uid ~s not responding: ~p ~n",[Uid, Err])
		    end,
		    gen_tcp:close(Fd),
		    Res;
		Err ->
		    io:format("yaws server under uid  ~s not running \n", [Uid]),
		    Err
	    end;
	Err ->
	    io:format("yaws: Cannot open runfile ~s ... server under uid ~s "
		      "not running ?? ~n",
		      [CtlFile, Uid])
    end,
    init:stop().

uid() ->
    {ok, Id} = yaws:getuid(), Id.


%% send a hup (kindof) to the yaws server to make it
%% reload its configuration and clear its caches

hup() ->
    actl(hup, uid()).

stop() ->	
    actl(stop, uid()).

status() ->
    actl(status, uid()).

load(Modules) ->
    actl({load, Modules}, uid()).

check([File| IncludeDirs]) ->
    GC = yaws_config:make_default_gconf(false),
    GC2 = GC#gconf{include_dir = lists:map(fun(X) -> atom_to_list(X) end, 
					   IncludeDirs)},
    SC = #sconf{},

    case yaws_compile:compile_file(atom_to_list(File), GC2, SC) of
	{ok, [{errors, 0}| _Spec]} ->
	    io:format("ok~n",[]),
	    init:stop();
	_Other ->
	    io:format("~nErrors in ~p~n", [File]),
	    init:stop()
    end.


    



		    

		    


		

