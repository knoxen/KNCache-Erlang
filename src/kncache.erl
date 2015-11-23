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
        ,size/1
        ,ttl/1
        ,ttl/2
        ,first/1
        ,put/3
        ,put/4
        ,get/2
        ,get/3
        ,delete/2
        ,flush/1
        ,destroy/1
        ,destroy/2
        ]).

%%
%% 
%%

make(Caches) ->
  gen_server:call(?CACHE_SRV, {make, Caches}).

make(Cache, TTL) ->
  gen_server:call(?CACHE_SRV, {make, Cache, TTL}).

%% List of {Cache, TTL} terms
list() ->
  gen_server:call(?CACHE_SRV, list).

%% Cache TTL (in seconds)
ttl(Cache) ->
  gen_server:call(?CACHE_SRV, {ttl, Cache}).

%% Set cache TTL (in seconds)
ttl(Cache, TTL) ->
  gen_server:call(?CACHE_SRV, {ttl, Cache, TTL}).

first(Cache) ->
  gen_server:call(?CACHE_SRV, {first, Cache}).

%% 
info(Cache) ->
  gen_server:call(?CACHE_SRV, {info, Cache}).

info(Key, Cache) ->
  gen_server:call(?CACHE_SRV, {info, Key, Cache}).

size(Cache) ->
  gen_server:call(?CACHE_SRV, {size, Cache}).

put(Key, Value, Cache) ->
  gen_server:call(?CACHE_SRV, {put, Key, Value, Cache}).

put(Key, Value, TTL, Cache) ->
  gen_server:call(?CACHE_SRV, {put, Key, Value, TTL, Cache}).

get(Key, Cache) ->
  gen_server:call(?CACHE_SRV, {get, Key, Cache}).

get(Key, ValueFn, Cache) ->
  gen_server:call(?CACHE_SRV, {get, Key, ValueFn, Cache}).

delete(Key, Cache) ->
  gen_server:call(?CACHE_SRV, {delete, Key, Cache}).

flush(Cache) ->
  gen_server:call(?CACHE_SRV, {flush, Cache}).

destroy(Cache) ->
  gen_server:cast(?CACHE_SRV, {destroy, Cache}).

destroy(Key, Cache) ->
  gen_server:cast(?CACHE_SRV, {destroy, Key, Cache}).




