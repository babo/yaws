%    -*- Erlang -*- 
%    File:	wiki_yaws.erl  (~jb/work/wiki/src/wiki_yaws.erl)
%    Author:	Johan Bevemyr
%    Created:	Thu Jun 27 22:26:49 2002
%    Purpose:   Yaws support utilities

-module('wiki_yaws').
-author('jb@son.bevemyr.com').

-export([get_path_prefix/1]).


get_path_prefix(UrlPath) ->
    %% search for initial path part
    case string:rchr(UrlPath, $/) of
	0 ->
	    UrlPath;
	N ->
	    lists:sublist(UrlPath, N)
    end.

 
