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
  Caches = maps:new(), 
  {ok, Caches}.

%%
%% Handle calls
%%
handle_call(list, _From, Caches) ->
  {reply, maps:keys(Caches), Caches};

handle_call({info, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        TableName = table_name(Cache),
        Size = ets:info(TableName, size),
        Memory = ets:info(TableName, memory) * erlang:system_info(wordsize),
        Kbs = erlang:trunc(Memory / 100) / 10,
        TTL = ttl(Cache, Caches),
        [{size, Size}, {kbs, Kbs}, {ttl, TTL}]
    end,
    Cache, Caches);

handle_call({info, Key, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        case ets:lookup(table_name(Cache), Key) of
          [{Key, {{time_ref, TimeRef}, {ttl, TTL}, {value, _Val}}}] ->
            case erlang:read_timer(TimeRef) of
              false ->
                {exiry, expired};
              TimeLeft ->
                {{expiry, TimeLeft / 1000}, {ttl, TTL}}
            end;
          %% Infinite cached value
          [{Key, _Val}] ->
            {expiry, infinity};
          [] ->
            undefined
        end
    end,
    Cache, Caches);

handle_call({size, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        ets:info(table_name(Cache), size)
    end,
    Cache, Caches);

handle_call({ttl, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        ttl(Cache, Caches)
    end,
    Cache, Caches);

handle_call({get, Key, Cache}, From, Caches) ->
  ValueFn = fun() -> undefined end,
  handle_call({get, Key, ValueFn, Cache}, From, Caches);

handle_call({get, Key, ValueFn, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        case ets:lookup(table_name(Cache), Key) of
          %% Cached value scheduled for deletion
          [{Key, {{time_ref, TimeRef}, {ttl, TTL}, {value, Value}}}] ->
            %% Cancel the current timer
            erlang:cancel_timer(TimeRef),
            %% Put the value back in the cache to start a new timer
            cache_put(Key, Value, TTL, Cache),
            {ok, Value};
          %% Infinite cached value
          [{Key, Value}] ->
            {ok, Value};
          %% Generate, cache, and return a new value
          [] ->
            %% Generate value and insert into cache unless undefined
            case ValueFn() of
              undefined ->
                undefined;
              {NewValue, TTL} ->
                %% Cache and return newly created value
                cache_put(Key, NewValue, TTL, Cache),
                {ok, NewValue};
              NewValue ->
                %% Cache and return newly created value
                cache_put(Key, NewValue, ttl(Cache, Caches), Cache),
                {ok, NewValue}
            end
        end
    end,
    Cache, Caches);

handle_call({delete, Key, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        cache_delete(Key, Cache, false)
    end,
    Cache, Caches);

handle_call({first, Cache}, _From, Caches) ->
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
    Cache, Caches);

handle_call({keys, Cache}, From, Caches) ->
  MapFun = fun(K,_V) -> K end,
  handle_call({map, MapFun, Cache}, From, Caches);

handle_call({map, MapFun, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        cache_map(MapFun, Cache)
    end,
    Cache, Caches);

handle_call({filter, PredFun, Cache}, _From, Caches) ->
  call_reply(
    fun() ->
        cache_filter(PredFun, Cache)
    end,
    Cache, Caches);

handle_call(Req, _From, Caches) ->
  {reply, {invalid_request, Req}, Caches}.

%%
%% Handle casts
%%
handle_cast({make, Cache, TTL}, Caches) ->
  {noreply, update_caches(Cache, TTL, Caches)};

handle_cast({make, CacheList}, Caches) ->
  NewCaches = 
    lists:foldl(
      fun({Cache, TTL}, Acc) ->
          update_caches(Cache, TTL, Acc)
      end,
      Caches, CacheList),
  {noreply, NewCaches};

handle_cast({ttl, Cache, TTL}, Caches) ->
  {noreply, maps:put(Cache, TTL, Caches)};

handle_cast({put, Key, Value, Cache}, Caches) ->
  cast_reply(
    fun() ->
        cache_put(Key, Value, ttl(Cache, Caches), Cache)
    end,
    Cache, Caches);

handle_cast({put, Key, Value, TTL, Cache}, Caches) ->
  cast_reply(
    fun() ->
        cache_put(Key, Value, TTL, Cache)
    end,
    Cache, Caches);

handle_cast({foreach, KVFun, Cache}, Caches) ->
  cast_reply(
    fun() ->
        cache_foreach(KVFun, Cache)
    end,
    Cache, Caches);

handle_cast({destroy, Cache}, Caches) ->
  case valid_cache(Cache, Caches) of
    true ->
      ets:delete(table_name(Cache)),
      {noreply, maps:remove(Cache, Caches)};
    false ->
      {noreply, Caches}
  end;

handle_cast({destroy, Key, Cache}, Caches) ->
  cast_reply(
    fun() ->
        cache_delete(Key, Cache, true)
    end,
    Cache, Caches);

handle_cast({flush, Cache}, Caches) ->
  cast_reply(
    fun() ->
        ets:delete_all_objects(table_name(Cache))
    end,
    Cache, Caches);

handle_cast(_Msg, Caches) ->
  {noreply, Caches}.

%%
%% Handle info
%%
handle_info({destroy, Key, Cache}, Caches) ->
  case valid_cache(Cache, Caches) of
    true ->
      ets:delete(table_name(Cache), Key);
    false ->
      skip
  end,
  {noreply, Caches};

handle_info(_Info, Caches) ->
  {noreply, Caches}.

%%
%% 
%%
terminate(_Reason, _Caches) ->
  ok.

code_change(_OldVsn, Caches, _Extra) ->
  {ok, Caches}.

%%
%% Internal functions
%%

update_caches(Cache, TTL, Caches) ->
  case valid_cache(Cache, Caches) of
    true ->
      maps:update(Cache, TTL, Caches);
    false ->
      TableName = table_name(Cache),
      ets:new(TableName, [named_table, public]),
      maps:put(Cache, TTL, Caches)
  end.

table_name(Cache) ->
  list_to_atom("kncache_" ++ atom_to_list(Cache)).

ttl(Cache, Caches) ->
  case maps:get(Cache, Caches) of
    0 ->
      infinity;
    TTL ->
      TTL
  end.

cache_put(Key, Value, infinity, Cache) ->
  ets:insert(table_name(Cache), {Key, Value}),
  ok;
cache_put(Key, Value, TTL, Cache) ->
  TimeRef = erlang:send_after(TTL*1000, ?CACHE_SRV, {destroy, Key, Cache}),
  TimedValue = {{time_ref, TimeRef}, {ttl, TTL}, {value, Value}},
  ets:insert(table_name(Cache), {Key, TimedValue}),
  ok.

cache_delete(Key, Cache, Force) ->
  TableName = table_name(Cache),
  case ets:lookup(TableName, Key) of
    [{Key, {{time_ref, TimeRef}, {ttl, _TTL}, {value, Value}}}] ->
      erlang:cancel_timer(TimeRef),
      ets:delete(TableName, Key),
      {ok, Value};
    [{Key, Value}] ->
      %% Infinite TTL; only delete if force is true
      case Force of 
        true ->
          ets:delete(TableName, Key);
        false ->
          skip
      end,
      {ok, Value};
    _ ->
      no_match
  end.

cache_foreach(KVFun, Cache) ->
  ForeachFun = 
    fun({K,V}, _Acc) ->
        KVFun(K,V)
    end,
  ets:foldl(ForeachFun, undefined, table_name(Cache)).

cache_map(KVFun, Cache) ->
  MapFun = 
    fun({K,V}, Acc) ->
        [KVFun(K,V)] ++ Acc
    end,
  ets:foldl(MapFun, [], table_name(Cache)).

cache_filter(PredFun, Cache) ->
  FilterFun = 
    fun({K,V}, Acc) ->
        case PredFun(K,V) of
          true ->
            [{K,V}] ++ Acc;
          false ->
            Acc
        end
    end,
  ets:foldl(FilterFun, [], table_name(Cache)).

call_reply(Fun, Cache, Caches) ->
  case valid_cache(Cache, Caches) of
    true ->
      {reply, Fun(), Caches};
    false ->
      {reply, {invalid_cache, Cache}, Caches}
  end.

cast_reply(Fun, Cache, Caches) ->
  case valid_cache(Cache, Caches) of
    true ->
      Fun();
    false ->
      skip
  end,
  {noreply, Caches}.

valid_cache(Cache, Caches) ->
  case ets:info(table_name(Cache)) of
    undefined ->
      false;
    _ ->
      maps:is_key(Cache, Caches)
  end.          
  
