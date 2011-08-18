-module(couch_mrview_index).


-export([db_name/1, index_name/1, signature/1]).
-export([update_seq/1, set_update_seq/2, purge_seq/1, committed_only/1]).
-export([get_info/1]).
-export([open/2, close/1]).
-export([update_options/1]).
-export([start_update/3, process_docs/2, finish_update/1, purge/4, commit/1]).
-export([compact/2, swap_compacted/2]).
-export([reset/1]).


-include_lib("couch_mrview/include/couch_mrview.hrl").


db_name(#mrst{db_name=DbName}) ->
    DbName.


index_name(#mrst{idx_name=IdxName}) ->
    IdxName.


signature(#mrst{sig=Sig}) ->
    Sig.


update_seq(#mrst{update_seq=UpdateSeq}) ->
    UpdateSeq.


set_update_seq(Seq, State) ->
    State#mrst{update_seq=Seq}.


purge_seq(#mrst{purge_seq=PurgeSeq}) ->
    PurgeSeq.


committed_only(_State) ->
    false.


get_info(State) ->
    #mrst{
        fd = Fd,
        sig = Sig,
        id_btree = Btree,
        language = Lang,
        update_seq = UpdateSeq,
        purge_seq = PurgeSeq,
        views = Views
    } = State,
    {ok, Size} = couch_file:bytes(Fd),
    {ok, DataSize} = couch_mrview_util:calculate_data_size(Btree, Views),
    {ok, [
        {signature, list_to_binary(couch_mrview_util:hexsig(Sig))},
        {language, Lang},
        {disk_size, Size},
        {data_size, DataSize},
        {update_seq, UpdateSeq},
        {purge_seq, PurgeSeq}
    ]}.


open(Db, State) ->
    #mrst{
        db_name=DbName,
        sig=Sig,
        root_dir=RootDir
    } = State,
    IndexFName = couch_mrview_util:index_file(RootDir, DbName, Sig),
    case couch_mrview_util:open_file(IndexFName) of
        {ok, Fd} ->
            case (catch couch_file:read_header(Fd)) of
                {ok, {Sig, Header}} ->
                    % Matching view signatures.
                    {ok, couch_mrview_util:init_state(Db, Fd, State, Header)};
                _ ->
                    {ok, couch_mrview_util:reset_index(Db, Fd, State)}
            end;
        Error ->
            (catch couch_mrview_util:delete_index_file(RootDir, DbName, Sig)),
            Error
    end.


close(State) ->
    couch_file:close(State#mrst.fd).


purge(Db, PurgeSeq, PurgedIdRevs, State) ->
    couch_mrview_updater:purge_index(Db, PurgeSeq, PurgedIdRevs, State).


update_options(#mrst{design_opts=Opts}) ->
    Opts1 = case couch_util:get_value(<<"include_design">>, Opts, false) of
        true -> [include_design];
        _ -> []
    end,
    Opts2 = case couch_util:get_value(<<"local_seq">>, Opts, false) of
        true -> [local_seq];
        _ -> []
    end,
    Opts1 ++ Opts2.


start_update(Parent, PartialDest, State) ->
    couch_mrview_updater:start_update(Parent, PartialDest, State).


process_docs(Docs, State) ->
    couch_mrview_updater:process_docs(Docs, State).


finish_update(State) ->
    couch_mrview_updater:finish_update(State).


commit(State) ->
    Header = {State#mrst.sig, couch_mrview_util:make_header(State)},
    couch_file:write_header(State#mrst.fd, Header).


compact(State, Opts) ->
    couch_mrview_compactor:compact(State, Opts).


swap_compacted(OldState, NewState) ->
    couch_mrview_compactor:swap_compacted(OldState, NewState).


reset(State) ->
    couch_util:with_db(State#mrst.db_name, fun(Db) ->
        NewState = couch_mrview_util:reset_index(Db, State#mrst.fd, State),
        {ok, NewState}
    end).
