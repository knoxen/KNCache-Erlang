-module(kncache).

-define(CACHE_SRV, kncache_srv).

%%
%% Cache API
%%
-export([make/1
        ,make/2
        ,make_caches/1
        ,list/0
        ,info/1
        ,info/2
        ,size/1
        ,ttl/1
        ,ttl/2
        ,first/1
        ,keys/1
        ,put/3
        ,put/4
        ,get/2
        ,get/3
        ,delete/2
        ,flush/1
        ,destroy/1
        ,destroy/2
        ,foreach/2
        ,map/2
        ,match/3
        ]).

%%
%% 
%%

make(Cache) ->
  gen_server:cast(?CACHE_SRV, {make, Cache, infinity}).

make(Cache, TTL) ->
  gen_server:cast(?CACHE_SRV, {make, Cache, TTL}).

make_caches(CacheList) ->
  gen_server:cast(?CACHE_SRV, {make_caches, CacheList}).

%% List of {Cache, TTL} terms
list() ->
  gen_server:call(?CACHE_SRV, list).

%% Cache TTL (in seconds)
ttl(Cache) ->
  gen_server:call(?CACHE_SRV, {ttl, Cache}).

%% Set cache TTL (in seconds)
ttl(Cache, TTL) ->
  gen_server:cast(?CACHE_SRV, {ttl, Cache, TTL}).

first(Cache) ->
  gen_server:call(?CACHE_SRV, {first, Cache}).

keys(Cache) ->
  gen_server:call(?CACHE_SRV, {keys, Cache}).

%% 
info(Cache) ->
  gen_server:call(?CACHE_SRV, {info, Cache}).

info(Key, Cache) ->
  gen_server:call(?CACHE_SRV, {info, Key, Cache}).

size(Cache) ->
  gen_server:call(?CACHE_SRV, {size, Cache}).

put(Key, Value, Cache) ->
  gen_server:cast(?CACHE_SRV, {put, Key, Value, Cache}).

put(Key, Value, TTL, Cache) ->
  gen_server:cast(?CACHE_SRV, {put, Key, Value, TTL, Cache}).

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

foreach(KVFun, Cache) ->
  gen_server:cast(?CACHE_SRV, {foreach, KVFun, Cache}).

map(KVFun, Cache) ->
  gen_server:call(?CACHE_SRV, {map, KVFun, Cache}).

match(KeyPattern, ValuePattern, Cache) ->
  gen_server:call(?CACHE_SRV, {match, KeyPattern, ValuePattern, Cache}).
