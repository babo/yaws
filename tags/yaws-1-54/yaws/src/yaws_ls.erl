%%%----------------------------------------------------------------------
%%% File    : yaws_ls.erl
%%% Author  : Claes Wikstrom <klacke@hyber.org>
%%% Purpose : 
%%% Created :  5 Feb 2002 by Claes Wikstrom <klacke@hyber.org>
%%% Modified: 13 Jan 2004 by Martin Bjorklund <mbj@bluetail.com>
%%%----------------------------------------------------------------------

-module(yaws_ls).
-author('klacke@hyber.org').

-compile(export_all).

-include_lib("yaws/include/yaws.hrl").
-include_lib("yaws/include/yaws_api.hrl").
-include("yaws_debug.hrl").

-include_lib("kernel/include/file.hrl").

list_directory(Arg, CliSock, List, DirName, Req, DoAllZip) ->
    {abs_path, Path} = Req#http_request.path,
    {DirStr, Pos, Direction, Qry} = parse_query(Path),
    ?Debug("List=~p Dirname~p~n", [List, DirName]), 
    [Up | L0] = lists:zf(
		  fun(F) ->
			  File = DirName ++ [$/|F],
			  FI = file:read_file_info(File),
			  file_entry(FI, DirName, F, Qry)
		  end, [".." | List]),
    L1 = lists:keysort(Pos, L0),
    L2 = if Direction == normal -> L1;
	    Direction == reverse -> lists:reverse(L1)
	 end,
    [UpHtml | L3] = [Html || {_, _, _, Html} <- [Up | L2]],
    L4 = case DoAllZip of
	     true ->
		 [UpHtml, all(DirName) | L3];
	     false ->
		 [UpHtml | L3]
	 end,
    Body = [ doc_head(DirStr),
	     list_head(Direction), 
	     L4,
	     list_tail(),
	     "\n<pre>",
	     inline_readme(DirName,List),
	     "</pre>\n<hr>\n",
	     yaws:address(),
	     "</body>\n</html>\n"],
    B = list_to_binary(Body),

    yaws_server:accumulate_content(B),
    yaws_server:deliver_accumulated(Arg, CliSock, decide, undefined, final),
    yaws_server:done_or_continue().

parse_query(Path) ->
    case string:tokens(Path, [$?]) of
	[DirStr, [PosC, $=, DirC] = Q] ->
	    Pos = case PosC of
		      $D -> 2; % date
		      $S -> 3; % size
		      _  -> 1  % name
		  end,
	    Dir = case DirC of
		      $r -> reverse;
		      _  -> normal
		  end,
	    {DirStr, Pos, Dir, "/?"++Q};
	_ ->
	    {Path, 1, normal, ""}
    end.
    


inline_readme(DirName,L) ->
    F = fun("README", _Acc) ->
		File = DirName ++ [$/ | "README"],
		{ok,Bin} = file:read_file(File),
		binary_to_list(Bin);
	   (_, Acc) ->
		Acc
	end,
    lists:foldl(F,[],L).


doc_head(DirName) ->
    HtmlDirName = yaws_api:htmlize(yaws_api:url_decode(DirName)),
    ?F("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2 Final//EN\"> \n"
       "<html> \n"
       "  <head> \n"
       "    <title>Index of ~s</title> \n"
       "    <style type=\"text/css\">\n"
       "    img { border: 0; padding: 0 2px; vertical-align: text-bottom; }\n"
       "    td  { font-family: monospace; padding: 2px 3px; text-align:left;\n"
       "          vertical-align: bottom; white-space: pre; }\n"
       "    td:first-child { text-align: left; padding: 2px 10px 2px 3px; }\n"
       "    table { border: 0; }\n"
%       "    a.symlink { font-style: italic; }\n"
       "    </style>\n"
       "  </head> \n"
       "  <body>\n"
       "    <h1>Index of ~s</h1>\n"
       "    <hr/>\n",
       [HtmlDirName, HtmlDirName]).

list_head(Direction) ->
    NextDirection = if Direction == normal  -> "r";
		       Direction == reverse -> "n"
		    end,
    ["<table>\n"
     "<tr>\n"
     "  <td><img src=\"/icons/blank.gif\"/"
     " alt=\"&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\"><a href=\"?N=",
     NextDirection,"\">Name</a></td>\n"
     "  <td><a href=\"?D=",NextDirection,"\">Last Modified</a></td>\n"
     "  <td><a href=\"?S=",NextDirection,"\">Size</a></td>\n"
     "</tr>\n"
     "<tr><td colspan=\"3\"><img src=\"/icons/blank.gif\""
     "alt=\"&nbsp;\"/></td></tr>\n"].

list_tail() ->
    "</table>".

%% FIXME: would be nice with a good size approx.  but it would require
%% a deep scan of possibly the entire docroot, (and also some knowledge
%% about zip's compression ratio in advance...)
all(DirName) ->
    {Gif, Alt} = list_gif(zip, ""),
    {ok, FI} = file:read_file_info(DirName),
    ?F("<tr>\n"
       "<td><a href=~p title=\"all.zip\"><img src=~p alt=~p/>~s</a></td>\n"
       "<td>~s</td>\n"
       "<td>0k</td>\n"
       "</tr>\n",
       [yaws_api:url_encode(lists:flatten(DirName)) ++ "all.zip",
	"/icons/" ++ Gif,
	Alt,
	"all.zip",
	datestr(FI)]).
    
out(A) ->
    Dir = A#arg.appmod_prepath,
    YPid = self(),
    spawn_link(fun() -> zip(YPid, Dir) end),
    {streamcontent, "application/zip", ""}.

zip(YPid, Dir) ->
    process_flag(trap_exit, true),
    P = open_port({spawn, "zip -q -1 -r - '" ++ Dir ++ "'"},
		  [use_stdio, binary, exit_status]),
    zip_loop(YPid, P).

zip_loop(YPid, P) ->
    receive
	{P, {data, Data}} ->
	    yaws_api:stream_chunk_deliver_blocking(YPid, Data),
	    zip_loop(YPid, P);
	{P, {exit_status, _}} ->
	    yaws_api:stream_chunk_end(YPid);
	{'EXIT', YPid, Status} ->
	    exit(Status);
	Else ->
	    error_logger:error_msg("Could not deliver zip file: ~p\n", [Else])
    end.


%% Removed code that appendended  Qry  to the file name.
%% It might still be a good idea in case  type==directory.
%% Was that the intention?
%% Carsten
%%
%% yes, that was the intention.  fixed now (mbj)
%% ... and maybe we should just remove this conversation in the next checkin :)

file_entry({ok, FI}, _DirName, Name, Qry) ->
    ?Debug("file_entry(~p) ", [Name]),
    Ext = filename:extension(Name),
    {Gif, Alt} = list_gif(FI#file_info.type, Ext),
    QryStr = if FI#file_info.type == directory -> Qry;
		true -> ""
	     end,
    Entry = 
	?F("<tr>\n"
	   "<td><a href=~p title=\"~w bytes\"><img src=~p alt=~p/>~s</a></td>\n"
	   "<td>~s</td>\n"
	   "<td>~s</td>\n"
	   "</tr>\n",
	   [yaws_api:url_encode(Name) ++ QryStr,
	    FI#file_info.size,
	    "/icons/" ++ Gif,
	    Alt,
	    Name,
	    datestr(FI), 
	    sizestr(FI)]),
    ?Debug("Entry:~p", [Entry]),
    {true, {Name, FI#file_info.mtime, FI#file_info.size, Entry}};
file_entry(_Err, _, _Name, _) ->
    ?Debug("no entry for ~p: ~p", [_Name, _Err]),
    false.


%%% Compensate for '&gt' which really is just one character.
trim(L,N) ->
    case trim(L,N,[]) of
	{truncated,R} -> {R,length(R)-2};
	R -> {R,length(R)}
    end.

trim([_H|_T], 4, Acc) ->
    {truncated,lists:reverse(Acc) ++ "...&gt"};
trim([H|T], I, Acc) ->
    trim(T, I-1, [H|Acc]);
trim([], _, Acc) ->
    lists:reverse(Acc).


datestr(FI) ->
    yaws:time_to_string(FI#file_info.mtime, []).

sizestr(FI) when FI#file_info.size > 1000000 ->
    ?F("~.1fM", [FI#file_info.size / 1000000]);
sizestr(FI) when FI#file_info.size > 1000 ->
    ?F("~wk", [trunc(FI#file_info.size / 1000)]);
sizestr(FI) when FI#file_info.size == 0 ->
    ?F("0k", []);
sizestr(_FI) ->
    ?F("1k", []). % As apache does it...


list_gif(directory, ".") ->
    {"back.gif", "[DIR]"};
list_gif(regular, ".txt") -> 
    {"text.gif", "[TXT]"};
list_gif(regular, ".c") ->
    {"c.gif", "[&nbsp;&nbsp;&nbsp;]"};
list_gif(regular, ".dvi") ->
    {"dvi.gif", "[&nbsp;&nbsp;&nbsp;]"};
list_gif(regular, ".pdf") ->
    {"pdf.gif", "[&nbsp;&nbsp;&nbsp;]"};
list_gif(regular, _) ->
    {"layout.gif", "[&nbsp;&nbsp;&nbsp;]"};
list_gif(directory, _) ->
    {"dir.gif", "[DIR]"};
list_gif(zip, _) ->
    {"compressed.gif", "[DIR]"};
list_gif(_, _) ->
    {"unknown.gif", "[OTH]"}.

    



