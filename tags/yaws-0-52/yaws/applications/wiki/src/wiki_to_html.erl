-module(wiki_to_html).

%% File    : wiki_to_html.erl
%% Author  : Joe Armstrong (joe@bluetail.com)
%%         : Johan Bevemyr, minor modifications (jb@bevemyr.com)
%% Purpose : Convert wiki page tree to HTML

-export([format_wiki/3, format_link/2, format_wiki_files/4]).

-import(lists, [member/2, map/2]).

format_wiki_files(Page, FileDir, [], Root) -> [];
format_wiki_files(Page, FileDir, Files, Root) ->
    LinkFun = fun(I) -> format_link(I, FileDir, Page, Root) end,
    ("<hr><b><p>Attached files: </b><br>\n" 
     "<table cellspacing=10 width = \"100%\">\n" 
     ++ lists:map(LinkFun, lists:keysort(2,Files)) ++
     "</table></p>\n").

format_wiki(Page, Wik, Root) ->
    LinkFun = fun(I) -> format_link(I, Page, Root) end,
    pp(Wik, LinkFun).

format_link(Page, Root) ->
    format_link({wikiLink, Page}, [], Root).

format_link({wikiLink, Page}, _, Root) ->
    FullName = Root ++ "/" ++ Page ++ ".wob",
    %% io:format("Testing:~p~n",[FullName]),
    case is_file(FullName) of
	true ->
	    ["<a href=\"showPage.yaws?node=",Page,"\">",Page,"</a> "];
	false ->
	    [" ",Page,"<a href=\"createNewPage.yaws?node=",Page,"\">???</a>"]
    end;
format_link({editTag, Tag}, Page, Root) ->
    ["<a href=\"/wiki/editTag?node=",Page,"&tag=",i2s(Tag),"\">",
     "<img border=0 src='edit.gif'></a> "].

format_link({file, FileName, _}, FileDir, Page, Root) ->
    ["<tr><td valign=top align=left><a href=\"", FileDir, "/", FileName,"\">",
     FileName, "</a> </td><td valign=top align=left>",  "</td></tr>\n"];

format_link({file, FileName, Description, _}, FileDir, Page, Root) ->
    ["<tr><td valign=top align=left><a href=\"", FileDir, "/", FileName,"\">",
     FileName, "</a></td><td align=left valign=top>",
     Description, "</td></tr>\n"].

i2s(X) ->
    integer_to_list(X).

pp({wik,L}, F) ->
    map(fun(I) -> pp(I, F) end, L);
pp({txt,_,Str}, F) ->
    wiki_format_txt:format(Str, F);
pp({open,Tag,Str}, F) -> 
    open("#CCFFCC",Tag,F,pp({txt,9999,Str}, F));
pp({write_append,Tag,Str}, F) -> 
    open("#99FFFF",Tag,F,pp({txt,8888,Str}, F));
pp(Other, F) ->
    wiki:show({cannot,format,Other}).

open(Color, Tag, F, Stuff) ->
    ["\n<table width=\"90%\" cellpadding=20>\n<tr><td bgcolor=\"",
     Color, "\">\n", Stuff,
     "<p>",F({editTag,Tag}),"</td></tr></table><p>\n"];
open(Color, Args, F, Stuff) ->
    wiki:show({bad_open_tag,Args}).

is_file(File) ->
    case file:file_info(File) of
        {ok, _} ->
            true;
        _ ->
            false
    end.












