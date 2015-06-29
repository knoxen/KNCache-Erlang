-module(kncache).

-define(CACHE_SRV, kncache_srv).

%%
%% Cache API
%%
-export([make/1
        ,make/2
        ,list/0
        ,info/1
        ,info/2
        ,retain_secs/1
        ,retain_secs/2
        ,first/1
        ,put/3
        ,get/2
        ,get/3
        ,delete/2
        ,flush/1
        ]).

%%
%% 
%%

make(Caches) ->
  gen_server:call(?CACHE_SRV, {make, Caches}).

make(Cache, Retain) ->
  gen_server:call(?CACHE_SRV, {make, Cache, Retain}).

%% List of {Cache, Retain} terms
list() ->
  gen_server:call(?CACHE_SRV, list).

%% The number of seconds a cache's values are retained
retain_secs(Cache) ->
  gen_server:call(?CACHE_SRV, {retain, Cache}).

%% Set the number of seconds a cache's values are retained
retain_secs(Cache, Retain) ->
  gen_server:call(?CACHE_SRV, {retain, Cache, Retain}).

first(Cache) ->
  gen_server:call(?CACHE_SRV, {first, Cache}).

%% 
info(Cache) ->
  gen_server:call(?CACHE_SRV, {info, Cache}).

info(Cache, Key) ->
  gen_server:call(?CACHE_SRV, {info, Cache, Key}).

put(Cache, Key, Value) ->
  gen_server:call(?CACHE_SRV, {put, Cache, Key, Value}).

get(Cache, Key) ->
  gen_server:call(?CACHE_SRV, {get, Cache, Key}).

get(Cache, Key, ValueFn) ->
  gen_server:call(?CACHE_SRV, {get, Cache, Key, ValueFn}).

%% Flush contents of cache
flush(Cache) ->
  gen_server:call(?CACHE_SRV, {flush, Cache}).

delete(Cache, Key) ->
  gen_server:cast(?CACHE_SRV, {delete, Cache, Key}).
