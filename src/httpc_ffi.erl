%% One-time tuning of erlang's httpc client at boot.
-module(httpc_ffi).
-export([configure/0]).

%% Default max_sessions is 2 persistent connections per host; digicert
%% runs 3 log shards on one hostname, so simultaneous ticks would churn
%% connections instead of reusing them.
configure() ->
    ok = httpc:set_options([{max_sessions, 8}]),
    nil.
