%% -------------------------------------------------------------------
%%
%% riak_kv_wiredtiger_backend: Use WiredTiger for Riak/KV storage
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(riak_kv_wiredtiger_backend).
-behavior(temp_riak_kv_backend).
-author('Steve Vinoski <steve@basho.com>').

%% KV Backend API
-export([api_version/0,
         capabilities/1,
         capabilities/2,
         start/2,
         stop/1,
         get/3,
         put/5,
         delete/4,
         drop/1,
         fold_buckets/4,
         fold_keys/4,
         fold_objects/4,
         is_empty/1,
         status/1,
         callback/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(API_VERSION, 1).
%% TODO: for when this backend supports 2i
%%-define(CAPABILITIES, [async_fold, indexes]).
-define(CAPABILITIES, [async_fold]).

-record(state, {conn :: wt:connection(),  %% There is one shared conection
                session :: wt:session(),  %% But a session per
                table :: string(),
                partition :: integer()}).

-type state() :: #state{}.
-type config() :: [{atom(), term()}].

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Return the major version of the
%% current API.
-spec api_version() -> {ok, integer()}.
api_version() ->
    {ok, ?API_VERSION}.

%% @doc Return the capabilities of the backend.
-spec capabilities(state()) -> {ok, [atom()]}.
capabilities(_) ->
    {ok, ?CAPABILITIES}.

%% @doc Return the capabilities of the backend.
-spec capabilities(riak_object:bucket(), state()) -> {ok, [atom()]}.
capabilities(_, _) ->
    {ok, ?CAPABILITIES}.

%% @doc Start the WiredTiger backend
-spec start(integer(), config()) -> {ok, state()} | {error, term()}.
start(Partition, Config) ->
    %% Get the data root directory
    case app_helper:get_prop_or_env(data_root, Config, wt) of
	<<"">> ->
            lager:error("Failed to startup WiredTiger: data_root is not valid"),
            {error, data_root_unset};
	[] ->
            lager:error("Failed to startup WiredTiger: data_root is empty"),
            {error, data_root_unset};
        undefined ->
            lager:error("Failed to startup WiredTiger: data_root is not set"),
            {error, data_root_unset};
        DataRoot ->
	    CacheSize =
		case proplists:get_value(cache_size, Config) of
		    undefined ->
			case application:get_env(wt, cache_size) of
			    {ok, Value} ->
				Value;
			    _ ->
				SizeEst = best_guess_at_a_reasonable_cache_size(64),
				%% lager:warning("Using estimated best cache size of ~p for WiredTiger backend.", [SizeEst]),
				SizeEst
			end;
		    Value ->
			Value
		end,
	    AppStarted =
		case application:start(wt) of
		    ok ->
			ok;
		    {error, {already_started, _}} ->
			ok;
		    {error, Reason} ->
			lager:error("Failed to start WiredTiger: ~p", [Reason]),
			{error, Reason}
		end,
	    case AppStarted of
		ok ->
		    ConnectionOpts =
			[Config,
			 {create, true},
			 {logging, true},
			 {transactional, true},
			 {session_max, 128},
			 {shared_cache, [{chunk, "64MB"},
					 {min, "1GB"},
					 {name, "wt-vnode-cache"},
					 {size, CacheSize}]},
			 {sync, false}
			 %% {verbose,
			 %%  ["block", "shared_cache", "ckpt", "evict",
			 %%   "evictserver", "fileops", "hazard", "lsm",
			 %%   "mutex", "read", "readserver", "reconcile",
			 %%   "salvage", "verify", "write"]}
			],
		    ok = filelib:ensure_dir(filename:join(DataRoot, "x")),
                    case wt_conn:open(DataRoot, ConnectionOpts) of
                        {ok, ConnRef} ->
                            Table = "lsm:wt" ++ integer_to_list(Partition),
                            {ok, SRef} = wt:session_open(ConnRef),
			    SessionOpts =
				[%TODO {block_compressor, "snappy"},
				 {internal_page_max, "128K"},
				 {leaf_page_max, "256K"},
				 {lsm_chunk_size, "256MB"},
				 {lsm_bloom_config, [{leaf_page_max, "16MB"}]} ],
                            ok = wt:session_create(SRef, Table, wt:config_to_bin(SessionOpts)),
                            {ok, #state{conn=ConnRef,
                                        table=Table,
                                        session=SRef,
                                        partition=Partition}};
                        {error, ConnReason}=ConnError ->
                            lager:error("Failed to start WiredTiger storage backend: ~p\n",
                                        [ConnReason]),
                            ConnError
                    end;
		Error ->
		    Error
	    end
    end.

%% @doc Stop the WiredTiger backend
-spec stop(state()) -> ok.
stop(#state{conn=ConnRef, session=SRef}) ->
    ok = wt:session_close(SRef),
    wt_conn:close(ConnRef).

%% @doc Retrieve an object from the WiredTiger backend
-spec get(riak_object:bucket(), riak_object:key(), state()) ->
                 {ok, any(), state()} |
                 {ok, not_found, state()} |
                 {error, term(), state()}.
get(Bucket, Key, #state{table=Table, session=SRef}=State) ->
    WTKey = to_object_key(Bucket, Key),
    case wt:session_get(SRef, Table, WTKey) of
        {ok, Value} ->
            {ok, Value, State};
        not_found  ->
            {error, not_found, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% @doc Insert an object into the WiredTiger backend.
%% NOTE: The WiredTiger backend does not currently support
%% secondary indexing and the_IndexSpecs parameter
%% is ignored.
-type index_spec() :: {add, Index, SecondaryKey} | {remove, Index, SecondaryKey}.
-spec put(riak_object:bucket(), riak_object:key(), [index_spec()], binary(), state()) ->
                 {ok, state()} |
                 {error, term(), state()}.
put(Bucket, PrimaryKey, _IndexSpecs, Val, #state{table=Table, session=SRef}=State) ->
    WTKey = to_object_key(Bucket, PrimaryKey),
    case wt:session_put(SRef, Table, WTKey, Val) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% @doc Delete an object from the WiredTiger backend
%% NOTE: The WiredTiger backend does not currently support
%% secondary indexing and the_IndexSpecs parameter
%% is ignored.
-spec delete(riak_object:bucket(), riak_object:key(), [index_spec()], state()) ->
                    {ok, state()} |
                    {error, term(), state()}.
delete(Bucket, Key, _IndexSpecs, #state{table=Table, session=SRef}=State) ->
    WTKey = to_object_key(Bucket, Key),
    case wt:session_delete(SRef, Table, WTKey) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% @doc Fold over all the buckets
-spec fold_buckets(riak_kv_backend:fold_buckets_fun(),
                   any(),
                   [],
                   state()) -> {ok, any()} | {async, fun()}.
fold_buckets(FoldBucketsFun, Acc, Opts, #state{conn=ConnRef, table=Table}) ->
    FoldFun = fold_buckets_fun(FoldBucketsFun),
    BucketFolder =
        fun() ->
                {ok, SRef} = wt:session_open(ConnRef),
                {ok, Cursor} = wt:cursor_open(SRef, Table),
                try
                    {FoldResult, _} =
                        wt:fold_keys(Cursor, FoldFun, {Acc, []}),
                    FoldResult
                catch
                    {break, AccFinal} ->
                        AccFinal
                after
                    ok = wt:cursor_close(Cursor),
                    ok = wt:session_close(SRef)
                end
        end,
    case lists:member(async_fold, Opts) of
        true ->
            {async, BucketFolder};
        false ->
            {ok, BucketFolder()}
    end.

%% @doc Fold over all the keys for one or all buckets.
-spec fold_keys(riak_kv_backend:fold_keys_fun(),
                any(),
                [{atom(), term()}],
                state()) -> {ok, term()} | {async, fun()}.
fold_keys(FoldKeysFun, Acc, Opts, #state{conn=ConnRef, table=Table}) ->
    %% Figure out how we should limit the fold: by bucket, by
    %% secondary index, or neither (fold across everything.)
    Bucket = lists:keyfind(bucket, 1, Opts),
    Index = lists:keyfind(index, 1, Opts),

    %% Multiple limiters may exist. Take the most specific limiter.
    Limiter =
        if Index /= false  -> Index;
           Bucket /= false -> Bucket;
           true            -> undefined
        end,

    %% Set up the fold...
    FoldFun = fold_keys_fun(FoldKeysFun, Limiter),
    KeyFolder =
        fun() ->
                {ok, SRef} = wt:session_open(ConnRef),
                {ok, Cursor} = wt:cursor_open(SRef, Table),
                try
                    wt:fold_keys(Cursor, FoldFun, Acc)
                catch
                    {break, AccFinal} ->
                        AccFinal
                after
                    ok = wt:cursor_close(Cursor),
                    ok = wt:session_close(SRef)
                end
        end,
    case lists:member(async_fold, Opts) of
        true ->
            {async, KeyFolder};
        false ->
            {ok, KeyFolder()}
    end.

%% @doc Fold over all the objects for one or all buckets.
-spec fold_objects(riak_kv_backend:fold_objects_fun(),
                   any(),
                   [{atom(), term()}],
                   state()) -> {ok, any()} | {async, fun()}.
fold_objects(FoldObjectsFun, Acc, Opts, #state{conn=ConnRef, table=Table}) ->
    Bucket =  proplists:get_value(bucket, Opts),
    FoldFun = fold_objects_fun(FoldObjectsFun, Bucket),
    ObjectFolder =
        fun() ->
                {ok, SRef} = wt:session_open(ConnRef),
                {ok, Cursor} = wt:cursor_open(SRef, Table),
                try
                    wt:fold(Cursor, FoldFun, Acc)
                catch
                    {break, AccFinal} ->
                        AccFinal
                after
                    ok = wt:cursor_close(Cursor),
                    ok = wt:session_close(SRef)
                end
        end,
    case lists:member(async_fold, Opts) of
        true ->
            {async, ObjectFolder};
        false ->
            {ok, ObjectFolder()}
    end.

%% @doc Delete all objects from this WiredTiger backend
-spec drop(state()) -> {ok, state()} | {error, term(), state()}.
drop(#state{table=Table, session=SRef}=State) ->
    case wt:session_truncate(SRef, Table) of
        ok ->
            {ok, State};
        Error ->
            {error, Error, State}
    end.

%% @doc Returns true if this WiredTiger backend contains any
%% non-tombstone values; otherwise returns false.
-spec is_empty(state()) -> boolean().
is_empty(#state{table=Table, session=SRef}) ->
    {ok, Cursor} = wt:cursor_open(SRef, Table),
    try
        not_found =:= wt:cursor_next(Cursor)
    after
        ok = wt:cursor_close(Cursor)
    end.

%% @doc Get the status information for this WiredTiger backend
-spec status(state()) -> [{atom(), term()}].
status(#state{table=Table, session=SRef}) ->
    {ok, Cursor} = wt:cursor_open(SRef, "statistics:"++Table),
    try
        Stats = fetch_status(Cursor),
        [{stats, Stats}]
    after
        ok = wt:cursor_close(Cursor)
    end.

%% @doc Register an asynchronous callback
-spec callback(reference(), any(), state()) -> {ok, state()}.
callback(_Ref, _Msg, State) ->
    {ok, State}.


%% ===================================================================
%% Internal functions
%% ===================================================================

%% @private
%% Return a function to fold over the buckets on this backend
fold_buckets_fun(FoldBucketsFun) ->
    fun(BK, {Acc, LastBucket}) ->
            case from_object_key(BK) of
                {LastBucket, _} ->
                    {Acc, LastBucket};
                {Bucket, _} ->
                    {FoldBucketsFun(Bucket, Acc), Bucket};
                _ ->
                    throw({break, Acc})
            end
    end.

%% @private
%% Return a function to fold over keys on this backend
fold_keys_fun(FoldKeysFun, undefined) ->
    %% Fold across everything...
    fun(StorageKey, Acc) ->
            case from_object_key(StorageKey) of
                {Bucket, Key} ->
                    FoldKeysFun(Bucket, Key, Acc);
                _ ->
                    throw({break, Acc})
            end
    end;
fold_keys_fun(FoldKeysFun, {bucket, FilterBucket}) ->
    %% Fold across a specific bucket...
    fun(StorageKey, Acc) ->
            case from_object_key(StorageKey) of
                {Bucket, Key} when Bucket == FilterBucket ->
                    FoldKeysFun(Bucket, Key, Acc);
                _ ->
                    throw({break, Acc})
            end
    end;
fold_keys_fun(FoldKeysFun, {index, FilterBucket, {eq, <<"$bucket">>, _}}) ->
    %% 2I exact match query on special $bucket field...
    fold_keys_fun(FoldKeysFun, {bucket, FilterBucket});
fold_keys_fun(FoldKeysFun, {index, FilterBucket, {eq, FilterField, FilterTerm}}) ->
    %% Rewrite 2I exact match query as a range...
    NewQuery = {range, FilterField, FilterTerm, FilterTerm},
    fold_keys_fun(FoldKeysFun, {index, FilterBucket, NewQuery});
fold_keys_fun(FoldKeysFun, {index, FilterBucket, {range, <<"$key">>, StartKey, EndKey}}) ->
    %% 2I range query on special $key field...
    fun(StorageKey, Acc) ->
            case from_object_key(StorageKey) of
                {Bucket, Key} when FilterBucket == Bucket,
                                   StartKey =< Key,
                                   EndKey >= Key ->
                    FoldKeysFun(Bucket, Key, Acc);
                _ ->
                    throw({break, Acc})
            end
    end;
fold_keys_fun(FoldKeysFun, {index, FilterBucket, {range, FilterField, StartTerm, EndTerm}}) ->
    %% 2I range query...
    fun(StorageKey, Acc) ->
            case from_index_key(StorageKey) of
                {Bucket, Key, Field, Term} when FilterBucket == Bucket,
                                                FilterField == Field,
                                                StartTerm =< Term,
                                                EndTerm >= Term ->
                    FoldKeysFun(Bucket, Key, Acc);
                _ ->
                    throw({break, Acc})
            end
    end;
fold_keys_fun(_FoldKeysFun, Other) ->
    throw({unknown_limiter, Other}).

%% @private
%% Return a function to fold over the objects on this backend
fold_objects_fun(FoldObjectsFun, FilterBucket) ->
    %% 2I does not support fold objects at this time, so this is much
    %% simpler than fold_keys_fun.
    fun({StorageKey, Value}, Acc) ->
            case from_object_key(StorageKey) of
                {Bucket, Key} when FilterBucket == undefined;
                                   Bucket == FilterBucket ->
                    FoldObjectsFun(Bucket, Key, Value, Acc);
                _ ->
                    throw({break, Acc})
            end
    end.

to_object_key(Bucket, Key) ->
    sext:encode({o, Bucket, Key}).

from_object_key(LKey) ->
    case sext:decode(LKey) of
        {o, Bucket, Key} ->
            {Bucket, Key};
        _ ->
            undefined
    end.

from_index_key(LKey) ->
    case sext:decode(LKey) of
        {i, Bucket, Field, Term, Key} ->
            {Bucket, Key, Field, Term};
        _ ->
            undefined
    end.

%% @private
%% Return all status from WiredTiger statistics cursor
fetch_status(Cursor) ->
    fetch_status(Cursor, wt:cursor_next_value(Cursor), []).
fetch_status(_Cursor, not_found, Acc) ->
    lists:reverse(Acc);
fetch_status(Cursor, {ok, Stat}, Acc) ->
    [What,Val|_] = [binary_to_list(B) || B <- binary:split(Stat, [<<0>>], [global])],
    fetch_status(Cursor, wt:cursor_next_value(Cursor), [{What,Val}|Acc]).

best_guess_at_a_reasonable_cache_size(ChunkSizeInMB) ->
    RunningApps = application:which_applications(),
    case proplists:is_defined(sasl, RunningApps) andalso
	 proplists:is_defined(os_mon, RunningApps) of
	true ->
	    MemInfo = memsup:get_system_memory_data(),
	    AvailableRAM = proplists:get_value(system_total_memory, MemInfo),
	    FreeRAM = proplists:get_value(free_memory, MemInfo),
	    CurrentlyInUseByErlang = proplists:get_value(total, erlang:memory()),
	    OneThirdOfRemainingRAM = ((AvailableRAM - CurrentlyInUseByErlang) div 3),
	    Remainder = OneThirdOfRemainingRAM rem (ChunkSizeInMB * 1024 * 1024),
	    EstCacheSize = (OneThirdOfRemainingRAM - Remainder),
	    GuessedSize =
		case EstCacheSize > FreeRAM of
		    true ->
			FreeRAM - (FreeRAM rem (ChunkSizeInMB * 1024 * 1024));
		    _ ->
			EstCacheSize
		end,
	    case GuessedSize < 809238528 of
		true -> "1GB";
		false -> integer_to_list(GuessedSize div (1024 * 1024)) ++ "MB"
	    end;
	false ->
	    "1GB"
    end.


%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

simple_test_() ->
    ?assertCmd("rm -rf test/wiredtiger-backend"),
    application:set_env(wt, data_root, "test/wiredtiger-backend"),
    temp_riak_kv_backend:standard_test(?MODULE, []).

custom_config_test_() ->
    ?assertCmd("rm -rf test/wiredtiger-backend"),
    application:set_env(wt, data_root, ""),
    temp_riak_kv_backend:standard_test(?MODULE, [{data_root, "test/wiredtiger-backend"}]).

-endif.