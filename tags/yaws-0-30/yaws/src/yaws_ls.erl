%%%----------------------------------------------------------------------
%%% File    : yaws_ls.erl
%%% Author  : Claes Wikstrom <klacke@hyber.org>
%%% Purpose : 
%%% Created :  5 Feb 2002 by Claes Wikstrom <klacke@hyber.org>
%%%----------------------------------------------------------------------

-module(yaws_ls).
-author('klacke@hyber.org').

-compile(export_all).
-include("yaws.hrl").
-include_lib("kernel/include/file.hrl").



list_directory(CliSock, List, DirName, GC, SC) ->
    ?Debug("List=~p", [List]), 
    L = lists:zf(
	  fun(F) ->
		  File = SC#sconf.docroot ++ DirName ++ [$/|F],
		  FI = file:read_file_info(File),
		  file_entry(FI, DirName, F)
	  end, [".." | List]),
    Body = [doc_head(DirName), 
	    list_head(), 
	    L,
	    "\n</pre>\n<hr>\n",
	    yaws:address(GC, SC),
	    "</body>\n</html>\n"],
    Bin = list_to_binary(Body),
    D = [yaws_server:make_200(), 
	 yaws_server:make_dyn_headers(true, "text/html"),
	 "\r\n", Bin],
    yaws_server:safe_send(true, CliSock, D, GC),
    done.



doc_head(DirName) ->
    DocHead = 
	?F("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2 Final//EN\"> \n"
	   "<html> \n"
	   "  <head> \n"
	   "    <title>Index of ~s </title> \n"
	   "  </head> \n"
	   "  <body>\n"
	   "    <h1>Index of ~s </h1>\n", [DirName, DirName]).

list_head() ->
    ListHead =
	"    <pre><img SRC=\"/icons/blank.gif\" ALT=\"     \"> "
	"<a HREF=\"?N=D\">Name</a>                   "
	"<a HREF=\"?M=A\">Last modified</a>                     "
	" <a HREF=\"?S=A\">Size</a>             "
	"<a HREF=\"?D=A\">Description</a> \n"
	"<hr> \n".


% produce a string like
%     <img SRC="/icons/layout.gif" ALT="[   ]"> <a HREF="iSD_SSL_3.0.1_beta1_Application_Guide_011206.pdf">iSD_SSL_3.0.1_beta1_..&gt;</a> 17-Dec-2001 19:06   1.3M  


file_entry({ok, FI}, DirName, Name) ->
    ?Debug("file_entry(~p) ", [Name]),
    Ext = filename:extension(Name),
    {Gif, Alt} = list_gif(FI#file_info.type, Ext),
    Trim = trim(Name, 20),
    Entry = ?F("<img SRC=~p  ALT=~p> <a HREF=~p>~s</a> ~s~s          ~s~n",
	       ["/icons/" ++ Gif,
		Alt,
		DirName ++ [$/|Name], 
		Trim,
		lists:duplicate(20 - length(Trim), $\s),
		datestr(FI), 
		sizestr(FI)]),
    ?Debug("Entry:~p", [Entry]),
    {true, Entry};
file_entry(Err, _, Name) ->
    ?Debug("no entry for ~p: ~p", [Name, Err]),
    false.




trim([H|T], 0) ->
    "..&gt";
trim([H|T], I) ->
    [H|trim(T,I-1)];
trim([], _) ->
    [].


datestr(FI) ->
    yaws:time_to_string(FI#file_info.mtime, []).
sizestr(FI) when FI#file_info.size > 1000000 ->
    ?F("~.1f M", [FI#file_info.size / 1000000]);
sizestr(FI) when FI#file_info.size > 1000 ->
    ?F("~w k", [trunc(FI#file_info.size / 1000)]);
sizestr(FI) ->
    ?F("~w ", [FI#file_info.size]).


list_gif(directory, ".") ->
    {"back.gif", "[DIR]"};
list_gif(regular, ".txt") -> 
    {"text.gif", "[TXT]"};
list_gif(regular, ".c") ->
    {"c.gif", "[   ]"};
list_gif(regular, ".dvi") ->
    {"dvi.gif", "[   ]"};
list_gif(regular, ".pdf") ->
    {"pdf.gif", "[   ]"};
list_gif(regular, _) ->
    {"layout.gif", "[   ]"};
list_gif(directory, _) ->
    {"dir.gif", "[DIR]"}.
    



