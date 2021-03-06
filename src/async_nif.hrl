%% -------------------------------------------------------------------
%%
%% async_nif: An async thread-pool layer for Erlang's NIF API
%%
%% Copyright (c) 2012 Basho Technologies, Inc. All Rights Reserved.
%% Author: Gregory Burd <greg@basho.com> <greg@burd.me>
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

-define(ASYNC_NIF_CALL(Fun, Args),
	F = fun(F, T) ->
		    R = erlang:make_ref(),
		    case erlang:apply(Fun, [R|Args]) of
			{ok, {enqueued, PctBusy}} ->
			    if
				PctBusy > 0.25 andalso PctBusy =< 1.0 ->
				    erlang:bump_reductions(erlang:trunc(2000 * PctBusy));
			       true ->
				    ok
			    end,
			    receive
				{R, {error, shutdown}=Error} ->
				    %% Work unit was queued, but not executed.
				    Error;
				{R, {error, _Reason}=Error} ->
				    %% Work unit returned an error.
				    Error;
				{R, Reply} ->
				    Reply
			    end;
			{error, eagain} ->
			    case T of
				3 -> not_found;
				_ -> F(F, T + 1)
			    end;
			Other ->
			    Other
		    end
	    end,
	F(F, 1)).
