%    -*- Erlang -*- 
%    File:	wiki.erl  (~jb/work/wiki/src/wiki.erl)
%    Author:    Joe Armstrong
%    Author:	Johan Bevemyr
%    Purpose:   Wiki web in Erlang

%%
%% History: Ported and partly rewritten by Johan Bevemyr for 
%%          the yaws http server.
%%

%% History: First started by Luke Gorrie who wrote the first
%%          Erlang wiki. Subsequently re-written many times by Joe Armstrong
%%          and Luke Gorrie.
%%          This version by Joe Armstrong.
%%          Thanks to Luke and Robert Virding for many helpfull
%%          discussions clarifying the design.
%%          This also makes use of the new pico_http_server which has
%%          a much simplified interface.


-module('wiki').
-author('jb@son.bevemyr.com').
-compile(export_all).

-export([showPage/3, createNewPage/3, showHistory/3, allPages/3,
	 lastEdited/3, wikiZombies/3, editPage/3, editFiles/3,
	 previewNewPage/3, allRefsToMe/3, deletePage/3, deletePage/4,
	 editTag/3, finalDeletePage/3, storePage/3,
	 storeNewPage/3, previewPage/3, previewTagged/3,
	 storeTagged/3,
	 sendMeThePassword/3, storeFiles/3, showOldPage/3]).

-export([show/1, ls/1, h1/1, read_page/2, background/1, p/1,
	 str2urlencoded/1]).

-import(lists, [reverse/1, map/2, sort/1]).

-import(wiki_templates, [template/4]).

% This should be -include:ed instead

showPage(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    if 
	Page == undefined ->
	    error(invalid_request);
	true ->
	    {WobFile, FileDir} = page2filename(Page, Root),
	    case file:read_file(WobFile) of
		{ok, Bin} ->
		    {wik002, Pwd,_Email,_Time,_Who,TxtStr,Files,_Patches} =
			bin_to_wik002(Root,FileDir,Bin),
		    Wik = wiki_split:str2wiki(TxtStr),
		    DeepStr = wiki_to_html:format_wiki(Page, Wik, Root),
		    DeepFiles = wiki_to_html:format_wiki_files(
				  Page, FileDir, Files, Root),
		    wiki_templates:template(Page, body_pic(Pwd),
					    banner(Page, Pwd),
					    [top_header(Page),DeepStr,
					     DeepFiles, footer(Page,Pwd)]);
		_ ->
		    createNewPage([{node, Page}], Root, Prefix)
	    end
    end.


createNewPage(Params, Root, Prefix) ->
    Page = getopt(node, Params),

    wiki_templates:template(
      "New Page",bgcolor("white"),"",
      [h1(Page),
       p("Creating a new page. "
	 "If you want a password protected page "
	 "then fill in both the password fields - otherwise "
	 "leave them blank."),
       p("If you fill in the email field and forget the page password "
	 "then the system can mail you back the password of the page if "
	 "you forget it."),
       p("Click on 'Preview' when you are ready to store the page."),
       form("POST", "previewNewPage.yaws",
	    [input("submit", "review", "Preview"),
	     input("hidden", "node", Page),
	     "Password1:",
	     password_entry("password1", 8),
	     "Password2:",
	     password_entry("password2", 8),p(),
	     "Email:",
	     input("text","email",""),
	     p(),
	     textarea("text", 25, 72,initial_page_content())])]).



storePage(Params, Root, Prefix) ->

    Page     = getopt(node,Params),
    Password = getopt(password, Params),
    Txt0     = getopt(txt, Params),

    Txt = zap_cr(urlencoded2str(Txt0)),
    %% Check the password
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    Wik = {wik002,Pwd,_Email,_Time,_Who,_OldTxt,_Files,_Patches} =
		bin_to_wik002(Bin),
	    case Pwd of 
		"" ->
		    store_ok(Page, Root, Prefix, Txt, Wik);
		Password ->
		    store_ok(Page, Root, Prefix, Txt, Wik);
		_ ->
		    show({invalid_password, shouldbe, Pwd, was, Password})
	    end;
	_ ->
	    show({no_such_page,Page})
   end.

storeNewPage(Params, Root, Prefix) ->
    
    Page     = getopt(node, Params),
    Password = getopt(password, Params),
    Email0   = getopt(email, Params),
    Txt0     = getopt(txt, Params),
    
    Txt = zap_cr(urlencoded2str(Txt0)),
    Email = urlencoded2str(Email0),
    %% Check the password
    {File,FileDir} = page2filename(Page, Root),
    Time = {date(),time()},
    Who = "unknown",
    B = term_to_binary({wik002,Password,Email,Time,Who,Txt,[],[]}),
    file:write_file(File, B),
    redirect({node, Page}, Prefix).

storeTagged(Params, Root, Prefix) ->

    Page = getopt(node, Params),
    Tag  = getopt(tag, Params),
    Txt0 = getopt(txt, Params),

    Txt = zap_cr(urlencoded2str(Txt0)),
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    Wik = {wik002,_Pwd,_Email,_Time,_Who,OldTxt,_Files,_Patches} = 
		bin_to_wik002(Bin),
	    W    = wiki_split:str2wiki(OldTxt),
	    ITag = list_to_integer(Tag),
	    {Type, Old} = wiki_split:getRegion(ITag, W),
	    W2 = case Type of
		     open ->
			 wiki_split:putRegion(ITag, W, Txt);
		     write_append ->
			 Time = format_time({date(), time()}),
			 wiki_split:putRegion(ITag, W, 
					      "''" ++ Time ++ "''\n\n" ++
					      Txt ++ "\n\n____\n" ++ Old)
		   end,
	    Str2 = wiki_split:wiki2str(W2),
	    store_ok(Page, Root, Prefix, Str2, Wik);
	_ ->
	    show({no_such_page,Page})
   end.


storeFiles(Params, Root, Prefix) ->

    Page        = getopt(node, Params),
    Password    = getopt(password, Params),
    Cancel      = getopt(cancel, Params),
    ContentL    = getopt(attached, Params),
    Description = getopt(text, Params),
    FileOpts    = getopt_options(attached, Params),

    FilePath    = getopt(filename, FileOpts, ""),
    Filename = basename(FilePath),

    if
	Cancel /= undefined ->
	    redirect({node, Page}, Prefix);
	true ->
	    Checkboxes = [{lists:nthtail(3,atom_to_list(N)),S} ||
			     {N,S,_} <- Params,
			     lists:prefix("cb_",atom_to_list(N))],
	    Content = list_to_binary(ContentL),
	    {File,FileDir} = page2filename(Page, Root),
	    case file:read_file(File) of
		{ok, Bin} ->
		    Wik = {wik002,Pwd,_Email,_Time,
			   _Who,_Txt,OldFiles,_Patches} = bin_to_wik002(Bin),
		    KeepFiles = [{file, Fname, Fdesc, []} ||
				    F = {file, Fname, Fdesc, _} <- OldFiles,
				    lists:keymember(Fname, 1, Checkboxes)],
		    DelFiles =
			[F || F = {file, Fname, Fdesc, Fcont} <- OldFiles,
			      not lists:keymember(Fname, 1, Checkboxes)],
		    NewFile = {file, Filename, Description, []},
		    NewFiles =
			case {Filename,Content} of
			    {[],<<>>} -> KeepFiles;
			    _ ->
				KeptOld =
				    lists:keydelete(Filename, 2, KeepFiles),
				[NewFile|KeptOld]
			end,
		    case Pwd of
			"" ->
			    store_files_ok(Page, Root, Prefix, NewFiles, Wik,
					   Filename, Content, DelFiles);
			Password ->
			    store_files_ok(Page, Root, Prefix, NewFiles, Wik,
					   Filename, Content, DelFiles);
			_ ->
			    show({invalid_password, shouldbe,
				  Pwd, was, Password})
		    end;
		_ ->
		    show({no_such_page,Page})
	    end
    end.


store_ok(Page, Root, Prefix, OldTxt,
	 {wik002,Pwd,Email,Time,Who,OldTxt,Files,Patches}) ->
    redirect({node, Page}, Prefix);
store_ok(Page, Root, Prefix, NewTxt,
	 {wik002,Pwd,Email,_Time,_Who,OldTxt,Files,Patches}) ->
    Patch = wiki_diff:diff(NewTxt, OldTxt),
    Time = {date(), time()},
    Who = "unknown",
    Patches1 = [{Patch,Time,Who}|Patches],
    Ds = {wik002,Pwd, Email,Time,Who,NewTxt,Files,Patches1},
    B = term_to_binary(Ds),
    {File,FileDir} = page2filename(Page, Root),
    file:write_file(File, B),
    redirect({node, Page}, Prefix).

store_files_ok(Page, Root, Prefix, NewFiles,
	       {wik002,Pwd,Email,_Time,_Who,Txt,Files,Patches},
	       FileName, Content, DelFiles) ->
    Time = {date(), time()},
    Who = "unknown",
    Ds = {wik002,Pwd, Email,Time,Who,Txt,NewFiles,Patches},
    B = term_to_binary(Ds),
    {File,FileDir} = page2filename(Page, Root),
    lists:foreach(fun({file,F,_,_}) ->
			  file:delete(Root++"/"++FileDir++"/"++F)
		  end, DelFiles),
    file:write_file(Root++"/"++FileDir++"/"++FileName, Content),
    file:write_file(File, B),
    redirect({node, Page}, Prefix).

showHistory(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,Pwd,Email,_Time,_Who,OldTxt,_Files,Patches} = 
		bin_to_wik002(Bin),
	    Links = reverse(mk_history_links(reverse(Patches), Page, 1)),
	    template("History",background("info"), "", Links);
	_ ->
	    show({no_such_page, Page})
    end.

redirect({node, Page}, Prefix) ->
    {redirect_local, Prefix++"showPage.yaws?node="++Page}.

mk_history_links([{C,Time,Who}|T], Page, N) ->
    [["<li>",i2s(N)," modified on <a href='showOldPage.yaws?node=",Page,
      "&index=",i2s(N),
     "'>",format_time(Time),"</a> size ", i2s(size(C)), " bytes",
     "\n"]|mk_history_links(T, Page, N+1)];
mk_history_links([], _, _) ->
    [].

format_time({{Year,Month,Day},{Hour,Min,Sec}}) ->
    [i2s(Year),"-",i2s(Month),"-",i2s(Day)," ",
     i2s(Hour),":",i2s(Min),":",i2s(Sec)].

allPages(_, Root, Prefix) ->
    Files = sort(files(Root, "*.wob")),
    template("All Pages", background("info"), "",
	     [h1("All Pages"),
	      p("This is a list of all pages known to the system."),
	      lists:map(fun(I) ->
				F = filename:basename(I, ".wob"),
				[wiki_to_html:format_link(F, Root),
				 "<br>"]
			end, 
			Files)]).

lastEdited(_, Root, Prefix) ->
    Files = sort(files(Root, "*.wob")),
    S = lists:flatten(lists:map(fun(I) ->
				  "~" ++ filename:basename(I, ".wob") ++"\n\n"
			  end, Files)),
    V = reverse(sort(
		  lists:map(fun(I) -> {last_edited_time(I), I} end, Files))),
    Groups = group_by_day(V),
    S1 = lists:map(fun({{Year,Month,Day},Fx}) ->
		     [p(),i2s(Year),"-",i2s(Month),"-",i2s(Day),"<p>",
		      "<ul>",
		      lists:map(fun(F) -> 
				  F1 = filename:basename(F, ".wob"),
				  J = wiki_to_html:format_link(F1, Root),
				  [J,"<br>"] end, Fx),
		      "</ul>"]
	     end, Groups),
    template("Last Edited", background("info"), "", 
	     [h1("Last Edited"),
	      p("These are the last edited files."),S1]).

group_by_day([]) ->
    [];
group_by_day([{{Day,Time}, File}|T]) ->
    {Stuff, T1} = collect_this_day(Day, T, [File]),
    T2 = group_by_day(T1),
    [Stuff|T2].

collect_this_day(Day, [{{Day,Time},File}|T], L) ->
    collect_this_day(Day, T, [File|L]);
collect_this_day(Day, T, L) ->
    {{Day,reverse(L)}, T}.

last_edited_time(File) ->
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,Pwd,_Email,Time,_Who,_Txt,_Files,_Patches} = 
		bin_to_wik002(Bin),
	    Time;
	_ ->
	    error
    end.
	
showOldPage(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Nt = getopt(index, Params),

    Index = list_to_integer(Nt),
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    Wik = {wik002,Pwd,_Email,_Time,_Who,Txt,Files,Patches} = 
		bin_to_wik002(Bin),
	    %% N = #patches to do
	    N = length(Patches) - Index + 1,
	    ThePatches = take(N, Patches),
	    TxtStr = wiki_diff:patchL(Txt, ThePatches),
	    W = wiki_split:str2wiki(TxtStr),
	    DeepStr = wiki_to_html:format_wiki(Page, W, Root),
	    DeepFiles = wiki_to_html:format_wiki_files(
			  Page, FileDir,Files, Root),
	    Form = form("POST", "noop.yaws",
			[textarea("text", 25, 75, TxtStr)]),
	    wiki_templates:template(Page, old_pic(), "",
				    [h1(Page),DeepStr,DeepFiles,"<hr>",Form]);
	_ ->
	    show({no_such_page, Page})
    end.

take(0, _) -> [];
take(N, [{P,_,_}|T]) -> [P|take(N-1, T)].

deletePage(Params,  Root, Prefix) ->
    Delete = getopt(delete, Params),
    N = getopt(node, Params),
    P = getopt(password, Params),

    if 
	Delete == undefined ->
	    deletePage(N, "", Root, Prefix);
	true ->
	    deletePage(N, P, Root, Prefix)
    end.

deletePage(Page, Password, Root, Prefix) ->

    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002, Pwd,_Email,_Time,_Who,TxtStr,_Files,_Patches} =
		bin_to_wik002(Bin),
	    case Pwd of 
		"" ->
		    delete1(Page, Password, TxtStr);
		Password ->
		    delete1(Page, Password, TxtStr);
		_ ->
		    template("Error", bgcolor("white"), "",
			 [
			  h1("Incorrect password"),
			  p("You have supplied an incorrect password"),
			  p("To find out the password fill in your "
			    "email address and click on <i>Show password</i>. "
			    " If you are "
			    "the registered "
			    "owner of this page then I will tell you "
			    "the password."),
			  form("POST", "sendMeThePassword.yaws",
			       [input("hidden", "node", Page),
				"email address:",
				input("text", "email", ""),
				input("submit", "send", "Show password")])
			 ])
		end;
	_ ->
	    show({no_such_page,Page})
    end.

delete1(Page, Password, Content) ->
    Txt = quote_lt(Content),
    template("Delete", background("info"), "",
	 [h1(Page),
	  p("Reconfirm deleting this page - hit the 'Delete' "
	    "button to permanently remove the page."),
	  form("POST", "finalDeletePage.yaws",
	       [input("submit", "finaldelete", "Delete"),
		input("hidden", "node", Page),
		input("hidden", "password", Password),
		p(),
		textarea("text", 25, 75, Txt),
		p(),
		hr()])]).

editPage(Params, Root, Prefix) ->
    Passwd = getopt(password, Params, ""),
    Node = getopt(node, Params), 

    editPage(Node, Passwd, Root, Prefix).

editPage(Page, Password, Root, Prefix) ->
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002, Pwd,_Email,_Time,_Who,TxtStr,Files,_Patches} =
		bin_to_wik002(Bin),
	    case Pwd of 
		"" ->
		    edit1(Page, Password, TxtStr);
		Password ->
		    edit1(Page, Password, TxtStr);
		_ ->
		    template("Error", bgcolor("white"), "",
			     [
			      h1("Incorrect password"),
			      p("You have supplied an incorrect "
				"password"),
			      p("To find out the the password fill "
				"in your email address and click on "
				"<i>Show password</i>. If you are "
				"the registered owner of this page "
				"then I will tell you the password."),
			      form("POST", "sendMeThePassword.yaws",
				   [input("hidden", "node", Page),
				    "email address:",
				    input("text", "email", ""),
				    input("submit", "send",
					  "Show password")])
			     ])
	    end;
	_ ->
	    show({no_such_page,Page})
    end.

edit1(Page, Password, Content) ->
    Txt = quote_lt(Content),
    template("Edit", background("info"), "",
	 [h1(Page),
	  p("Edit this page - when you have finished hit the 'Preview' "
	    "button to check your results."),
	  form("POST", "previewPage.yaws",
	       [textarea("text", 25, 75, Txt),
		p(),
		input("submit", "review", "preview"),
		input("hidden", "node", Page),
		input("hidden", "password", Password),
		hr()]),
	  form("POST", "deletePage.yaws",
	       [input("submit", "delete", "delete"),
		input("hidden", "node", Page),
		input("hidden", "password", Password),
		hr()])
	 ]).

sendMeThePassword(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Email = getopt(email, Params),

    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,Pwd,EmailOwner,_Time,_Who,_OldTxt,_Files,_Patches} =
		bin_to_wik002(Bin),
	    %% io:format("Here Email=~p EMailOwner=~p~n",[Email,EmailOwner]),
	    case Email of
		"" ->
		    template("Error", bgcolor("pink"), "",
			 [h1("Failure"),
			  p("This page has no associated email address")]);
		EmailOwner ->
		    mail(Page, Email, Pwd),
		    template("Ok",bgcolor("white"),"",
			 [h1("Success"),
			  p("The password has been mailed to "),
			  Email,
			  p("Have a nice day")]);
		Other ->
		    template("Error",bgcolor("pink"),"",
			 [h1("Failure"),
			  p("Incorrect email address")])
	    end;
	_ ->
	    show({no_such_file,Page})
    end.



editFiles(Params, Root, Prefix) ->
    N = getopt(node, Params),
    P = getopt(password, Params, ""),
    editFiles(N, P, Root, Prefix).

editFiles(Page, Password, Root, Prefix) ->
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002, Pwd,_Email,_Time,_Who,_TxtStr,Files,_Patches} =
		bin_to_wik002(Bin),
	    case Pwd of 
		"" ->
		    editFiles1(Page, Password, Root, Prefix);
		Password ->
		    editFiles1(Page, Password, Root, Prefix);
		_ ->
		    template("Error", bgcolor("white"), "",
			     [
			      h1("Incorrect password"),
			      p("You have supplied an incorrect "
				"password"),
			      p("To find out the the password fill "
				"in your email address and click on "
				"<i>Show password</i>. If you are "
				"the registered owner of this page "
				"then I will tell you the password."),
			      form("POST", "sendMeThePassword.yaws",
				   [input("hidden", "node", Page),
				    "email address:",
				    input("text", "email", ""),
				    input("submit", "send",
					  "Show password")])
			     ])
	    end;
	_ ->
	    show({no_such_page,Page})
    end.


editFiles1(Page, Password, Root, Prefix) ->
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,Pwd,_Email,_Time,_Who,_OldTxt,Files,_Patches} =
		bin_to_wik002(Bin),
	    CheckBoxes =
		lists:map(fun({file,Name,Description,_Content}) ->
				  ["<tr><td align=left valign=top "
				   "width=\"20%\">",
				   input("checkbox","cb_"++Name,"on"), Name,
				   "</td><td align=left valign=top>",
				   Description,
				   "</td></tr>\n"];
			     ({file,Name,_Content})  ->
				  ["<tr><td align=left valign=top>",
				   input("checkbox","cb_"++Name,"on"),Name,
				   "</td><td></td></tr>\n"]
			  end, lists:keysort(2,Files)),
	    wiki_templates:template("Edit", bgcolor("white"),"",
		     [h1(Page),
		      p("Edit this page - when you have finished hit the "
			"'Store' button to check your results."),
		      form("POST", "storeFiles.yaws",
			   [input("submit", "store", "Store"),
			    input("submit", "cancel", "Cancel"),
			    input("hidden", "node", Page),
			    input("hidden", "password", Password),
			    hr(),
			    "<table width=\"100%\"><tr>",
			    "<th align=left>Attach new file: ",
			    "<td align=left>",
			    input("file","attached","30"),"\n",
			    "<tr><th colspan=2 align=left>",
			    "Description: ","\n",
			    "<tr><td colspan=2 align=left>",
			    textarea("text", 10, 72,""),"\n",
			    "</table>",
			    p(),
			    hr(),
			    "Check files that you want to keep:",
			    p(),
			    "<table cellspacing=10 width = \"100%\">\n",
			    CheckBoxes,
			    "</table>\n",
			    p(),
			    hr()
			   ])]);
	Error ->
	    show({no_such_page, Page})
    end.

editTag(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Tag = getopt(tag, Params),

    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,Pwd,_Email,_Time,_Who,OldTxt,_Files,_Patches} =
		bin_to_wik002(Bin),
	    Wik = wiki_split:str2wiki(OldTxt),
	    {Type, Str} = wiki_split:getRegion(list_to_integer(Tag), Wik),
	    Str1 = case Type of 
		       open -> quote_lt(Str);
		       write_append -> ""
		   end,
	    wiki_templates:template("Edit", bgcolor("white"),"",
		     [h1(Page),
		      p("Edit this page - when you have finished hit the "
			"'Preview' button to check your results."),
		      form("POST", "previewTagged.yaws",
			   [input("submit", "review", "preview"),
			    input("hidden", "node", Page),
			    input("hidden", "tag", Tag),
			    p(),
			    textarea("text", 25, 75, Str1),
			    p(),
			    hr()])]);
	Error ->
	    show({no_such_page, Page})
    end.


previewPage(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Password = getopt(password, Params),
    Txt0 = getopt(text, Params),

    Txt = zap_cr(Txt0),
    Wik = wiki_split:str2wiki(Txt),
    template("Preview",background("info"),"",
	     [h1(Page),
	      p("If this page is ok hit the \"Store\" button "
		"otherwise return to the editing phase by clicking the back "
		"button in your browser."),
	      form("POST", "storePage.yaws",
		   [input("submit", "store", "Store"),
		    input("hidden", "node", Page),
		    input("hidden", "password", Password),
		    input("hidden", "txt", str2formencoded(Txt))]),
	      p(),hr(),h1(Page), 
	      wiki_to_html:format_wiki(Page, Wik, Root)]).

finalDeletePage(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Password = getopt(password, Params, ""),
    Txt0 = getopt(text, Params),
    
    {File,FileDir} = page2filename(Page, Root),
    case file:delete(File) of
	ok ->
	    wiki_templates:template("Page Deleted",background("info"),"",
		     [h1(Page),
		      p("Page has been permanently deleted."),
		      p("<a href='showPage.yaws?node=home'>Home</a>"),
		      hr()]);
	_ ->
	    wiki_templates:template("Error",background("info"),"",
		     [h1(Page),
		      p("Failed to delete page."),
		      hr()])
    end.

%% Preview Tagged
%% Tagged stuff is inside comment and append regions
%% We *dont* want any structure here

previewTagged(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Tag = getopt(tag, Params),
    Txt0 = getopt(text, Params),

    Txt = zap_cr(Txt0),
    %% we want this stuff to *only* be txt
    %% io:format("Here previewTagged:~p~n",[Txt]),
    case legal_flat_text(Txt) of
	true ->
	    wiki_templates:template("Preview",bgcolor("white"),"",
		     [p("If this region is ok hit the <i>Store</i> button "
			"otherwise return to the editing phase by clicking "
			"the back button in your browser."),
		      form("POST", "storeTagged.yaws",
			   [input("submit", "store", "Store"),
			    input("hidden", "node", Page),
			    input("hidden", "tag", Tag),
			    input("hidden", "txt", str2formencoded(Txt))]),
		      p(),hr(), 
		      wiki_to_html:format_wiki(Page,{txt,10000,Txt},Root)]);
	false ->
	    show({text_contains,'< or >', in_col_1_which_is_illegal})
    end.


%% Flat text is *not* allowed to contain <

legal_flat_text("<" ++ _) -> false;
legal_flat_text(X)        -> legal_flat_text1(X).
    
legal_flat_text1("\n<" ++ _) -> false;
legal_flat_text1("\n>" ++ _) -> false;
legal_flat_text1([_|T])      -> legal_flat_text1(T);
legal_flat_text1([])         -> true.
    
previewNewPage(Params, Root, Prefix) ->
    Page  = getopt(node, Params),
    P1    = getopt(password1, Params),
    P2    = getopt(password2, Params),
    Email = getopt(email, Params),
    Txt0  = getopt(text, Params),

    if 
	P1 == P2 ->
	    Txt = zap_cr(Txt0),
	    Wik = wiki_split:str2wiki(Txt),
	    template("Preview", bgcolor("white"),"",
		     [p("If this page is ok hit the \"Store\" button "
			"otherwise return to the editing phase by clicking "
			"the back button in your browser."),
		      form("POST", "storeNewPage.yaws",
			   [input("submit", "store", "Store"),
			    input("hidden", "node", Page),
			    input("hidden", "password", P1),
			    input("hidden", "email", str2formencoded(Email)),
			    input("hidden", "txt", str2formencoded(Txt))]),
		      wiki_to_html:format_wiki(Page, Wik, Root)]);
	true ->
	    show({passwords_differ,P1,P2})
    end.

zap_cr([$\r,$\n|T]) -> [$\n|zap_cr(T)];
zap_cr([H|T])       -> [H|zap_cr(T)];
zap_cr([])          -> [].

wikiZombies(_, Root, Prefix) ->
    wiki_utils:zombies(Root).

allRefsToMe(Params, Root, Prefix) ->
    Page = getopt(node, Params),

    wiki_utils:findallrefsto(Page, Root).


mail(Page, Email, Pwd) ->
    send(Email,"Wiki password",
	 "The password of " ++ Page ++ " is " ++ Pwd ++ "\n").

send(To, Subject, Data) ->
    {TmpFile, S} = open_tmp_file("/tmp", ".mail"),
    io:format(S, "To: <~s>~n", [To]),
    io:format(S, "Subject: ~s~n~n", [Subject]),
    io:format(S, "~s~n",[Data]),
    io:format(S, ".~nquit~n", []),
    file:close(S),
    io:format("sending ...~n", []),
    os:cmd("/usr/sbin/sendmail -t > /dev/null < " ++ TmpFile),
    file:delete(TmpFile).
                               
open_tmp_file(RootName, Suffix) ->
    open_tmp_file(10, RootName, Suffix).
 
open_tmp_file(0, _, Suffix) ->
    exit({cannot_open_a_temporay_file, Suffix});
open_tmp_file(N, RootName, Suffix) ->
    {_,_,M} = erlang:now(),
    FileName = RootName ++ "/" ++ integer_to_list(M) ++ Suffix,
    %% io:format("trying to open:~p~n", [FileName]),
    case file:open(FileName, write) of
        {ok, Stream} ->
            {FileName, Stream};
        {error, _} ->
            open_tmp_file(N-1, RootName, Suffix)
    end.      


ls(Root) ->
    Files = files(Root, "*.wob"),
    lists:map(fun(I) -> filename:basename(I, ".wob") end, Files).

%%

page2filename(Page, Root) ->
    {Root ++ "/" ++ Page ++ ".wob", Page ++ ".files"}.


%%

error(invalid_request) ->
    {html, "invalid request"}.

%%

bin_to_wik002(Bin) ->
    case binary_to_term(Bin) of
	{wik001,Pwd,Email,Time,Who,OldTxt,Patches} -> 
	    {wik002,Pwd,Email,Time,Who,OldTxt,[],Patches};
	{wik002,Pwd,Email,Time,Who,OldTxt,Files,Patches} ->
	    {wik002,Pwd,Email,Time,Who,OldTxt,Files,Patches}
    end.

bin_to_wik002(Root, FileDir, Bin) ->
    %% First check filedir for files, if empty use files from wob
    Wik = bin_to_wik002(Bin),
    case get_wiki_files(Root, FileDir) of
	[] ->
	    {wik002,_,_,_,_,_,Files,_} = Wik,
	    create_wiki_files(Root, FileDir, Files);
	_ ->
	    ok
    end,
    Wik.

%%

get_wiki_files(Root, FileDir) ->
    Dir = Root ++ "/" ++ FileDir,
    files(Dir, "*").

%%

create_wiki_files(Root, FileDir, Files) ->
    Dir = Root ++ "/" ++ FileDir,
    file:make_dir(Dir),
    F = fun({file,F,_D,C}) ->
		file:write_file(Dir++"/"++F, C);
	   ({file,F,C}) ->
		file:write_file(Dir++"/"++F, C)
	end,
    lists:foreach(F, Files),
    ok.

%%

old_pic() -> background("old").

background(F) ->
    ["<body background='", F, ".gif'>\n"].

table(Color, X) ->
    ["<table width=\"100%\"><tr><td bgcolor=\"", Color, "\">\n",
     X,"</td></tr></table>\n"].

mk_image_link(X, Img) ->
    ["<a href=\"", X, "\"><img border=0 src='",Img, "'></a>&nbsp;&nbsp;\n"].

banner_edit_link(File, "") ->
    mk_image_link("editPage.yaws?node=" ++ File, "editme.gif");
banner_edit_link(File, _) ->
    "".

banner_edit_files(File, "") ->
    mk_image_link("editFiles.yaws?node=" ++ File, "editfiles.gif");
banner_edit_files(File, _) ->
    "".

body_pic("") -> background("normal");
body_pic(_)  -> background("locked").

banner(File, Password) ->			    
    [table("#FFFFFF",
	   [
	    mk_image_link("showPage.yaws?node=home", "home.gif"),
	    mk_image_link("showHistory.yaws?node=" ++ File, "history.gif"),
	    mk_image_link("allPages.yaws", "allpages.gif"),
	    mk_image_link("lastEdited.yaws", "lastedited.gif"),
	    mk_image_link("wikiZombies.yaws", "zombies.gif"),
	    banner_edit_link(File, Password),
	    banner_edit_files(File, Password)])].

footer(File, "") ->
    "";
footer(File, _) ->
    [p(),hr(),
     p("This page is password protected. To edit the page enter "
       "the password and click on edit."),
     form("POST", "editPage.yaws",
	  [input("hidden", "node",File),
	   "Password:",
	   password_entry("password", 8),
	   input("submit", "submit", "Edit")]),
     form("POST", "editFiles.yaws",
	  [input("hidden", "node",File),
	   "Password:",
	   password_entry("password", 8),
	   input("submit", "submit", "Edit Files")])].

password_entry(Name, Size) ->
    ["<INPUT TYPE=password name=", Name,"  SIZE=", i2s(Size),">\n"].

input(Type="file", Name, Size) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Size=\"", Size, "\">\n"];
input(Type="checkbox", Name, Value) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Value=\"", Value, "\" checked>\n"];
input(Type, Name, Value) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Value=\"", Value, "\">\n"].

input(Type, Name, Value, Size) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Value=\"", Value,"\"",
     "Size=\"",Size, "\">\n"].


form(Method, Action, Args) ->
    ["<FORM METHOD=", Method,
     " ENCTYPE=\"multipart/form-data\"",
     " ACTION=\"", Action, "\">",
     Args, "</form>\n"].


textarea(Name, Row, Cols, Txt) ->
     ["<textarea name=", Name, " rows=", i2s(Row),
      " cols=", i2s(Cols), " wrap=virtual>",
      Txt, "</textarea>\n"].

h1(X)   -> ["<h1>",X,"</h1>"].

b(X)    -> ["<b>",X,"</b>"].

p() -> "<p>".
p(X) -> ["<p>", X, "</p>\n"].
br() -> ["<br>\n"].
hr() -> ["<hr>\n"].
body(X) -> ["<body bgcolor=\"", X, "\">"].
pre(X)  -> ["<pre>",X,"</pre>"].

i2s(I) -> integer_to_list(I).

initial_page_content() -> "\nEnter your text here\n".

bgcolor(C) ->
    ["<body bgcolor='", C, "'>\n"].


top_header(Page) ->
    F1 = add_blanks_nicely(Page),
    ["<h1><a href='allRefsToMe.yaws?node=",Page,"'>",F1,"</a></h1>\n"].

add_blanks_nicely([H1,H2|T]) ->
    case {little_letter(H1),
	 big_letter(H2)} of
	{true,true} ->
	    [H1,$ ,H2|add_blanks_nicely(T)];
	_ ->
	    [H1|add_blanks_nicely([H2|T])]
    end;
add_blanks_nicely([H|T]) ->
    [H|add_blanks_nicely(T)];
add_blanks_nicely([]) ->
    [].


big_letter(H) when $A =< H, H =< $Z -> true;
big_letter($�) -> true;
big_letter($�) -> true;
big_letter($�) -> true;
big_letter(_)  -> false.
    
little_letter(H) when $a =< H, H =< $z -> true;
little_letter($�) -> true;
little_letter($�) -> true;
little_letter($�) -> true;
little_letter(_)  -> false.

show(X) ->
    {html, [body("white"),"<pre>",
	    quote_lt(lists:flatten(io_lib:format("~p~n",[X]))),
	    "</pre>"]}.

show_error(Str) ->
    {html, [body("white"),"<pre>","Error: ",Str,"</pre>"]}.


quote_lt([$<|T]) -> "&lt;" ++ quote_lt(T);
quote_lt([H|T])  -> [H|quote_lt(T)];
quote_lt([])     -> [].

%%----------------------------
%% Utilities
%% Notes on the encoding of URI's
%% This comes from secition 8.2.1 of RFC1866

%% The default encoding for all forms is `application/x-www-form-urlencoded'.
%% A form data set is represented in this media type as follows:
%% 
%%   1. The form field names and values are escaped: space characters are
%%      replaced by `+', and then reserved characters are escaped as per [URL];
%%      that is, non-alphanumeric characters are replaced by `%HH', a percent
%%      sign and two hexadecimal digits representing the ASCII code of the
%%      character. Line breaks, as in multi-line text field values, are
%%      represented as CR LF pairs, i.e. `%0D%0A'.
%% 
%%   2. The fields are listed in the order they appear in the document with the
%%      name separated from the value by `=' and the pairs separated from each
%%      other by `&'. Fields with null values may be omitted. In particular,
%%      unselected radio buttons and checkboxes should not appear in the
%%      encoded data, but hidden fields with VALUE attributes present should.
%% 

str2urlencoded([$\n|T]) ->
    "%0D%0A" ++ str2urlencoded(T);
str2urlencoded([H|T]) ->
    case is_alphanum(H) of
	true ->
	    [H|str2urlencoded(T)];
	false ->
	    {Hi,Lo} = byte2hex(H),
	    [$%,Hi,Lo|str2urlencoded(T)]
    end;
str2urlencoded([]) -> [].

str2formencoded([$ |T]) ->
    [$+|str2formencoded(T)];
str2formencoded([$\n|T]) ->
    "%0D%0A" ++ str2formencoded(T);
str2formencoded([H|T]) ->
    case is_alphanum(H) of
	true ->
	    [H|str2formencoded(T)];
	false ->
	    {Hi,Lo} = byte2hex(H),
	    [$%,Hi,Lo|str2formencoded(T)]
    end;
str2formencoded([]) -> [].

byte2hex(X) ->
    {nibble2hex(X bsr 4), nibble2hex(X band 15)}.

nibble2hex(X) when X < 10 -> $0 + X;
nibble2hex(X) -> $A + X - 10.

is_alphanum(X) when $0 =< X, X =< $9 -> true;
is_alphanum(X) when $a =< X, X =< $z -> true;
is_alphanum(X) when $A =< X, X =< $Z -> true;
is_alphanum(_) -> false.


urlencoded2str([$%,Hi,Lo|T]) -> [decode_hex(Hi, Lo)|urlencoded2str(T)];
urlencoded2str([$+|T])       -> [$ |urlencoded2str(T)];
urlencoded2str([H|T])        -> [H|urlencoded2str(T)];
urlencoded2str([])           -> [].


%% decode_hex %%

decode_hex(Hex1, Hex2) ->
    hex2dec(Hex1)*16 + hex2dec(Hex2).

hex2dec(X) when X >=$0, X =<$9 -> X-$0;
hex2dec($A) -> 10;
hex2dec($B) -> 11;
hex2dec($C) -> 12;
hex2dec($D) -> 13;
hex2dec($E) -> 14;
hex2dec($F) -> 15;
hex2dec($a) -> 10;
hex2dec($b) -> 11;
hex2dec($c) -> 12;
hex2dec($d) -> 13;
hex2dec($e) -> 14;
hex2dec($f) -> 15.


%% 

files(Dir, Re) -> 
    Re1 = regexp:sh_to_awk(Re),
    find_files(Dir, Re1, []).

find_files(Dir, Re, L) -> 
    case file:list_dir(Dir) of
	{ok, Files} -> find_files(Files, Dir, Re, L);
	{error, _}  -> L
    end.

find_files([File|T], Dir, Re, L) ->
    FullName = Dir ++  [$/|File],
    case file_type(FullName) of
	regular ->
	    case regexp:match(FullName, Re) of
		{match, _, _}  -> 
		    find_files(T, Dir, Re, [FullName|L]);
		_ ->
		    find_files(T, Dir, Re, L)
	    end;
	_ -> 
	    find_files(T, Dir, Re, L)
    end;
find_files([], _, _, L) ->
    L.

file_type(File) ->
    case file:read_file_info(File) of
	{ok, Facts} ->
	    case element(3, Facts) of
		regular   -> regular;
		directory -> directory;
		_         -> error
	    end;
	_ ->
	    error
    end.

%%

read_page(Page, Root) ->
    {File,FileDir} = page2filename(Page, Root),
    %% io:format("Reading:~p~n",[Page]),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,_Pwd,_Email,_Time,_Who,OldTxt,_Files,_Patches} =
		bin_to_wik002(Bin),
	    {ok, OldTxt};
	_ ->
	    error
    end.

%%

mime_type(Name)  ->
    case lists:reverse(Name) of
	"cod."++_ ->
	    "application/octet-stream";
	"piz."++_ ->
	    "application/x-zip";
	"lmth."++_ ->
	    "text/html";
	"mth."++_ ->
	    "text/html";
	"fdp."++_ ->
	    "application/pdf";
	_ ->
	    "application/octet-stream"
    end.

%%

%% Applies the Funs in the list to the Args. Return the value of the
%% first Fun that returns a non-ok value, otherwise ok.

check_precon([],_Args) -> ok;
check_precon([F|Fs], Args) ->
    case apply(F,Args) of
	ok ->
	    check_precon(Fs, Args);
	NotOk ->
	    NotOk
    end.
    
%%

getopt(Key, KeyList) ->
    getopt(Key, KeyList, undefined).

getopt(Key, KeyList, Default) ->
    case lists:keysearch(Key, 1, KeyList) of
	false ->
	    Default;
	{value, Tuple} ->
	    element(2,Tuple)
    end.

getopt_options(Key, KeyList) ->
    case lists:keysearch(Key, 1, KeyList) of
	{value, Tuple} when size(Tuple) >= 3 ->
	    element(3,Tuple);
	_ ->
	    undefined
    end.

%

basename(FilePath) ->
    case string:rchr(FilePath, $\\) of
	0 ->
	    %% probably not a DOS name
	    filename:basename(FilePath);
	N ->
	    %% probably a DOS name, remove everything after last \
	    string:substr(FilePath, N+1)
    end.

