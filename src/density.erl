%%% Copyright (c) 2011 Jachym Holecek <freza@circlewave.net>
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions
%%% are met:
%%%
%%% 1. Redistributions of source code must retain the above copyright
%%%    notice, this list of conditions and the following disclaimer.
%%% 2. Redistributions in binary form must reproduce the above copyright
%%%    notice, this list of conditions and the following disclaimer in the
%%%    documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
%%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%%% SUCH DAMAGE.

-module(density).

-export([rec/2, del/1, read/1, read_all/0, read_all/1, read_sel/1]).

-import(lists, [foldl/3]).
-import(sysmon_lib, [logarithm/2, strip_key/1]).

-include("sysmon_db.hrl").

%%% Histograms are predefined event bins stored in single ETS row. Otherwise similar to event counters.

rec({Tab, _, Inst} = Key, Val) when is_integer(Val), Val >= 0 ->
    case ets:lookup(density_conf, {Tab, Inst}) of
	[Conf] ->
	    update(Key, value_to_index(Val, Conf), Conf);
	[] ->
	    not_found
    end.

del({_, _, _} = Key) ->
    ets:delete(sysmon_hst, Key).

read({_, _, _} = Key) ->
    case ets:lookup(sysmon_hst, Key) of
	[Item] ->
	    {ok, strip_key(Item)};
	[] ->
	    not_found
    end.

read_all() ->
    read_sel({'_', '_', '_'}).

read_all(Tab) ->
    read_sel({Tab, '_', '_'}).

read_sel(Head) ->
    ets:safe_fixtable(sysmon_avg, true),
    try
	read_sel(ets:select(sysmon_avg, [{{Head, '_', '_'}, [], ['$_']}], 100), [])
    after
	ets:safe_fixtable(sysmon_avg, false)
    end.

%%%

read_sel({Items, Cont}, Acc) ->
    read_sel(ets:select(Cont), foldl(fun (X, A) -> [{element(1, X), strip_key(X)} | A] end, Acc, Items));
read_sel('$end_of_table', Acc) ->
    Acc.

update(Key, Idx, #density_conf{bin_cnt = Bins}) ->
    case update(Key, Idx) of
	not_found ->
	    %% Make space for implicit bins: underflow/overflow samples.
	    ets:insert_new(sysmon_hst, list_to_tuple([Key | lists:duplicate(Bins + 2, 0)])),
	    update(Key, Idx);
	_ ->
	    ok
    end.

update(Key, Idx) ->
    try
	ets:update_counter(sysmon_hst, Key, {Idx, 1}),
	ok
    catch
	error : badarg ->
	    not_found
    end.

%% Row format is {Key, Underflow_bin, [... regular bins ...], Overflow_bin}.
value_to_index(#density_conf{scale = lin, shift = Shift, param = Mult, bin_cnt = Bins}, Val) ->
    select_bin(round((Val - Shift) / Mult), Bins);
value_to_index(#density_conf{scale = log, shift = Shift, param = Base, bin_cnt = Bins}, Val) when Val >= 1 ->
    select_bin(round(logarithm(Base, Val) - logarithm(Base, Shift)), Bins).

%% Map zero-based relative index to actual column. Place out-of-range values to {under,over}flow bins.
select_bin(N, _) when N < 0 ->
    2;
select_bin(N, C) when N >= C ->
    C + 3;
select_bin(N, _) ->
    N + 3.