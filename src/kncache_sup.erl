%%%-------------------------------------------------------------------
%% @doc kncache top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(kncache_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([]) ->
  RestartStrategy = {one_for_one, 10, 10},
  KNCacheSrv = {kncache_srv,
                {kncache_srv, start_link, []},
                permanent, 2000, worker, [kncache_srv]},
  {ok, {RestartStrategy, [KNCacheSrv]}}.

%%====================================================================
%% Internal functions
%%====================================================================
