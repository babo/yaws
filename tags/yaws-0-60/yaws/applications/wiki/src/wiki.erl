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
	 previewNewPage/3, allRefsToMe/3, deletePage/3, 
	 editTag/3, finalDeletePage/3, storePage/3, putPassword/3,
	 storeNewPage/3, previewPage/3, previewTagged/3, copyFiles/3,
	 deleteFiles/3, addFile/3, storeTagged/3, fixupFiles/3,
	 sendMeThePassword/3, storeFiles/3, showOldPage/3,
	 changePassword/3, changePassword2/3]).

-export([show/1, ls/1, h1/1, read_page/2, p/1,
	 str2urlencoded/1, session_manager_init/2]).

-import(lists, [reverse/1, map/2, sort/1]).

-import(wiki_templates, [template/3]).

-include("../../../include/yaws_api.hrl").

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
		    wiki_templates:template(Page, 
					    banner(Page, Pwd),
					    [top_header(Page),DeepStr,
					     DeepFiles]);
		_ ->
		    NewSid = session_new(initial_page_content()),
		    redirect_create(Page, NewSid, Prefix)
	    end
    end.


fixupFiles(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    if
	Page == undefined ->
	    error(invalid_request);
	true ->
	    importFiles(Page, Root, Prefix)
    end.

importFiles(Page, Root, Prefix) ->
    {WobFile, FileDir} = page2filename(Page, Root),
    case file:read_file(WobFile) of
	{ok, Bin} ->
	    {wik002, Pwd,Email,Time,Who,TxtStr,Files,Patches} =
		bin_to_wik002(Root,FileDir,Bin),

	    CurFiles = files(Root++"/"++FileDir, "*"),

	    CurFileNames = [basename(CF) || CF <- CurFiles],

	    F = fun(Fn) ->
			case lists:keysearch(Fn,2,Files) of
			    {value, File} ->
				File;
			    false ->
				{file, Fn, "", []}
			end
		end,

	    NewFiles = [F(X) || X <- CurFileNames],

	    Ds = {wik002, Pwd,Email,Time,Who,TxtStr,NewFiles,Patches},
	    B = term_to_binary(Ds),
	    file:write_file(WobFile, B),
	    redirect({node, Page}, Prefix);
	_ ->
	    NewSid = session_new(initial_page_content()),
	    redirect_create(Page, NewSid, Prefix)
    end.


createNewPage(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Sid  = getopt(sid, Params),


    if 
	Sid /= undefined ->
	    {Txt,Passwd,Email} =
		session_get_all(Sid, initial_page_content(), "", ""),
	    createNewPage1(Page, Sid, Prefix, Txt, Passwd, Email);
	Sid == undefined ->
	    NewSid = session_new(initial_page_content()),
	    redirect_create(Page, NewSid, Prefix)
    end.

createNewPage1(Page, Sid, Prefix, Content, Passwd, Email) ->
    Txt = quote_lt(Content),
    wiki_templates:template(
      "New Page","",
      [h1(Page),
       p("Creating a new page. "
	 "If you want a password protected page "
	 "then fill in both the password fields - otherwise "
	 "leave them blank."),
       p("If you fill in the email field and forget the page password "
	 "then the system can mail you back the password of the page if "
	 "you forget it."),
       p("Click on 'Preview' when you are ready to store the page."),
       form("POST", "previewNewPage.yaws?sid="++str2urlencoded(Sid),
	    [input("submit", "review", "Preview"),
	     input("hidden", "node", Page),
	     hr(),
	     "<table>\n"
	     "<tr> <td align=left>Password: </td>",
	     "<td align=left> ", password_entry("password1", 8, Passwd),
	     "</td></tr>\n",
	     "<tr> <td align=left>Reconfirm password: </td>",
	     "<td align=left> ",password_entry("password2", 8, Passwd),
	     "</td></tr>\n",
	     "<tr> <td align=left>Email: </td>",
	     "<td align=left> ",
	     input("text","email",Email),
	     "</td></tr>\n",
	     "</table>\n",
	     p(),
	     textarea("text", 25, 72,Txt),
	     hr()
	    ])]).


storePage(Params, Root, Prefix) ->
    Password = getopt(password, Params, ""),
    Page     = getopt(node, Params), 
    Cancel   = getopt(cancel, Params),
    Edit     = getopt(edit, Params),
    Sid      = getopt(sid, Params),
    
    if 
	Cancel /= undefined ->
	    session_end(Sid),
	    redirect({node, Page}, Prefix);
	true  ->
	    case checkPassword(Page, Password, Root, Prefix) of
		true ->
		    if
			Edit /= undefined ->
			    Txt0 = getopt(txt, Params),
			    Txt = zap_cr(urlencoded2str(Txt0)),
			    session_set_text(Sid, Txt),
			    redirect_edit(Page, Sid, Password, Prefix);
			true ->
			    storePage1(Params, Root, Prefix)
		    end;
		false ->
		    show({bad_password, Page});
		error ->
		    show({no_such_page,Page})
	    end
    end.
    

storePage1(Params, Root, Prefix) ->
    Page     = getopt(node,Params),
    Txt0     = getopt(txt, Params),
    Sid      = getopt(sid, Params),

    Txt = zap_cr(urlencoded2str(Txt0)),

    session_end(Sid),
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    Wik = {wik002,Pwd,_Email,_Time,_Who,_OldTxt,_Files,_Patches} =
		bin_to_wik002(Bin),
	    store_ok(Page, Root, Prefix, Txt, Wik);
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
    case file:write_file(File, B) of
	ok ->redirect({node, Page}, Prefix);
	{error, Reason} ->
	    show({failed_to_create_page,file:format_error(Reason)})
    end.


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

    Page     = getopt(node, Params),
    Password = getopt(password, Params),
    Add      = getopt(add, Params),
    Update   = getopt(update, Params),
    Delete   = getopt(delete, Params),
    Copy     = getopt(copy, Params),
    Cancel   = getopt(cancel, Params),

    case checkPassword(Page, Password, Root, Prefix) of
	true ->
	    if
		Add /= undefined ->
		    addFileInit(Params, Root, Prefix);
		Update /= undefined ->
		    updateFilesInit(Params, Root, Prefix);
		Delete /= undefined ->
		    deleteFilesInit(Params, Root, Prefix);
		Copy /= undefined ->
		    copyFilesInit(Params, Root, Prefix);
		Cancel /= undefined ->
		    redirect({node, Page}, Prefix);
		true ->
		    show({no_such_page, Page})
	    end;
	false ->
	    getPassword(Page, Root, Prefix, storeFiles, Params);
	error ->
	    show({no_such_page,Page})
    end.

addFileInit(Params, Root, Prefix) ->
    Page        = getopt(node, Params),
    Password    = getopt(password, Params),
    template("Add File", "",
	     [h1(Page), 
	      form("POST", "addFile.yaws", 
		   [
		    input("hidden", "node", Page),
		    input("hidden", "password", Password),
		    "<table width=\"100%\"><tr>",
		    "<th align=left>Attach new file: ",
		    "<td align=left>",
		    input("file","attached","30"),"\n",
		    "<tr><th colspan=2 align=left>",
		    "Description: ","\n",
		    "<tr><td colspan=2 align=left>",
		    textarea("text", 10, 72,""),"\n",
		    "</table>",
		    input("submit", "add", "Add"),
		    input("button", "Cancel",
			  "parent.location='showPage.yaws?node="++
			  str2urlencoded(Page)++"'")])
	     ]).
    
-record(addfile, {
	  root,
	  prefix,
	  param,
	  password,
	  node,
	  text,
	  cancel,
	  fd,
	  last,
	  filename
	  }).


%%% addFile
%%% More than a bit messy due to the chunked arguments :-(

addFile(Arg, Root, Prefix) ->
    State = prepare_addFile_state(Arg#arg.state, Root, Prefix),
    case yaws_api:parse_multipart_post(Arg) of
	{cont, Cont, Res} ->
	    case addFileChunk(Res, State) of
		{done, Result} ->
		    Result;
		{cont, NewState} ->
		    {get_more, Cont, NewState}
	    end;
	{result, Res} ->
	    case addFileChunk(Res, State#addfile{last=true}) of
		{done, Result} ->
		    Result;
		{cont, _} ->
		    show({error_on_upload, State#addfile.node})
	    end
    end.
		

prepare_addFile_state(undefined, Root, Prefix) ->
    #addfile{root=Root, prefix=Prefix};
prepare_addFile_state(State, Root, Prefix) ->
    State#addfile{root=Root, prefix=Prefix}.

    
merge_body(undefined, Data) ->
    Data;
merge_body(Acc, New) ->
    Acc ++ New.



addFileChunk([{part_body, Data}|Res], State) ->
    addFileChunk([{body, Data}|Res], State);

addFileChunk([], State) when State#addfile.last==true,
			     State#addfile.filename /= undefined,
			     State#addfile.fd /= undefined ->
    Page        = State#addfile.node,
    {File,FileDir} = page2filename(Page, State#addfile.root),
    {ok, Bin}   = file:read_file(File),
    {wik002,Pwd,Email,_,_,Txt,OldFiles,Patches} = bin_to_wik002(Bin),
    Description = State#addfile.text,
    FileName    = State#addfile.filename,
    NewFile     = {file, FileName, Description, []},
    KeptOld     = lists:keydelete(FileName, 2, OldFiles),
    NewFiles    = [NewFile|KeptOld],
    Time        = {date(), time()},
    Who         = "unknown",
    Ds          = {wik002,Pwd, Email,Time,Who,Txt,NewFiles,Patches},
    B           = term_to_binary(Ds),
    file:write_file(File, B),
    Res = file:close(State#addfile.fd),
    {done, redirect({node, Page}, State#addfile.prefix)};
addFileChunk([], State) when State#addfile.last==true ->
    Page        = State#addfile.node,
    {done, show({error_in_upload, Page})};
addFileChunk([], State) ->
    {cont, State};

addFileChunk([{head, {add, _Opts}}|Res], State ) ->
    addFileChunk(Res, State#addfile{param = add});
addFileChunk([{body, Data}|Res], State) when State#addfile.param == add ->
    addFileChunk(Res, State);

addFileChunk([{head, {node, _Opts}}|Res], State ) ->
    addFileChunk(Res, State#addfile{param = node});
addFileChunk([{body, Data}|Res], State) when State#addfile.param == node ->
    Node = State#addfile.node,
    NewNode = merge_body(Node, Data),
    addFileChunk(Res, State#addfile{node = NewNode});

addFileChunk([{head, {password, _Opts}}|Res], State) ->
    addFileChunk(Res, State#addfile{param = password});
addFileChunk([{body, Data}|Res], State) when State#addfile.param == password ->
    Password = State#addfile.password,
    NewPW = merge_body(Password, Data),
    addFileChunk(Res, State#addfile{password = NewPW});

addFileChunk([{head, {cancel, _Opts}}|Res], State) ->
    {done, redirect({node, State#addfile.node}, State#addfile.prefix)};

addFileChunk([{head, {text, _Opts}}|Res], State) ->
    addFileChunk(Res, State#addfile{param = text});
addFileChunk([{body, Data}|Res], State) when State#addfile.param == text ->
    Text = State#addfile.text,
    NewText = merge_body(Text, Data),
    addFileChunk(Res, State#addfile{text = NewText});

addFileChunk([{head, {attached, Opts}}|Res], State) ->
    Page     = State#addfile.node,
    Password = State#addfile.password,
    FilePath = getopt(filename, Opts),
    FileName = basename(FilePath),
    Root     = State#addfile.root,
    Prefix   = State#addfile.prefix,
    {_,FileDir} = page2filename(Page, Root),
    Valid = check_filename(lists:reverse(FileName)),
    if
	Valid /= ok ->
	    {error, Reason} = Valid,
	    {done, show({illegal_filename, FileName, Reason})};
	FileName == "" ->
	    {done, show({empty_content, Page})};
	true ->
	    case checkPassword(Page, Password, Root, Prefix) of
		true ->
		    {ok, Fd} = file:open(Root++"/"++FileDir++"/"++
					 FileName, write),
		    addFileChunk(Res, State#addfile{fd=Fd,param=attached,
						    filename=FileName});
		false ->
		    {done, show({bad_password, Page})};
		error->
		    {done, show({no_such_page,Page})}
	    end
    end;
addFileChunk([{body, Data}|Res], State) when State#addfile.param == attached ->
    file:write(State#addfile.fd, Data),
    addFileChunk(Res, State).



check_filename("sway."++_) ->
    {error, "Files ending with .yaws files are not allowed."};
check_filename(FileName) ->
    case lists:any(fun(C) -> lists:member(C, FileName) end,
		   "$\\!%^&*[]~\"'`<>|/") of
	true ->
	    {error,
	     "Illegal character in file. "
	     "Please remove all of the following characters "
	     "$\\!%^&*[]~\"'`<>|/ from the filename."};
	false ->
	    ok
    end.

updateFilesInit(Params, Root, Prefix) ->
    Page = getopt(node, Params),

    Descriptions = [{lists:nthtail(4,atom_to_list(N)),S} ||
		       {N,S,_} <- Params,
		       lists:prefix("cbt_",atom_to_list(N))],

    {File,FileDir} = page2filename(Page, Root),
    {ok, Bin} = file:read_file(File),
    Wik = bin_to_wik002(Bin),
    {wik002,Pwd,Email,_Time, _Who,Txt,OldFiles,Patches} = Wik,

    %% Update description field of file entry
    UpdateDesc =
	fun({file, Fname, OldDesc, []}) ->
		case lists:keysearch(Fname, 1, Descriptions) of
		    {value, {_,NewDesc}} ->
			{file, Fname, NewDesc, []};
		    _ ->
			{file, Fname, OldDesc, []}
		end
	end,

    NewFiles = [UpdateDesc(F) || F <- OldFiles],
    
    Time = {date(), time()},
    Who = "unknown",
    Ds = {wik002,Pwd, Email,Time,Who,Txt,NewFiles,Patches},
    B = term_to_binary(Ds),
    file:write_file(File, B),
    redirect({node, Page}, Prefix).


deleteFilesInit(Params, Root, Prefix) ->

    Page        = getopt(node, Params),
    Password    = getopt(password, Params),

    CheckedFiles = [lists:nthtail(3,atom_to_list(N)) ||
		       {N,_,_} <- Params,
		       lists:prefix("cb_",atom_to_list(N))],

    {File,FileDir} = page2filename(Page, Root),
    {ok, Bin} = file:read_file(File),
    Wik = {wik002,Pwd,_Email,_Time, _Who,_Txt,Files,_Patches}
	= bin_to_wik002(Bin),
    
    Extend = fun({file, Name, Desc, _}) ->
		     {file, Name, Desc, []};
		({file, Name, _}) ->
		     {file, Name, "", []}
	     end,

    OldFiles = [ Extend(F) || F <- Files],

    DelFiles = [ {file, Name, Desc, []} || {file, Name, Desc, _} <- OldFiles,
					   lists:member(Name, CheckedFiles)],

    List =
	wiki_to_html:format_wiki_files(Page, FileDir,
				       lists:keysort(2,DelFiles), Root,
				       "The following files will be deleted "
				       "from " ++ Page ++ "."),

    DelList = [input("hidden", "del_"++Name, Name) ||
		  {file, Name, _, _} <- DelFiles],

    template("Confirm", "",
	     [h1(Page),
	      List,
	      form("POST", "deleteFiles.yaws", 
		   [DelList,
		    input("submit", "delete", "Delete"),
		    input("submit", "cancel", "Cancel"),
		    input("hidden", "node", Page),
		    input("hidden", "password", Password)])
	     ]).
    
deleteFiles(Params, Root, Prefix) ->
    Password = getopt(password, Params, ""),
    Page     = getopt(node, Params), 
    Cancel   = getopt(cancel, Params),
    
    if 
	Cancel /= undefined ->
	    redirect({node, Page}, Prefix);
	true  ->
	    case checkPassword(Page, Password, Root, Prefix) of
		true ->
		    deleteFiles1(Params, Root, Prefix);
		false ->
		    show({bad_password, Page});
		error ->
		    show({no_such_page,Page})
	    end
    end.

deleteFiles1(Params, Root, Prefix) ->
    Page        = getopt(node, Params),

    CheckedFiles = [lists:nthtail(4,atom_to_list(N)) ||
		       {N,_,_} <- Params,
		       lists:prefix("del_",atom_to_list(N))],

    {File,FileDir} = page2filename(Page, Root),
    {ok, Bin} = file:read_file(File),
    Wik = {wik002,Pwd,Email,_Time, _Who,Txt,Files,Patches}
	= bin_to_wik002(Bin),
    
    Extend = fun({file, Name, Desc, _}) ->
		     {file, Name, Desc, []};
		({file, Name, _}) ->
		     {file, Name, "", []}
	     end,

    OldFiles = [ Extend(F) || F <- Files],

    DelFiles = [ {file, Name, Desc, []} || {file, Name, Desc, _} <- OldFiles,
					   lists:member(Name, CheckedFiles)],
    NewFiles = [ {file, Name, Desc, []} ||
		   {file, Name, Desc, _} <- OldFiles,
		   not lists:member(Name, CheckedFiles)],

    Time = {date(), time()},
    Who = "unknown",
    Ds = {wik002,Pwd, Email,Time,Who,Txt,NewFiles,Patches},
    B = term_to_binary(Ds),
    lists:foreach(fun({file,F,_,_}) ->
			  file:delete(Root++"/"++FileDir++"/"++F)
		  end, DelFiles),
    file:write_file(File, B),
    redirect({node, Page}, Prefix).


copyFilesInit(Params, Root, Prefix) ->

    Page        = getopt(node, Params),
    Password    = getopt(password, Params),

    CheckedFiles = [lists:nthtail(3,atom_to_list(N)) ||
		       {N,_,_} <- Params,
		       lists:prefix("cb_",atom_to_list(N))],

    {File,FileDir} = page2filename(Page, Root),
    {ok, Bin} = file:read_file(File),
    Wik = {wik002,Pwd,_Email,_Time, _Who,_Txt,Files,Patches}
	= bin_to_wik002(Bin),
    
    Extend = fun({file, Name, Desc, _}) ->
		     {file, Name, Desc, []};
		({file, Name, _}) ->
		     {file, Name, "", []}
	     end,

    OldFiles = [ Extend(F) || F <- Files],

    CpFiles = [ {file, Name, Desc, []} || {file, Name, Desc, _} <- OldFiles,
					  lists:member(Name, CheckedFiles)],
    List =
	wiki_to_html:format_wiki_files(Page, FileDir,
				       lists:keysort(2,CpFiles), Root,
				       "The following files will be copied "
				       "from " ++ Page ++ "."),

    CpList = [input("hidden", "cp_"++Name, Name) ||
		 {file, Name, _, _} <- CpFiles],

    PageFiles = sort(files(Root, "*.wob")),
    Pages = [filename:basename(P,".wob") || P <- PageFiles, P /= File],
    
    if
	length(CheckedFiles) == 0 ->
	    editFiles(Params, Root, Prefix);
	true ->
	    template("Confirm", "",
		     [h1(Page),
		      List,
		      form("POST", "copyFiles.yaws", 
			   [CpList,
			    "Destination: ",
			    input("select","destination",Pages),
			    input("submit", "copy", "Copy"),
			    input("submit", "cancel", "Cancel"),
			    input("hidden", "node", Page),
			    input("hidden", "password", Password)])
		     ])
    end.

    
copyFiles(Params, Root, Prefix) ->
    Password = getopt(password, Params, ""),
    Page     = getopt(node, Params),
    Cancel   = getopt(cancel, Params),

    if
	Cancel /= undefined ->
	    redirect({node, Page}, Prefix);
	true ->
	    case checkPassword(Page, Password, Root, Prefix) of
		true ->
		    copyFiles1(Params, Root, Prefix);
		false ->
		    show({bad_password, Page});
		error ->
		    show({no_such_page,Page})
	    end
    end.

copyFiles1(Params, Root, Prefix) ->
    Page     = getopt(node, Params), 
    Dest     = getopt(destination, Params), 

    case checkPassword(Dest, "", Root, Prefix) of
	true ->
	    copyFiles3(Params, Root, Prefix);
	false ->
	    getPassword(Dest, Root, Prefix, copyFiles2, Params);
	error ->
	    show({no_such_page,Page})
    end.

copyFiles2(Params, Root, Prefix) ->
    Page     = getopt(node, Params), 
    Dest     = getopt(destination, Params), 
    Password = getopt(password, Params, ""),

    case checkPassword(Dest, Password, Root, Prefix) of
	true ->
	    copyFiles3(Params, Root, Prefix);
	false ->
	    show({bad_password, Page});
	error ->
	    show({no_such_page,Page})
    end.

copyFiles3(Params, Root, Prefix) ->
    Page     = getopt(node, Params), 
    Dest     = getopt(destination, Params), 
    
    {SrcWobFile, SrcFileDir} = page2filename(Page, Root),
    {DstWobFile, DstFileDir} = page2filename(Dest, Root),
    
    SrcFileNames = [lists:nthtail(3,atom_to_list(N)) ||
		       {N,S,_} <- Params,
		       lists:prefix("cp_",atom_to_list(N))],

    SrcDir = Root ++ "/" ++ SrcFileDir ++ "/",
    DstDir = Root ++ "/" ++ DstFileDir ++ "/",

    [os:cmd("cp '"++SrcDir++F++"' '"++DstDir++"'") || F <- SrcFileNames],
    importFiles(Dest, Root, Prefix).

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

showHistory(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,Pwd,Email,_Time,_Who,OldTxt,_Files,Patches} = 
		bin_to_wik002(Bin),
	    Links = reverse(mk_history_links(reverse(Patches), Page, 1)),
	    template("History", "", Links);
	_ ->
	    show({no_such_page, Page})
    end.

redirect({node, Page}, Prefix) ->
    {redirect_local, Prefix++"showPage.yaws?node="++str2urlencoded(Page)}.

redirect_edit(Page, Sid, Password, Prefix) ->
    UrlSid = str2urlencoded(Sid),
    UrlPW = str2urlencoded(Password),
    {redirect_local, Prefix++"editPage.yaws?node="++str2urlencoded(Page)++
     "&sid="++UrlSid++"&password="++UrlPW}.

redirect_create(Page, Sid, Prefix) ->
    UrlSid = str2urlencoded(Sid),
    {redirect_local, Prefix++"createNewPage.yaws?node="++str2urlencoded(Page)++
     "&sid="++UrlSid}.    

redirect_change(Page, Prefix) ->
    {redirect_local, Prefix++"changePassword.yaws?node="++
     str2urlencoded(Page)}.    

mk_history_links([{C,Time,Who}|T], Page, N) ->
    [["<li>",i2s(N)," modified on <a href='showOldPage.yaws?node=",
      str2urlencoded(Page),
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
    template("All Pages", "",
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
    template("Last Edited", "", 
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
	    wiki_templates:template(Page, "",
				    [h1(Page),DeepStr,DeepFiles,"<hr>",Form]);
	_ ->
	    show({no_such_page, Page})
    end.

take(0, _) -> [];
take(N, [{P,_,_}|T]) -> [P|take(N-1, T)].

deletePage(Params,  Root, Prefix) ->
    Page     = getopt(node, Params),
    Password = getopt(password, Params, ""),

    case checkPassword(Page, Password, Root, Prefix) of
	true ->
	    deletePage1(Params, Root, Prefix);
	false ->
	    show({bad_password, Page});
	error ->
	    show({no_such_page,Page})
    end.

deletePage1(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Password = getopt(password, Params),
    
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002, _Pwd,_Email,_Time,_Who,Content,_Files,_Patches} =
		bin_to_wik002(Bin),
    
	    Txt = quote_lt(Content),
	    template("Delete", "",
		     [h1(Page),
		      p("Reconfirm deleting this page - hit the 'Delete' "
			"button to permanently remove the page."),
		      form("POST", "finalDeletePage.yaws",
			   [input("submit", "finaldelete", "Delete"),
			    input("submit", "cancel", "Cancel"),
			    input("hidden", "node", Page),
			    input("hidden", "password", Password),
			    p(),
			    textarea("text", 25, 75, Txt),
			    p(),
			    hr()])]);
	_ ->
	    show({no_such_page,Page})
    end.

finalDeletePage(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Password = getopt(password, Params, ""),
    Cancel   = getopt(cancel, Params),

    if
	Cancel /= undefined ->
	    redirect({node, Page}, Prefix);
	true ->
	    case checkPassword(Page, Password, Root, Prefix) of
		true ->
		    finalDeletePage1(Params, Root, Prefix);
		false ->
		    show({bad_password, Page});
		error ->
		    show({no_such_page,Page})
	    end
    end.

finalDeletePage1(Params, Root, Prefix) ->
    Page = getopt(node, Params),
    Txt0 = getopt(text, Params),
    
    {File,FileDir} = page2filename(Page, Root),
    case file:delete(File) of
	ok ->
	    Files = files(Root++"/"++FileDir, "*"),
	    [file:delete(F) || F <- Files],
	    file:del_dir(Root++"/"++FileDir),
	    redirect({node, "home"}, Prefix);
	_ ->
	    wiki_templates:template("Error","",
		     [h1(Page),
		      p("Failed to delete page."),
		      hr()])
    end.


getPassword(Page, Root, Prefix, Target, Values) ->
    Vs = [{target, atom_to_list(Target), []}|
	  lists:keydelete(password, 1, Values)],
    Hidden = [[input("hidden", atom_to_list(Name), Value),"\n"] ||
		 {Name, Value, _} <- Vs],
    template("Password", "",
	     [h1(Page),
	      p("This page is password protected - provide a password"
		"and hit the 'Continue' button."),
	      form("POST", "putPassword.yaws","f",
		   (Hidden ++
		    [input("hidden", "target", atom_to_list(Target)),
		     "Password: ",
		     password_entry("password",8),
		     input("submit","continue","Continue"),
		     input("submit","cancel","Cancel"),
		     script("document.f.password.focus();")
		     ]
		   )
		  )
	     ]).

putPassword(Params, Root, Prefix) ->
    Target = getopt(target, Params, "error"),
    Cancel = getopt(cancel, Params),
    Page   = getopt(node, Params),

    if
	Cancel /= undefined ->
	    redirect({node, Page}, Prefix);
	true ->
	    case Target of
		"error" ->
		    show({no_such_target, Target});
		_ ->
		    apply(?MODULE,list_to_atom(Target),[Params, Root, Prefix])
	    end
    end.

editPage(Params, Root, Prefix) ->
    Password = getopt(password, Params, ""),
    Page     = getopt(node, Params),
    Sid      = getopt(sid, Params),

    case checkPassword(Page, Password, Root, Prefix) of
	true ->
	    editPage(Page, Password, Root, Prefix, Sid);
	false ->
	    getPassword(Page, Root, Prefix, editPage, Params);
	error ->
	    show({no_such_page,Page})
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Session manager
%%

-record(sid, {text="", password="", email=""}).


session_server_ensure_started() ->
    case whereis(wiki_session_manager) of
	undefined ->
	    Pid = spawn(?MODULE, session_manager_init, [0,[]]),
	    register(wiki_session_manager, Pid);
	_ ->
	    done
    end.

session_manager_init(N,Sessions) ->
    process_flag(trap_exit, true),
    session_manager(N,Sessions).

% Sessions = [{Pid, Sid}]
session_manager(N,Sessions) ->
    receive 
	{'EXIT', Pid, _} ->
	    NewS = lists:keydelete(Pid, 1, Sessions),
	    session_manager(N, NewS);
	{Sid, stop} ->
	    NewS = lists:keydelete(Sid, 2, Sessions),
	    case lists:keysearch(Sid, 2, Sessions) of
		{value, {Pid, Sid}} ->
		    Pid ! done;
		_  -> do_nothing
	    end,
	    session_manager(N,NewS);
	{new_sid, From, Txt, Passwd, Email} ->
	    Sid = integer_to_list(N),
	    Pid = spawn_link(?MODULE, session_proc,
			     [Sid,#sid{text=Txt,
				       password=Passwd,
				       email=Email}]),
	    From ! {session_id, Sid},
	    session_manager(N+1, [{Pid, Sid}|Sessions]);
	{new_sid, Sid, From, Txt, Passwd, Email} ->
	    case lists:keysearch(Sid, 2, Sessions) of
		{value, _} ->
		    From ! {session_id, Sid};
		_ ->
		    Pid = spawn_link(?MODULE, session_proc,
				     [Sid,#sid{text=Txt,
					       password=Passwd,
					       email=Email}]),
		    From ! {session_id, Sid},
		    session_manager(N, [{Pid, Sid}|Sessions])
	    end,
	    session_manager(N, Sessions);
	{to_sid, From, Sid, Msg} ->
	    case lists:keysearch(Sid, 2, Sessions) of
		{value, {Pid, Sid}} ->
		    Pid ! Msg;
		_ ->
		    From ! {unknown_sid, Sid}
	    end,
	    session_manager(N, Sessions);
	Unknown ->
	    session_manager(N, Sessions)
    end.
				    
session_proc(Sid,State) ->
    receive
	stop ->
	    exit(done);
	{set_text, From, NewTxt} ->
	    From ! {set, Sid},
	    session_proc(Sid,State#sid{text=NewTxt});
	{get_text, From} ->
	    From ! {text, Sid, State#sid.text},
	    session_proc(Sid,State);
	{set_all, From, NewTxt, NewPW, NewEmail} ->
	    From ! {set, Sid},
	    session_proc(Sid,State#sid{text=NewTxt,
				       password=NewPW,
				       email=NewEmail});
	{get_all, From} ->
	    From ! {all, Sid,
		    State#sid.text,
		    State#sid.password, State#sid.email},
	    session_proc(Sid,State)
    after
	3600000 ->   %% one hour
	    exit(timeout)
    end.

to_sm(Msg) ->
    session_server_ensure_started(),
    wiki_session_manager ! Msg.

session_end(undefined) -> done;
session_end(Sid) -> to_sm({to_sid, self(), Sid, stop}).
    
session_new(Txt) ->
    session_new(Txt, "", "").

session_new(Sid, Txt) ->
    session_new(Sid, Txt, "", "").

session_new(Txt, Passwd, Email) ->
    to_sm({new_sid, self(), Txt, Passwd, Email}),
    receive
	{session_id, Sid} -> Sid
    end.
session_new(Sid, Txt, Passwd, Email) ->
    to_sm({new_sid, Sid, self(), Txt, Passwd, Email}),
    receive
	{session_id, Sid} -> Sid
    end.
    
session_get_text(undefined, OldTxt) -> OldTxt;
session_get_text(Sid, OldTxt) ->
    to_sm({to_sid, self(), Sid, {get_text, self()}}),
    receive
	{text, Sid, Txt} ->
	    Txt;
	{unknown_sid, Sid} ->
	    session_new(Sid, OldTxt),
	    OldTxt
    end.

session_set_text(undefined, _) -> done;
session_set_text(Sid, Txt) ->
    to_sm({to_sid, self(), Sid, {set_text, self(), Txt}}),
    receive
	{set, Sid} -> done;
	{unknown_sid, Sid} ->
	    session_new(Sid, Txt)
    end.

session_get_all(undefined, Txt, Passwd, Email) -> {Txt,Passwd,Email};
session_get_all(Sid, Txt, Passwd, Email) ->
    to_sm({to_sid, self(), Sid, {get_all, self()}}),
    receive
	{all, Sid, OldTxt, OldPasswd, OldEmail} ->
	    {OldTxt, OldPasswd, OldEmail};
	{unknown_sid, Sid} ->
	    session_new(Sid, Txt, Passwd, Email),
	    {Txt, Passwd, Email}
    end.

session_set_all(undefined, _,_,_) -> done;
session_set_all(Sid, Txt, Passwd, Email) ->
    to_sm({to_sid, self(), Sid, {set_all, self(), Txt, Passwd, Email}}),
    receive
	{set, Sid} -> done;
	{unknown_sid, Sid} ->
	    session_new(Sid, Txt, Passwd, Email)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

editPage(Page, Password, Root, Prefix, Sid) ->
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002, Pwd,_Email,_Time,_Who,TxtStr,Files,_Patches} =
		bin_to_wik002(Bin),
	    if
		Sid /= undefined ->
		    OldTxt = session_get_text(Sid, TxtStr),
		    edit1(Page, Password, OldTxt, Sid);
		true ->
		    NewSid = session_new(TxtStr),
		    redirect_edit(Page, NewSid, Password, Prefix)
	    end;
	_ ->
	    show({no_such_page,Page})
    end.

edit1(Page, Password, Content, Sid) ->
    Txt = quote_lt(Content),
    template("Edit", "",
	 [h1(Page),
	  p("Edit this page - when you have finished hit the 'Preview' "
	    "button to check your results."),
	  form("POST", "previewPage.yaws?sid="++str2urlencoded(Sid),
	       "f1",
	       [textarea("text", 25, 75, Txt),
		p(),
		input("submit", "preview", "Preview"),
		input("submit", "delete", "Delete"),
		input("submit", "cancel", "Cancel"),
		input("submit", "chpasswd", "Password"),
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
		    template("Error", "",
			 [h1("Failure"),
			  p("This page has no associated email address")]);
		EmailOwner ->
		    mail(Page, Email, Pwd),
		    template("Ok", "",
			 [h1("Success"),
			  p("The password has been mailed to "),
			  Email,
			  p("Have a nice day")]);
		Other ->
		    template("Error", "",
			 [h1("Failure"),
			  p("Incorrect email address")])
	    end;
	_ ->
	    show({no_such_file,Page})
    end.


checkPassword(Page, Password, Root, Prefix) ->
    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002, Pwd,_Email,_Time,_Who,_TxtStr,Files,_Patches} =
		bin_to_wik002(Bin),
	    case Pwd of 
		""       -> true;
		Password -> true;
		_        -> false
	    end;
	_ ->
	    error
    end.

editFiles(Params, Root, Prefix) ->
    Page     = getopt(node, Params),
    Password = getopt(password, Params, ""),

    case checkPassword(Page, Password, Root, Prefix) of
	true ->
	    editFiles1(Page, Password, Root, Prefix);
	false ->
	    getPassword(Page, Root, Prefix, editFiles, Params);
	error ->
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
				  ["<tr><td align=left valign=top>",
				   input("checkbox","cb_"++Name,"on", ""),
				   Name, 
				   "</td><td width='70%' align=left "
				   "valign=top>",
				   textarea("cbt_"++Name, 2, 20, Description),
				   "</td></tr>\n"];
			     ({file,Name,_Content})  ->
				  ["<tr><td align=left valign=top>",
				   input("checkbox","cb_"++Name,"on", ""),
				   Name,
				   "</td><td width='70%' align=left "
				   "valign=top>",
				   textarea("cbt_"++Name, 2, 20, ""),
				   "</td></tr>\n"]
			  end, lists:keysort(2,Files)),
	    Check = ["Check files that you want to operate on:",
		     p(),
		     "<table cellspacing=10 width = \"100%\">\n",
		     CheckBoxes,
		     "</table>\n",
		     p(),
		     hr()],
	    wiki_templates:template("Edit", "",
		     [h1(Page),
		      form("POST", "storeFiles.yaws",
			   [Check,
			    input("submit", "add", "Add"),
			    input("submit", "update", "Update"),
			    input("submit", "delete", "Delete"),
			    input("submit", "copy", "Copy"),
			    input("submit", "cancel", "Cancel"),
			    input("hidden", "node", Page),
			    input("hidden", "password", Password)
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
	    wiki_templates:template("Edit", "",
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

changePassword(Params, Root, Prefix) ->
    Page     = getopt(node, Params),

    wiki_templates:template(
      "Edit", "",
      [h1(Page),
       p("Change password setting for page - to remove a password leave "
	 "the new passwords blank."),
       form("POST", "changePassword2.yaws?node="++
	    str2urlencoded(Page), "f",
	    ["<table>\n"
	     "<tr> <td align=left> Old password: </td>"
	     "<td aligh=left> ", password_entry("password", 8),
	     "</td></tr>\n"
	     "<tr> <td align=left>New password: </td>"
	     "<td aligh=left> ", password_entry("password1", 8),
	     "</td></tr>\n"
	     "<tr> <td align=left>Reconfirm password: </td>"
	     "<td aligh=left> ", password_entry("password2", 8),
	     "</td></tr>\n"
	     "</table>",
	     input("submit", "change", "Change"),
	     script("document.f.password.focud();")
	    ]
	   )
      ]).


changePassword2(Params, Root, Prefix) ->
    Page     = getopt(node, Params),
    OldPw    = getopt(password, Params),
    Pw1      = getopt(password1, Params),
    Pw2      = getopt(password2, Params),

    {File,FileDir} = page2filename(Page, Root),
    case file:read_file(File) of
	{ok, Bin} ->
	    {wik002,Pwd,Email,Time,Who,Txt,Files,Patches} =
		bin_to_wik002(Bin),
	    if
		OldPw == Pwd ->
		    if
			Pw1 == Pw2 ->
			    Ds = {wik002,Pw1,Email,Time,Who,Txt,Files,Patches},
			    B = term_to_binary(Ds),
			    file:write_file(File, B),
			    redirect({node, Page}, Prefix);
			true ->
			    show({password_mismatch, Page})
		    end;
		 true ->
		    show({bad_password, Page})
	    end;
	Error ->
	    show({no_such_page, Page})
    end.

previewPage(Params, Root, Prefix) ->
    Page     = getopt(node, Params),
    Cancel   = getopt(cancel, Params),
    Delete   = getopt(delete, Params),
    Change   = getopt(chpasswd, Params),
    Sid      = getopt(sid, Params),

    if
	Cancel /= undefined ->
	    session_end(Sid),
	    redirect({node, Page}, Prefix);
	Delete /= undefined ->
	    session_end(Sid),
	    deletePage(Params, Root, Prefix);
	Change /= undefined ->
	    session_end(Sid),
	    redirect_change(Page, Prefix);
	true ->
	    previewPage1(Params, Root, Prefix)
    end.

previewPage1(Params, Root, Prefix) ->
    Page     = getopt(node, Params),
    Password = getopt(password, Params),
    Txt0     = getopt(text, Params),
    Sid      = getopt(sid, Params,"undefined"),
    
    Txt = zap_cr(Txt0),
    Wik = wiki_split:str2wiki(Txt),
    session_set_text(Sid, Txt),
    template("Preview","",
	     [h1(Page),
	      p("If this page is ok hit the \"Store\" button "
		"otherwise return to the editing phase by clicking the edit "
		"button."),
	      form("POST", "storePage.yaws?sid="++str2urlencoded(Sid),
		   [input("submit", "store", "Store"),
		    input("submit", "cancel", "Cancel"),
		    input("submit", "edit", "Edit"),
		    input("hidden", "node", Page),
		    input("hidden", "password", Password),
		    input("hidden", "txt", str2formencoded(Txt))]),
	      p(),hr(),h1(Page), 
	      wiki_to_html:format_wiki(Page, Wik, Root, preview)]).

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
	    wiki_templates:template("Preview","",
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
    Sid   = getopt(sid, Params),

    Txt = zap_cr(Txt0),
    Wik = wiki_split:str2wiki(Txt),
    session_set_text(Sid, Txt),
    if 
	P1 == P2 ->
	    session_set_all(Sid,Txt,P1,Email),
	    template("Preview", "",
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

table(Id, X) ->
    ["<table width=\"100%\"><tr><td id=\"", Id, "\">\n",
     X,"</td></tr></table>\n"].

mk_image_link(X, Img, Alt) ->
    ["<a href=\"", X, "\"><img border=0 src='",Img, "' alt='",Alt,"'>"
     "</a>&nbsp;&nbsp;\n"].

mk_image_link(X, Img, Alt, Title) ->
    ["<a href=\"", X, "\"><img border=0 src='",Img, "' ",
     "alt='", Alt, "' "
     "title='", Title,"'></a>&nbsp;&nbsp;\n"].

banner(File, Password) ->			    
    [table("menu",
	   [
	    mk_image_link("showPage.yaws?node=home",
			  "WikiPreferences.files/home.gif", "Home",
			  "Go to initial page"),
	    mk_image_link("showHistory.yaws?node=" ++ str2urlencoded(File),
			  "WikiPreferences.files/history.gif",
			  "History",
			  "History of page evolution"),
	    mk_image_link("allPages.yaws",
			  "WikiPreferences.files/allpages.gif",
			  "All Pages",
			  "Lists all pages on this site"),
	    mk_image_link("lastEdited.yaws",
			  "WikiPreferences.files/lastedited.gif",
			  "Last Edited",
			  "Site editing history"),
	    mk_image_link("wikiZombies.yaws",
			  "WikiPreferences.files/zombies.gif",
			  "Zombies",
			  "Unreachable pages"),
	    mk_image_link("editPage.yaws?node=" ++ str2urlencoded(File),
			  "WikiPreferences.files/editme.gif",
			  "Edit Me",
			  "Edit this page"),
	    mk_image_link("editFiles.yaws?node=" ++ str2urlencoded(File),
			  "WikiPreferences.files/editfiles.gif",
			  "Edit Files",
			  "Edit attached files")
	   ])].

password_entry(Name, Size) ->
    ["<INPUT TYPE=password name=", Name,"  SIZE=", i2s(Size),">\n"].

password_entry(Name, Size, Value) ->
    ["<INPUT TYPE=password name=", Name,"  SIZE=", i2s(Size),
     " Value=\"", Value, "\">\n"].

input(Type="button", Name, OnClick) ->
    ["<INPUT TYPE=",Type,"  Value=\"",Name,"\" onClick=\"", OnClick, "\">\n"];
input(Type="file", Name, Size) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Size=\"", Size, "\">\n"];
input(Type="checkbox", Name, Value) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Value=\"", Value,
     "\" checked>\n"];
input("select", Name, Values) ->
    Options = ["<option> " ++ Option || Option <- Values],
    ["<select Name=\"",Name,"\">\n", Options,
     "</select>\n"];
input(Type, Name, Value) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Value=\"", Value, "\">\n"].

input(Type="checkbox", Name, Value, State) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Value=\"", Value,
     "\" " ++ State ++ ">\n"];
input(Type, Name, Value, Size) ->
    ["<INPUT TYPE=",Type,"  Name=\"",Name,"\" Value=\"", Value,"\"",
     "Size=\"",Size, "\">\n"].

script(Script) ->
    ["<script>\n", Script, "\n</script>\n"].

form(Method, Action, Args) ->
    ["<FORM METHOD=", Method,
     " ENCTYPE=\"multipart/form-data\"",
     " ACTION=\"", Action, "\">",
     Args, "</form>\n"].

form(Method, Action, Name, Args) ->
    ["<FORM METHOD=", Method,
     " ENCTYPE=\"multipart/form-data\"",
     " ACTION=\"", Action, "\" NAME=\"", Name, "\">",
     Args, "</form>\n"].


textarea(Name, Row, Txt) ->
     ["<textarea name=\"", Name, "\" rows=", i2s(Row),
      " wrap=virtual>", Txt, "</textarea>\n"].

textarea(Name, Row, Cols, Txt) ->
     ["<textarea name=\"", Name, "\" rows=", i2s(Row),
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
    ["<h1><a href='allRefsToMe.yaws?node=",str2urlencoded(Page),
     "'>",F1,"</a></h1>\n"].

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

show({bad_password, Page}) ->
    template("Error", "",
	     [h1("Incorrect password"),
	      p("You have supplied an incorrect password"),
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
	     ]);

show({illegal_filename, FileName, Reason}) ->
    template("Error", "",
	     [h1("Illegal filename"),
	      p("You have supplied an illegal filename: " ++ FileName ++ "."),
	      p(Reason)]);

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


str2fileencoded([$_|T]) ->
    [$_|str2fileencoded(T)];
str2fileencoded([$ |T]) ->
    [$ |str2fileencoded(T)];
str2fileencoded([$.|T]) ->
    [$.|str2fileencoded(T)];
str2fileencoded([H|T]) ->
    case is_alphanum(H) of
	true ->
	    [H|str2fileencoded(T)];
	false ->
	    {Hi,Lo} = byte2hex(H),
	    [$%,Hi,Lo|str2fileencoded(T)]
    end;
str2fileencoded([]) -> [].

fileencoded2str(Str) ->
    urlencoded2str(Str).


str2urlencoded([$\n|T]) ->
    "%0D%0A" ++ str2urlencoded(T);
str2urlencoded([$.|T]) ->
    "." ++ str2urlencoded(T);
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
str2formencoded([$.|T]) ->
    [$.|str2formencoded(T)];
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
	    Val = element(2,Tuple),
	    if 
		Val == undefined -> Default;
		true -> Val
	    end
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
