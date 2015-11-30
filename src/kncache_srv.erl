-module(kncache_srv).

-behavior(gen_server).

-vsn('0.9.5').

-define(CACHE_SRV, kncache_srv).

%%
%% Gen server API
%%
-export([start_link/0,
         init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         code_change/3,
         terminate/2
        ]).

%%
%% Gen Server Impl
%%
start_link() ->
  gen_server:start_link({local, ?CACHE_SRV}, ?MODULE, [], []).

init([]) ->
  CacheMap = maps:new(), 
  {ok, CacheMap}.

%%
%% Handle calls
%%
handle_call(list, _From, CacheMap) ->
  {reply, maps:keys(CacheMap), CacheMap};

handle_call({info, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        TableName = table_name(Cache),
        Size = ets:info(TableName, size),
        Memory = ets:info(TableName, memory) * erlang:system_info(wordsize),
        Kbs = erlang:trunc(Memory / 100) / 10,
        TTL = ttl(Cache, CacheMap),
        [{size, Size}, {kbs, Kbs}, {ttl, TTL}]
    end,
    Cache, CacheMap);

handle_call({size, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        ets:info(table_name(Cache), size)
    end,
    Cache, CacheMap);

handle_call({ttl, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        ttl(Cache, CacheMap)
    end,
    Cache, CacheMap);

handle_call({get, Key, Cache}, From, CacheMap) ->
  handle_call({get, Key, undefined, Cache}, From, CacheMap);

handle_call({get, Key, ValueFun, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        case ets:lookup(table_name(Cache), Key) of
          [{Key, {Value, [{ttl, infinity}, _]}}] ->
            %% Infinite cached value. Just return value.
            {ok, Value};
          [{Key, {Value, [{ttl, TTL}, {time_ref, TimeRef}]}}] ->
            %% TTL cached value. Cancel the current timer.
            erlang:cancel_timer(TimeRef),
            %% Put value back in cache to refresh timer
            cache_put(Key, Value, TTL, Cache),
            {ok, Value};
          %% No cached value.
          [] ->
            case ValueFun of
              undefined ->
                %% No cached value and no Value Fun to generate one.
                undefined;
              _ ->
                %% Use Value Fun to generate a new value
                case ValueFun() of
                  {NewValue, TTL} ->
                    %% Value Fun specifies TTL
                    cache_put(Key, NewValue, TTL, Cache),
                    {ok, NewValue};
                  NewValue ->
                    %% Use Cache default TTL
                    cache_put(Key, NewValue, ttl(Cache, CacheMap), Cache),
                    {ok, NewValue}
                end
            end
        end
    end,
    Cache, CacheMap);

handle_call({peek, Key, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        case ets:lookup(table_name(Cache), Key) of
          [{Key, {Value, [{ttl, infinity}, _]}}] ->
          %% Infinite cached value
            {Value, [{expiry, never}, {ttl, infinity}]};
          [{Key, {Value, [{ttl, TTL}, {time_ref, TimeRef}]}}] ->
            case erlang:read_timer(TimeRef) of
              false ->
                {Value, [{exiry, expired}, {ttl, TTL}]};
              TimeLeft ->
                {Value, [{expiry, TimeLeft / 1000}, {ttl, TTL}]}
            end;
          [] ->
            undefined
        end
    end,
    Cache, CacheMap);

handle_call({remove, Key, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        cache_delete(Key, Cache, false)
    end,
    Cache, CacheMap);

handle_call({first, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        TableName = table_name(Cache),
        case ets:first(TableName) of
          '$end_of_table' ->
            empty;
          Key ->
            ets:lookup(TableName, Key)
        end
    end,
    Cache, CacheMap);

handle_call({keys, Cache}, From, CacheMap) ->
  MapFun = fun(K,_V) -> K end,
  handle_call({map, MapFun, Cache}, From, CacheMap);

handle_call({map, MapFun, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        ets:foldl(fun({K,V}, Acc) -> [MapFun(K,V)] ++ Acc end,
                  [],
                  table_name(Cache))
    end,
    Cache, CacheMap);

handle_call({match, KeyPattern, ValuePattern, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        ets:match(table_name(Cache), {KeyPattern, {ValuePattern, '_', '_'}})
    end,
    Cache, CacheMap);

handle_call({filter, PredFun, Cache}, _From, CacheMap) ->
  call_reply(
    fun() ->
        ets:foldl(
          fun({K,V}, Acc) ->
              case PredFun(K,V) of
                true ->
                  [{K,V}] ++ Acc;
                false ->
                  Acc
              end
          end,
          [],
          table_name(Cache))
    end,
    Cache, CacheMap);

handle_call(Req, _From, CacheMap) ->
  {reply, {invalid_request, Req}, CacheMap}.

%%
%% Handle casts
%%
handle_cast({make, Cache, TTL}, CacheMap) ->
  UpdatedCacheMap = make_cache(Cache, TTL, CacheMap),
  {noreply, UpdatedCacheMap};

handle_cast({make_caches, CacheList}, CacheMap) ->
  UpdatedCacheMap = lists:foldl(
                   fun({Cache, TTL}, Acc) ->
                       make_cache(Cache, TTL, Acc)
                   end,
                   CacheMap, CacheList),
  {noreply, UpdatedCacheMap};

handle_cast({ttl, Cache, TTL}, CacheMap) ->
  {noreply, maps:put(Cache, TTL, CacheMap)};

handle_cast({put, Key, Value, Cache}, CacheMap) ->
  cast_reply(
    fun() ->
        cache_put(Key, Value, ttl(Cache, CacheMap), Cache)
    end,
    Cache, CacheMap);

handle_cast({put, Key, Value, TTL, Cache}, CacheMap) ->
  cast_reply(
    fun() ->
        cache_put(Key, Value, TTL, Cache)
    end,
    Cache, CacheMap);

handle_cast({foreach, KVFun, Cache}, CacheMap) ->
  cast_reply(
    fun() ->
        ets:foldl(fun({K,V}, _Acc) ->
                      KVFun(K,V)
                  end,
                  undefined, table_name(Cache))
    end,
    Cache, CacheMap);

handle_cast({destroy, Cache}, CacheMap) ->
  case valid_cache(Cache, CacheMap) of
    true ->
      ets:delete(table_name(Cache)),
      {noreply, maps:remove(Cache, CacheMap)};
    false ->
      {noreply, CacheMap}
  end;

handle_cast({destroy, Key, Cache}, CacheMap) ->
  cast_reply(
    fun() ->
        cache_delete(Key, Cache, true)
    end,
    Cache, CacheMap);

handle_cast({flush, Cache}, CacheMap) ->
  cast_reply(
    fun() ->
        ets:delete_all_objects(table_name(Cache))
    end,
    Cache, CacheMap);

handle_cast(_Msg, CacheMap) ->
  {noreply, CacheMap}.

%%
%% Handle info
%%
handle_info({destroy, Key, Cache}, CacheMap) ->
  case valid_cache(Cache, CacheMap) of
    true ->
      ets:delete(table_name(Cache), Key);
    false ->
      skip
  end,
  {noreply, CacheMap};

handle_info(_Info, CacheMap) ->
  {noreply, CacheMap}.

%%
%% 
%%
terminate(_Reason, _CacheMap) ->
  ok.

code_change(_OldVsn, CacheMap, _Extra) ->
  {ok, CacheMap}.

%%
%% Internal functions
%%
make_cache(Cache, TTL, CacheMap) ->
  case valid_cache(Cache, CacheMap) of
    false ->
      TableName = table_name(Cache),
      ets:new(TableName, [named_table, public]),
      maps:put(Cache, TTL, CacheMap);
    true ->
      CacheMap
  end.

table_name(Cache) ->
  list_to_atom("kncache_" ++ atom_to_list(Cache)).

ttl(Cache, CacheMap) ->
  case maps:get(Cache, CacheMap) of
    0 ->
      infinity;
    TTL ->
      TTL
  end.

cache_put(Key, Value, TTL, Cache) ->
  TimeRef = case TTL of
              infinity ->
                undefined;
              _ ->
                erlang:send_after(TTL*1000, ?CACHE_SRV, {destroy, Key, Cache})
            end,
  ets:insert(table_name(Cache), {Key, {Value, [{ttl, TTL}, {time_ref, TimeRef}]}}),
  ok.

cache_delete(Key, Cache, Force) ->
  TableName = table_name(Cache),
  case ets:lookup(TableName, Key) of
    [{Key, {Value, [{ttl, infinity}, _]}}] ->
      %% Infinite TTL; only delete if force is true
      case Force of 
        true ->
          ets:delete(TableName, Key);
        false ->
          skip
      end,
      {ok, Value};
    [{Key, {Value, [{ttl, _}, {time_ref, TimeRef}]}}] ->
      erlang:cancel_timer(TimeRef),
      ets:delete(TableName, Key),
      {ok, Value};
    _ ->
      undefined
  end.

call_reply(Fun, Cache, CacheMap) ->
  case valid_cache(Cache, CacheMap) of
    true ->
      {reply, Fun(), CacheMap};
    false ->
      {reply, {invalid_cache, Cache}, CacheMap}
  end.

cast_reply(Fun, Cache, CacheMap) ->
  case valid_cache(Cache, CacheMap) of
    true ->
      Fun();
    false ->
      skip
  end,
  {noreply, CacheMap}.

valid_cache(Cache, CacheMap) ->
  case ets:info(table_name(Cache)) of
    undefined ->
      false;
    _ ->
      maps:is_key(Cache, CacheMap)
  end.          
  
