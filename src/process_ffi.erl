%% Minimal process introspection not exposed by gleam_erlang.
-module(process_ffi).
-export([queue_len/1]).

%% Message queue length of a process; a huge number if it's gone,
%% so callers treat dead processes as over any backpressure limit.
queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        _ -> 1000000000
    end.
