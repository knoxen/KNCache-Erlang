-module(kncache_srv).

-behavior(gen_server).

-vsn('1.0.0').

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
handle_call({make, Cache, Retain}, _From, Caches) ->
  {reply, ok, update_caches(Cache, Retain, Caches)};

handle_call({make, CacheList}, _From, Caches) ->
  NewCaches = lists:foldl(
                fun({Cache, Retain}, Acc) ->
                    update_caches(Cache, Retain, Acc)
                end,
                Caches,
                CacheList),
  {reply, ok, NewCaches};

handle_call(list, _From, Caches) ->
  {reply, maps:keys(Caches), Caches};

handle_call({info, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            CacheName = cache_name(Cache),
            Size = ets:info(CacheName, size),
            Memory = ets:info(CacheName, memory) * erlang:system_info(wordsize),
            Kbs = erlang:trunc(Memory / 100) / 10,
            Retain = retain(Cache, Caches),
            {reply, [{size, Size}, {kbs, Kbs}, {retain, Retain}], Caches}
        end);

handle_call({info, Cache, Key}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            Expiry =
              case ets:lookup(cache_name(Cache), Key) of
                [{Key, {{time_ref, TimeRef}, {value, _Val}}}] ->
                  case erlang:read_timer(TimeRef) of
                    false ->
                      expired;
                    TimeLeft ->
                      TimeLeft / 1000
                  end;
                %% Infinite cached value
                [{Key, _Val}] ->
                  infinity;
                [] ->
                  undefined
              end,

            {reply, {expiry, Expiry}, Caches}
        end);
            
handle_call({retain, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            {reply, retain(Cache, Caches), Caches}
        end);

handle_call({retain, Cache, Retain}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            Caches2 = maps:put(Cache, Retain, Caches),
            {reply, ok, Caches2}
        end);

handle_call({put, Cache, Key, Value}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            case maps:is_key(Cache, Caches) of
              true ->
                cache_put(Cache, Key, Value, retain(Cache, Caches)),
                {reply, ok, Caches};
              false ->
                {reply, skip, Caches}
            end
        end);

handle_call({get, Cache, Key}, From, Caches) ->
  handle_call({get, Cache, Key, 
               fun() -> 
                   undefined
               end},
              From, Caches);

handle_call({get, Cache, Key, ValueFn}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            Value =
              case ets:lookup(cache_name(Cache), Key) of
                %% Cached value scheduled for deletion
                [{Key, {{time_ref, TimeRef}, {value, Val}}}] ->
                  %% Cancel the current timer
                  erlang:cancel_timer(TimeRef),
                  %% Put the value back in the cache to start a new timer
                  cache_put(Cache, Key, Val, retain(Cache, Caches)),
                  {ok, Val};
                %% Infinite cached value
                [{Key, Val}] ->
                  {ok, Val};
                %% Generate, cache, and return a new value
                [] ->
                  %% Generate value and insert into Cache unless undefined
                  case ValueFn() of
                    undefined ->
                      undefined;
                    NewValue ->
                      %% Cache and return newly created value
                      cache_put(Cache, Key, NewValue, retain(Cache, Caches)),
                      {ok, NewValue}
                  end
              end,
            {reply, Value, Caches}
        end);

handle_call({first, Cache}, _From, Caches) ->
  reply(Cache, Caches,
        fun() ->
            CacheName = cache_name(Cache),
            First = case ets:first(CacheName) of
                      '$end_of_table' ->
                        empty;
                      Key ->
                        ets:lookup(CacheName, Key)
                    end,
            {reply, First, Caches}
        end);

handle_call({flush, Cache}, _From, Caches) ->
  reply(Cache, Caches, 
        fun() ->
            ets:delete_all_objects(cache_name(Cache)),
            {reply, ok, Caches}
        end);

handle_call(Req, _From, Caches) ->
  {reply, {invalid_request, Req}, Caches}.

%%
%% Handle casts
%%
handle_cast({delete, Cache, Key}, Caches) ->
  case maps:is_key(Cache, Caches) of
    true ->
      cache_delete(Cache, Key);
    false ->
      skip
  end,
  {noreply, Caches};

handle_cast(_Msg, Caches) ->
  {noreply, Caches}.

%%
%% Handle info
%%
handle_info({delete, Cache, Key}, Caches) ->
  case maps:is_key(Cache, Caches) of
    true ->
      ets:delete(cache_name(Cache), Key);
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

update_caches(Cache, Retain, Caches) ->
  case maps:is_key(Cache, Caches) of
    true ->
      maps:update(Cache, Retain, Caches);
    false ->
      CacheName = cache_name(Cache),
      ets:new(CacheName, [named_table, public]),
      maps:put(Cache, Retain, Caches)
  end.

cache_name(Cache) ->
  list_to_atom("kncache_" ++ atom_to_list(Cache)).

retain(Cache, Caches) ->
  case maps:get(Cache, Caches) of
    0 ->
      infinity;
    Retain ->
      Retain
  end.

cache_put(Cache, Key, Value, infinity) ->
  ets:insert(cache_name(Cache), {Key, Value}),
  ok;
cache_put(Cache, Key, Value, Retain) ->
  TimeRef = erlang:send_after(Retain*1000, ?CACHE_SRV, {delete, Cache, Key}),
  ets:insert(cache_name(Cache), 
                 {Key, {{time_ref, TimeRef}, {value, Value}}}),
  ok.

cache_delete(Cache, Key) ->  
  CacheName = cache_name(Cache),

  case ets:lookup(CacheName, Key) of
    [{Key, {{time_ref, TimeRef}, {value, _Value}}}] ->
      erlang:cancel_timer(TimeRef),
      ets:delete(CacheName, Key),
      ok;
    [{Key, _Value}] ->
      ets:delete(CacheName, Key),
      ok;
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
