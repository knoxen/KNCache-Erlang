-module(kncache_srv).

-behavior(gen_server).

-vsn('0.9.3').

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
handle_call({make, Cache, TTL}, _From, Caches) ->
  {reply, ok, update_caches(Cache, TTL, Caches)};

handle_call({make, CacheList}, _From, Caches) ->
  NewCaches = lists:foldl(
                fun({Cache, TTL}, Acc) ->
                    update_caches(Cache, TTL, Acc)
                end,
                Caches,
                CacheList),
  {reply, ok, NewCaches};

handle_call(list, _From, Caches) ->
  {reply, maps:keys(Caches), Caches};

handle_call({info, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            TableName = table_name(Cache),
            Size = ets:info(TableName, size),
            Memory = ets:info(TableName, memory) * erlang:system_info(wordsize),
            Kbs = erlang:trunc(Memory / 100) / 10,
            TTL = ttl(Cache, Caches),
            {reply, [{size, Size}, {kbs, Kbs}, {ttl, TTL}], Caches}
        end);

handle_call({info, Key, Cache}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            Info =
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
              end,
            {reply, Info, Caches}
        end);
            
handle_call({size, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            TableName = table_name(Cache),
            Size = ets:info(TableName, size),
            {reply, Size, Caches}
        end);

handle_call({ttl, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            {reply, ttl(Cache, Caches), Caches}
        end);

handle_call({ttl, Cache, TTL}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            Caches2 = maps:put(Cache, TTL, Caches),
            {reply, ok, Caches2}
        end);

handle_call({put, Key, Value, Cache}, From, Caches) ->
  TTL = ttl(Cache, Caches),
  handle_call({put, Key, Value, TTL, Cache}, From, Caches);

handle_call({put, Key, Value, TTL, Cache}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            case maps:is_key(Cache, Caches) of
              true ->
                cache_put(Key, Value, TTL, Cache),
                {reply, ok, Caches};
              false ->
                {reply, skip, Caches}
            end
        end);

handle_call({get, Key, Cache}, From, Caches) ->
  ValueFn = fun() -> undefined end,
  handle_call({get, Key, ValueFn, Cache}, From, Caches);

handle_call({get, Key, ValueFn, Cache}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            Value =
              case ets:lookup(table_name(Cache), Key) of
                %% Cached value scheduled for deletion
                [{Key, {{time_ref, TimeRef}, {ttl, TTL}, {value, Val}}}] ->
                  %% Cancel the current timer
                  erlang:cancel_timer(TimeRef),
                  %% Put the value back in the cache to start a new timer
                  cache_put(Key, Val, TTL, Cache),
                  {ok, Val};
                %% Infinite cached value
                [{Key, Val}] ->
                  {ok, Val};
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
              end,
            {reply, Value, Caches}
        end);

handle_call({delete, Key, Cache}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            Value = 
              case maps:is_key(Cache, Caches) of
                true ->
                  cache_delete(Key, Cache, false);
                false ->
                  {error, invalid_cache}
              end,
            {reply, Value, Caches}
        end);

handle_call({first, Cache}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            TableName = table_name(Cache),
            First = case ets:first(TableName) of
                      '$end_of_table' ->
                        empty;
                      Key ->
                        ets:lookup(TableName, Key)
                    end,
            {reply, First, Caches}
        end);

handle_call({keys, Cache}, From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            KeysFun = fun(K,_V) -> K end,
            handle_call({map, KeysFun, Cache}, From, Caches)
        end);

handle_call({flush, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            ets:delete_all_objects(table_name(Cache)),
            {reply, ok, Caches}
        end);

handle_call({foreach, Fn, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            KVFun = 
              fun({K,V}, _Acc) ->
                  Fn(K,V)
              end,
            _Acc = ets:foldl(KVFun, [], table_name(Cache)),
            {reply, ok, Caches}
        end);

handle_call({map, Fn, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            KVFun = 
              fun({K,V}, List) ->
                  [Fn(K,V)] ++ List
              end,
            List = ets:foldl(KVFun, [], table_name(Cache)),
            {reply, List, Caches}
        end);

handle_call(Req, _From, Caches) ->
  {reply, {invalid_request, Req}, Caches}.

%%
%% Handle casts
%%
handle_cast({destroy, Cache}, Caches) ->
  case maps:is_key(Cache, Caches) of
    true ->
      ets:delete(table_name(Cache)),
      {noreply, maps:remove(Cache, Caches)};
    false ->
      {noreply, Caches}
  end;

handle_cast({destroy, Key, Cache}, Caches) ->
  case maps:is_key(Cache, Caches) of
    true ->
      cache_delete(Key, Cache, true);
    false ->
      skip
  end,
  {noreply, Caches};

handle_cast(_Msg, Caches) ->
  {noreply, Caches}.

%%
%% Handle info
%%
handle_info({destroy, Key, Cache}, Caches) ->
  case maps:is_key(Cache, Caches) of
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
  case maps:is_key(Cache, Caches) of
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

reply(Cache, Caches, ValidCacheFn) ->
  case maps:is_key(Cache, Caches) of
    true ->
      ValidCacheFn();
    false ->
      {reply, {invalid_cache, Cache}, Caches}
  end.
