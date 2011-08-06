% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_index_updater).
-behaviour(gen_server).


%% API
-export([start_link/2, run/2, is_running/1, restart/2]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-include("couch_db.hrl").

-record(st, {
    idx,
    mod,
    pid=nil
}).


start_link(Index, Module) ->
    gen_server:start_link(?MODULE, {Index, Module}, []).


run(Pid, IdxState) ->
    gen_server:call(Pid, {update, IdxState}).


is_running(Pid) ->
    gen_server:call(Pid, is_running).


restart(Pid, IdxState) ->
    gen_server:call(Pid, {restart, IdxState}).


init({Index, Module}) ->
    process_flag(trap_exit, true),
    {ok, #st{idx=Index, mod=Module}}.


terminate(_Reason, State) ->
    couch_util:shutdown_sync(State#st.pid),
    ok.


handle_call({update, _IdxState}, _From, #st{pid=Pid}=State) when is_pid(Pid) ->
    {reply, ok, State};
handle_call({update, IdxState}, _From, State) ->
    Pid = spawn_link(fun() -> update(State#st.mod, IdxState) end),
    {reply, ok, State#st{pid=Pid}};
handle_call(is_running, _From, #st{pid=Pid}=State) when is_pid(Pid) ->
    {reply, true, State};
handle_call(is_running, _From, State) ->
    {reply, false, State}.


handle_cast(_Mesg, State) ->
    {stop, unknown_cast, State}.


handle_info({'EXIT', Pid, {updated, IdxState}}, #st{pid=Pid}=State) ->
    ok = gen_server:call(State#st.idx, {new_state, IdxState}),
    {noreply, State#st{pid=undefined}};
handle_info({'EXIT', Pid, reset}, #st{pid=Pid}=State) ->
    {ok, NewIdxState} = gen_server:call(State#st.idx, reset),
    Pid2 = spawn_link(fun() -> update(State#st.mod, NewIdxState) end),
    {noreply, State#st{pid=Pid2}};
handle_info(_Mesg, State) ->
    {stop, unknown_info, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


update(Mod, IdxState) ->
    Self = self(),
    DbName = Mod:db_name(IdxState),
    CurrSeq = Mod:update_seq(IdxState),
   
    TaskType = <<"Indexer">>,
    Starting = <<"Starting index update.">>,
    couch_task_status:add_task(TaskType, Mod:index_name(IdxState), Starting),

    couch_util:with_db(DbName, fun(Db) ->
        PurgedIdxState = case purge_index(Db, Mod, IdxState) of
            {ok, IdxState0} -> IdxState0;
            reset -> exit(reset)
        end,
        
        UpdateOpts = Mod:update_options(PurgedIdxState),
        IncludeDesign = lists:member(include_design, UpdateOpts),
        DocOpts = case lists:member(local_seq, UpdateOpts) of
            true -> [conflicts, deleted_conflicts, local_seq];
            _ -> [conflicts, deleted_conflicts]
        end,

        QueueOpts = [{max_size, 100000}, {max_items, 500}],
        {ok, Queue} = couch_work_queue:new(QueueOpts),
        
        ProcIdxState = Mod:start_update(self(), self(), PurgedIdxState),

        ProcDocFun = fun() -> process_docs(Self, Mod, ProcIdxState, Queue) end,
        spawn_link(ProcDocFun),
                        
        couch_task_status:set_update_frequency(500),
        NumChanges = couch_db:count_changes_since(Db, CurrSeq),

        LoadProc = fun(DocInfo, _, Count) ->
            update_task_status(NumChanges, Count),
            queue_doc(Db, DocInfo, DocOpts, IncludeDesign, Queue),
            {ok, Count+1}
        end,
        {ok, _, _} = couch_db:enum_docs_since(Db, CurrSeq, LoadProc, 0, []),

        couch_work_queue:close(Queue),
        couch_task_status:set_update_frequency(0),
        couch_task_status:update("Waiting for index writer to finish."),

        receive
            {new_state, NewIdxState} ->
                NewSeq = couch_db:get_update_seq(Db),
                NewIdxState2 = Mod:set_update_seq(NewSeq, NewIdxState),
                exit({updated, NewIdxState2})
        end
    end).


purge_index(Db, Mod, IdxState) ->
    DbPurgeSeq = couch_db:get_purge_seq(Db),
    IdxPurgeSeq = Mod:purge_seq(IdxState),
    if
        DbPurgeSeq == IdxPurgeSeq ->
            {ok, IdxState};
        DbPurgeSeq == IdxPurgeSeq + 1 ->
            couch_task_status:update(<<"Purging index entries.">>),
            {ok, PurgedIdRevs} = couch_db:get_last_purged(Db),
            Mod:purge(Db, DbPurgeSeq, PurgedIdRevs, IdxState);
        true ->
            couch_task_status:update(<<"Resetting index due to purge state.">>),
            reset
    end.


queue_doc(Db, DocInfo, DocOpts, IncludeDesign, DocQueue) ->
    #doc_info{
        id=DocId,
        high_seq=Seq,
        revs=[#rev_info{deleted=Deleted}|_]
    } = DocInfo,
    case {IncludeDesign, DocId} of
        {false, <<"_design/", _/binary>>} ->
            ok;
        _ when Deleted ->
            Doc = #doc{id=DocId, deleted=true},
            couch_work_queue:queue(DocQueue, {Seq, Doc});
        _ ->
            {ok, Doc} = couch_db:open_doc_int(Db, DocInfo, DocOpts),
            couch_work_queue:queue(DocQueue, {Seq, Doc})
    end.


process_docs(Parent, Mod, IdxState, Queue) ->
    case couch_work_queue:dequeue(Queue) of
        closed ->
            Mod:finish_update(IdxState);
        {ok, Docs} ->
            FoldFun = fun({Seq, Doc}, IdxStAcc) ->
                Mod:process_doc(Doc, Seq, IdxStAcc)
            end,
            NewIdxState = lists:foldl(FoldFun, IdxState, Docs),
            process_docs(Parent, Mod, NewIdxState, Queue)
    end.


update_task_status(Total, Count) ->
    PercDone = (Count * 100) div Total,
    Mesg = "Processed ~p of ~p changes (~p%)",
    couch_task_status:update(Mesg, [Count, Total, PercDone]).    
