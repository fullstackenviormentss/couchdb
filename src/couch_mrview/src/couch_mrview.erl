-module(couch_mrview).

-export([query_view/3, query_view/4, query_view/6]).
-export([open_view/3, open_view/4, run_view/5]).
-export([get_info/2]).

-include_lib("couch_mrview/include/couch_mrview.hrl").

-record(mracc, {
    db,
    meta_sent=false,
    total_rows,
    offset,
    limit,
    skip,
    group_level,
    callback,
    user_acc,
    reduce_fun,
    include_docs
}).


query_view(Db, DDoc, ViewName) ->
    query_view(Db, DDoc, ViewName, #mrargs{}).


query_view(Db, DDoc, ViewName, Args) ->
    query_view(Db, DDoc, ViewName, Args, fun default_callback/2, []).

    
query_view(Db, DDoc, ViewName, Args, Callback, Acc) when is_list(Args) ->
    query_view(Db, DDoc, ViewName, to_mrargs(Args), Callback, Acc);
query_view(Db, DDoc, ViewName, Args0, Callback, Acc) ->
    {ok, VInfo, Args} = couch_mrview_util:get_view(Db, DDoc, ViewName, Args0),
    run_view(Db, VInfo, Args, Callback, Acc).


open_view(Db, DDoc, ViewName) ->
    open_view(Db, DDoc, ViewName, #mrargs{}).

open_view(Db, DDoc, ViewName, Args) when is_list(Args) ->
    open_view(Db, DDoc, ViewName, to_mrargs(Args));
open_view(Db, DDoc, ViewName, Args0) ->
    couch_mrview_util:get_view(Db, DDoc, ViewName, Args0).


run_view(Db, {map, View}, Args, Callback, Acc) ->
    map_fold(Db, View, Args, Callback, Acc);
run_view(Db, {red, View}, Args, Callback, Acc) ->
    red_fold(Db, View, Args, Callback, Acc).


% API convenience.
get_info(Db, DDoc) ->
    couch_mrview_util:get_info(Db, DDoc).


map_fold(Db, View, Args, Callback, UAcc) ->
    {ok, Total} = couch_mrview_util:get_row_count(View),
    Acc = #mracc{
        db=Db,
        total_rows=Total,
        limit=Args#mrargs.limit,
        skip=Args#mrargs.skip,
        callback=Callback,
        user_acc=UAcc,
        reduce_fun=fun couch_mrview_util:reduce_to_count/1,
        include_docs=Args#mrargs.include_docs
    },
    OptList = couch_mrview_util:key_opts(Args),
    {Reds, Acc2} = lists:foldl(fun(Opts, {_, Acc0}) ->
        {ok, R, A} = couch_mrview_util:fold(View, fun map_fold/3, Acc0, Opts),
        {R, A}
    end, {nil, Acc}, OptList),
    
    % Send meta info if we haven't already
    Offset = couch_mrview_util:reduce_to_count(Reds),
    Meta = [{total, Total}, {offset, Offset}],
    {Go, UAcc1} = case Acc2#mracc.meta_sent of
        false -> Callback({meta, Meta}, Acc2#mracc.user_acc);
        _ -> {ok, Acc2#mracc.user_acc}
    end,
    
    % Notify callback that the fold is complete.
    {_, UAcc2} = case Go of
        ok -> Callback(complete, UAcc1);
        _ -> {ok, UAcc1}
    end,
    {ok, UAcc2}.


map_fold(_KV, _Offset, #mracc{skip=N}=Acc) when N > 0 ->
    {ok, Acc#mracc{skip=N-1}};
map_fold(KV, OffsetReds, #mracc{offset=undefined}=Acc) ->
    #mracc{
        total_rows=Total,
        callback=Callback,
        user_acc=UAcc0,
        reduce_fun=Reduce
    } = Acc,
    Offset = Reduce(OffsetReds),
    {Go, UAcc1} = Callback({meta, [{total, Total}, {offset, Offset}]}, UAcc0),
    Acc1 = Acc#mracc{meta_sent=true, offset=Offset, user_acc=UAcc1},
    case Go of
        ok -> map_fold(KV, OffsetReds, Acc1);
        stop -> {stop, Acc1}
    end;
map_fold(_KV, _Offset, #mracc{limit=0}=Acc) ->
    {stop, Acc};
map_fold({{Key, Id}, Val}, _Offset, Acc) ->
    #mracc{
        db=Db,
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0,
        include_docs=IncludeDocs
    } = Acc,
    Doc = couch_mrview_util:maybe_load_doc(Db, Id, Val, IncludeDocs),
    Row = [{key, Key}, {id, Id}, {val, Val}] ++ Doc,
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{limit=Limit-1, user_acc=UAcc1}}.


red_fold(Db, View, Args, Callback, UAcc) ->
    Acc = #mracc{
        db=Db,
        total_rows=null,
        limit=Args#mrargs.limit,
        skip=Args#mrargs.skip,
        group_level=Args#mrargs.group_level,
        callback=Callback,
        user_acc=UAcc,
        include_docs=Args#mrargs.include_docs
    },
    GroupFun = group_rows_fun(Args#mrargs.group_level),
    OptList = couch_mrview_util:key_opts(Args, [{key_group_fun, GroupFun}]),
    Acc2 = lists:foldl(fun(Opts, Acc0) ->
        {ok, Acc1} =
            couch_mrview_util:fold_reduce(View, fun red_fold/3,  Acc0, Opts),
        Acc1
    end, Acc, OptList),
    {_, UAcc1} = Callback(complete, Acc2#mracc.user_acc),
    {ok, UAcc1}.


red_fold(_Key, _Red, #mracc{skip=N}=Acc) when N > 0 ->
    {ok, Acc#mracc{skip=N-1}};
red_fold(_Key, _Red, #mracc{limit=0} = Acc) ->
    {stop, Acc};
red_fold(_Key, Red, #mracc{group_level=0} = Acc) ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, null}, {val, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1}};
red_fold(Key, Red, #mracc{group_level=exact} = Acc) ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, Key}, {val, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1}};
red_fold(K, Red, #mracc{group_level=I} = Acc) when I > 0, is_list(K) ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, lists:sublist(K, I)}, {val, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1}};
red_fold(K, Red, #mracc{group_level=I} = Acc) when I > 0 ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, K}, {val, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1}}.


group_rows_fun(exact) ->
    fun({Key1,_}, {Key2,_}) -> Key1 == Key2 end;
group_rows_fun(0) ->
    fun(_A, _B) -> true end;
group_rows_fun(GroupLevel) when is_integer(GroupLevel) ->
    fun({[_|_] = Key1,_}, {[_|_] = Key2,_}) ->
        lists:sublist(Key1, GroupLevel) == lists:sublist(Key2, GroupLevel);
    ({Key1,_}, {Key2,_}) ->
        Key1 == Key2
    end.


default_callback(complete, Acc) ->
    {ok, lists:reverse(Acc)};
default_callback({final, Info}, []) ->
    {ok, [Info]};
default_callback({final, _}, Acc) ->
    {ok, Acc};
default_callback(Row, Acc) ->
    {ok, [Row | Acc]}.


to_mrargs(KeyList) ->
    lists:foldl(fun({Key, Value}, Acc) ->
        Index = lookup_index(couch_util:to_existing_atom(Key)),
        setelement(Index, Acc, Value)
    end, #mrargs{}, KeyList).


lookup_index(Key) ->
    Index = lists:zip(
        record_info(fields, mrargs), lists:seq(2, record_info(size, mrargs))
    ),
    couch_util:get_value(Key, Index).
