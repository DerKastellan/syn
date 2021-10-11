%% ==========================================================================================================
%% Syn - A global Process Registry and Process Group manager.
%%
%% The MIT License (MIT)
%%
%% Copyright (c) 2015-2021 Roberto Ostinelli <roberto@ostinelli.net> and Neato Robotics, Inc.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THxE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% ==========================================================================================================
-module(syn_groups).
-behaviour(syn_gen_scope).

%% API
-export([start_link/1]).
-export([get_subcluster_nodes/1]).
-export([join/2, join/3, join/4]).
-export([leave/2, leave/3]).
-export([members/1, members/2]).
-export([is_member/2, is_member/3]).
-export([local_members/1, local_members/2]).
-export([is_local_member/2, is_local_member/3]).
-export([count/0, count/1, count/2]).
-export([local_count/0, local_count/1]).
-export([group_names/0, group_names/1, group_names/2]).
-export([local_group_names/0, local_group_names/1]).
-export([publish/2, publish/3]).
-export([local_publish/2, local_publish/3]).
-export([multi_call/2, multi_call/3, multi_call/4, multi_call_reply/2]).

%% syn_gen_scope callbacks
-export([
    init/1,
    handle_call/3,
    handle_info/2,
    save_remote_data/2,
    get_local_data/1,
    purge_local_data_for_node/2
]).

%% internal
-export([multi_call_and_receive/5]).

%% macros
-define(DEFAULT_MULTI_CALL_TIMEOUT_MS, 5000).

%% includes
-include("syn.hrl").

%% ===================================================================
%% API
%% ===================================================================
-spec start_link(Scope :: atom()) ->
    {ok, Pid :: pid()} | {error, {already_started, Pid :: pid()}} | {error, Reason :: term()}.
start_link(Scope) when is_atom(Scope) ->
    syn_gen_scope:start_link(?MODULE, Scope).

-spec get_subcluster_nodes(Scope :: atom()) -> [node()].
get_subcluster_nodes(Scope) ->
    syn_gen_scope:get_subcluster_nodes(?MODULE, Scope).

-spec members(GroupName :: term()) -> [{Pid :: pid(), Meta :: term()}].
members(GroupName) ->
    members(?DEFAULT_SCOPE, GroupName).

-spec members(Scope :: atom(), GroupName :: term()) -> [{Pid :: pid(), Meta :: term()}].
members(Scope, GroupName) ->
    do_get_members(Scope, GroupName, '_').

-spec is_member(GroupName :: term(), Pid :: pid()) -> boolean().
is_member(GroupName, Pid) ->
    is_member(?DEFAULT_SCOPE, GroupName, Pid).

-spec is_member(Scope :: atom(), GroupName :: term(), Pid :: pid()) -> boolean().
is_member(Scope, GroupName, Pid) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            case find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) of
                undefined -> false;
                _ -> true
            end
    end.

-spec local_members(GroupName :: term()) -> [{Pid :: pid(), Meta :: term()}].
local_members(GroupName) ->
    local_members(?DEFAULT_SCOPE, GroupName).

-spec local_members(Scope :: atom(), GroupName :: term()) -> [{Pid :: pid(), Meta :: term()}].
local_members(Scope, GroupName) ->
    do_get_members(Scope, GroupName, node()).

-spec do_get_members(Scope :: atom(), GroupName :: term(), NodeParam :: atom()) -> [{Pid :: pid(), Meta :: term()}].
do_get_members(Scope, GroupName, NodeParam) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            ets:select(TableByName, [{
                {{GroupName, '$2'}, '$3', '_', '_', NodeParam},
                [],
                [{{'$2', '$3'}}]
            }])
    end.

-spec is_local_member(GroupName :: term(), Pid :: pid()) -> boolean().
is_local_member(GroupName, Pid) ->
    is_local_member(?DEFAULT_SCOPE, GroupName, Pid).

-spec is_local_member(Scope :: atom(), GroupName :: term(), Pid :: pid()) -> boolean().
is_local_member(Scope, GroupName, Pid) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            case find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) of
                {{_, _}, _, _, _, Node} when Node =:= node() -> true;
                _ -> false
            end
    end.

-spec join(GroupName :: term(), Pid :: pid()) -> ok.
join(GroupName, Pid) ->
    join(GroupName, Pid, undefined).

-spec join(GroupNameOrScope :: term(), PidOrGroupName :: term(), MetaOrPid :: term()) -> ok.
join(GroupName, Pid, Meta) when is_pid(Pid) ->
    join(?DEFAULT_SCOPE, GroupName, Pid, Meta);

join(Scope, GroupName, Pid) when is_pid(Pid) ->
    join(Scope, GroupName, Pid, undefined).

-spec join(Scope :: atom(), GroupName :: term(), Pid :: pid(), Meta :: term()) -> ok.
join(Scope, GroupName, Pid, Meta) ->
    Node = node(Pid),
    case syn_gen_scope:call(?MODULE, Node, Scope, {join_on_node, node(), GroupName, Pid, Meta}) of
        {ok, {CallbackMethod, Time, TableByName, TableByPid}} when Node =/= node() ->
            %% update table on caller node immediately so that subsequent calls have an updated registry
            add_to_local_table(GroupName, Pid, Meta, Time, undefined, TableByName, TableByPid),
            %% callback
            syn_event_handler:call_event_handler(CallbackMethod, [Scope, GroupName, Pid, Meta]),
            %% return
            ok;

        {Response, _} ->
            Response
    end.

-spec leave(GroupName :: term(), Pid :: pid()) -> ok | {error, Reason :: term()}.
leave(GroupName, Pid) ->
    leave(?DEFAULT_SCOPE, GroupName, Pid).

-spec leave(Scope :: atom(), GroupName :: term(), Pid :: pid()) -> ok | {error, Reason :: term()}.
leave(Scope, GroupName, Pid) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            Node = node(Pid),
            case syn_gen_scope:call(?MODULE, Node, Scope, {leave_on_node, node(), GroupName, Pid}) of
                {ok, {Meta, TableByPid}} when Node =/= node() ->
                    %% remove table on caller node immediately so that subsequent calls have an updated registry
                    remove_from_local_table(GroupName, Pid, TableByName, TableByPid),
                    %% callback
                    syn_event_handler:call_event_handler(on_process_left, [Scope, GroupName, Pid, Meta]),
                    %% return
                    ok;

                {Response, _} ->
                    Response
            end
    end.

-spec count() -> non_neg_integer().
count() ->
    count(?DEFAULT_SCOPE).

-spec count(Scope :: atom()) -> non_neg_integer().
count(Scope) ->
    do_count(Scope, '_').

-spec count(Scope :: atom(), Node :: node()) -> non_neg_integer().
count(Scope, Node) ->
    do_count(Scope, Node).

-spec local_count() -> non_neg_integer().
local_count() ->
    count(?DEFAULT_SCOPE, node()).

-spec local_count(Scope :: atom()) -> non_neg_integer().
local_count(Scope) ->
    count(Scope, node()).

-spec do_count(Scope :: atom(), NodeParam :: atom()) -> non_neg_integer().
do_count(Scope, NodeParam) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            Entries = ets:select(TableByName, [{
                {{'$1', '_'}, '_', '_', '_', NodeParam},
                [],
                ['$1']
            }]),
            Set = ordsets:from_list(Entries),
            ordsets:size(Set)
    end.

-spec group_names() -> [GroupName :: term()].
group_names() ->
    group_names(?DEFAULT_SCOPE).

-spec group_names(Scope :: atom()) -> [GroupName :: term()].
group_names(Scope) ->
    do_group_names(Scope, '_').

-spec group_names(Scope :: atom(), Node :: node()) -> [GroupName :: term()].
group_names(Scope, Node) ->
    do_group_names(Scope, Node).

-spec local_group_names() -> [GroupName :: term()].
local_group_names() ->
    group_names(?DEFAULT_SCOPE, node()).

-spec local_group_names(Scope :: atom()) -> [GroupName :: term()].
local_group_names(Scope) ->
    group_names(Scope, node()).

-spec do_group_names(Scope :: atom(), Node :: node()) -> [GroupName :: term()].
do_group_names(Scope, NodeParam) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            Groups = ets:select(TableByName, [{
                {{'$1', '_'}, '_', '_', '_', NodeParam},
                [],
                ['$1']
            }]),
            Set = ordsets:from_list(Groups),
            ordsets:to_list(Set)
    end.

-spec publish(GroupName :: term(), Message :: term()) -> {ok, RecipientCount :: non_neg_integer()}.
publish(GroupName, Message) ->
    publish(?DEFAULT_SCOPE, GroupName, Message).

-spec publish(Scope :: atom(), GroupName :: term(), Message :: term()) -> {ok, RecipientCount :: non_neg_integer()}.
publish(Scope, GroupName, Message) ->
    Members = members(Scope, GroupName),
    do_publish(Members, Message).

-spec local_publish(GroupName :: term(), Message :: term()) -> {ok, RecipientCount :: non_neg_integer()}.
local_publish(GroupName, Message) ->
    local_publish(?DEFAULT_SCOPE, GroupName, Message).

-spec local_publish(Scope :: atom(), GroupName :: term(), Message :: term()) -> {ok, RecipientCount :: non_neg_integer()}.
local_publish(Scope, GroupName, Message) ->
    Members = local_members(Scope, GroupName),
    do_publish(Members, Message).

-spec do_publish(Members :: [{Pid :: pid(), Meta :: term()}], Message :: term()) ->
    {ok, RecipientCount :: non_neg_integer()}.
do_publish(Members, Message) ->
    lists:foreach(fun({Pid, _Meta}) ->
        Pid ! Message
    end, Members),
    {ok, length(Members)}.

-spec multi_call(GroupName :: term(), Message :: term()) -> {[{pid(), Reply :: term()}], [BadPid :: pid()]}.
multi_call(GroupName, Message) ->
    multi_call(?DEFAULT_SCOPE, GroupName, Message).

-spec multi_call(Scope :: atom(), GroupName :: term(), Message :: term()) -> {[{pid(), Reply :: term()}], [BadPid :: pid()]}.
multi_call(Scope, GroupName, Message) ->
    multi_call(Scope, GroupName, Message, ?DEFAULT_MULTI_CALL_TIMEOUT_MS).

-spec multi_call(Scope :: atom(), GroupName :: term(), Message :: term(), Timeout :: non_neg_integer()) ->
    {[{pid(), Reply :: term()}], [BadPid :: pid()]}.
multi_call(Scope, GroupName, Message, Timeout) ->
    Self = self(),
    Members = members(Scope, GroupName),
    lists:foreach(fun({Pid, Meta}) ->
        spawn_link(?MODULE, multi_call_and_receive, [Self, Pid, Meta, Message, Timeout])
    end, Members),
    collect_replies(orddict:from_list(Members)).

-spec multi_call_reply(CallerPid :: pid(), Reply :: term()) -> {syn_multi_call_reply, pid(), Reply :: term()}.
multi_call_reply(CallerPid, Reply) ->
    CallerPid ! {syn_multi_call_reply, self(), Reply}.

%% ===================================================================
%% Callbacks
%% ===================================================================

%% ----------------------------------------------------------------------------------------------------------
%% Init
%% ----------------------------------------------------------------------------------------------------------
-spec init(#state{}) -> {ok, HandlerState :: term()}.
init(State) ->
    HandlerState = #{},
    %% rebuild
    rebuild_monitors(State),
    %% init
    {ok, HandlerState}.

%% ----------------------------------------------------------------------------------------------------------
%% Call messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()}, #state{}) ->
    {reply, Reply :: term(), #state{}} |
    {reply, Reply :: term(), #state{}, timeout() | hibernate | {continue, term()}} |
    {noreply, #state{}} |
    {noreply, #state{}, timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), Reply :: term(), #state{}} |
    {stop, Reason :: term(), #state{}}.
handle_call({join_on_node, RequesterNode, GroupName, Pid, Meta}, _From, #state{
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    case is_process_alive(Pid) of
        true ->
            case find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) of
                undefined ->
                    %% add
                    MRef = case find_monitor_for_pid(Pid, TableByPid) of
                        undefined -> erlang:monitor(process, Pid);  %% process is not monitored yet, create
                        MRef0 -> MRef0
                    end,
                    do_join_on_node(GroupName, Pid, Meta, MRef, RequesterNode, on_process_joined, State);

                {{_, Meta}, _, _, _, _} ->
                    %% re-joined with same meta
                    {ok, noop};

                {{_, _}, _, _, MRef, _} ->
                    do_join_on_node(GroupName, Pid, Meta, MRef, RequesterNode, on_group_process_updated, State)
            end;

        false ->
            {reply, {{error, not_alive}, undefined}, State}
    end;

handle_call({leave_on_node, RequesterNode, GroupName, Pid}, _From, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    case find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) of
        undefined ->
            {reply, {{error, not_in_group}, undefined}, State};

        {{_, _}, Meta, _, _, _} ->
            %% is this the last group process is in?
            maybe_demonitor(Pid, TableByPid),
            %% remove from table
            remove_from_local_table(GroupName, Pid, TableByName, TableByPid),
            %% callback
            syn_event_handler:call_event_handler(on_process_left, [Scope, GroupName, Pid, Meta]),
            %% broadcast
            syn_gen_scope:broadcast({'3.0', sync_leave, GroupName, Pid, Meta}, [RequesterNode], State),
            %% return
            {reply, {ok, {Meta, TableByPid}}, State}
    end;

handle_call(Request, From, #state{scope = Scope} = State) ->
    error_logger:warning_msg("SYN[~s<~s>] Received from ~p an unknown call message: ~p", [?MODULE, Scope, From, Request]),
    {reply, undefined, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Info messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_info(Info :: timeout | term(), #state{}) ->
    {noreply, #state{}} |
    {noreply, #state{}, timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), #state{}}.
handle_info({'3.0', sync_join, GroupName, Pid, Meta, Time}, State) ->
    handle_groups_sync(GroupName, Pid, Meta, Time, State),
    {noreply, State};

handle_info({'3.0', sync_leave, GroupName, Pid, Meta}, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    %% remove from table
    remove_from_local_table(GroupName, Pid, TableByName, TableByPid),
    %% callback
    syn_event_handler:call_event_handler(on_process_left, [Scope, GroupName, Pid, Meta]),
    %% return
    {noreply, State};

handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    case find_groups_entries_by_pid(Pid, TableByPid) of
        [] ->
            error_logger:warning_msg(
                "SYN[~s<~s>] Received a DOWN message from an unknown process ~p with reason: ~p",
                [?MODULE, Scope, Pid, Reason]
            );

        Entries ->
            lists:foreach(fun({{_Pid, GroupName}, Meta, _, _, _}) ->
                %% remove from table
                remove_from_local_table(GroupName, Pid, TableByName, TableByPid),
                %% callback
                syn_event_handler:call_event_handler(on_process_left, [Scope, GroupName, Pid, Meta]),
                %% broadcast
                syn_gen_scope:broadcast({'3.0', sync_leave, GroupName, Pid, Meta}, State)
            end, Entries)
    end,
    %% return
    {noreply, State};

handle_info(Info, #state{scope = Scope} = State) ->
    error_logger:warning_msg("SYN[~s<~s>] Received an unknown info message: ~p", [?MODULE, Scope, Info]),
    {noreply, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Data callbacks
%% ----------------------------------------------------------------------------------------------------------
-spec get_local_data(State :: term()) -> {ok, Data :: term()} | undefined.
get_local_data(#state{table_by_name = TableByName}) ->
    {ok, get_groups_tuples_for_node(node(), TableByName)}.

-spec save_remote_data(RemoteData :: term(), State :: term()) -> any().
save_remote_data(GroupsTuplesOfRemoteNode, State) ->
    %% insert tuples
    lists:foreach(fun({GroupName, Pid, Meta, Time}) ->
        handle_groups_sync(GroupName, Pid, Meta, Time, State)
    end, GroupsTuplesOfRemoteNode).

-spec purge_local_data_for_node(Node :: node(), State :: term()) -> any().
purge_local_data_for_node(Node, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
}) ->
    purge_groups_for_remote_node(Scope, Node, TableByName, TableByPid).

%% ===================================================================
%% Internal
%% ===================================================================
-spec rebuild_monitors(#state{}) -> ok.
rebuild_monitors(#state{
    table_by_name = TableByName
} = State) ->
    GroupsTuples = get_groups_tuples_for_node(node(), TableByName),
    do_rebuild_monitors(GroupsTuples, #{}, State).

-spec do_rebuild_monitors([syn_groups_tuple()], #{pid() => reference()}, #state{}) -> ok.
do_rebuild_monitors([], _, _) -> ok;
do_rebuild_monitors([{GroupName, Pid, Meta, Time} | T], NewMRefs, #state{
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    remove_from_local_table(GroupName, Pid, TableByName, TableByPid),
    case is_process_alive(Pid) of
        true ->
            case maps:find(Pid, NewMRefs) of
                error ->
                    MRef = erlang:monitor(process, Pid),
                    add_to_local_table(GroupName, Pid, Meta, Time, MRef, TableByName, TableByPid),
                    do_rebuild_monitors(T, maps:put(Pid, MRef, NewMRefs), State);

                {ok, MRef} ->
                    add_to_local_table(GroupName, Pid, Meta, Time, MRef, TableByName, TableByPid),
                    do_rebuild_monitors(T, NewMRefs, State)
            end;

        _ ->
            do_rebuild_monitors(T, NewMRefs, State)
    end.

-spec do_join_on_node(
    GroupName :: term(),
    Pid :: pid(),
    Meta :: term(),
    MRef :: reference() | undefined,
    RequesterNode :: node(),
    CallbackMethod :: atom(),
    #state{}
) ->
    {
        reply,
        {ok, {
            CallbackMethod :: atom(),
            Time :: non_neg_integer(),
            TableByName :: atom(),
            TableByPid :: atom()
        }},
        #state{}
    }.
do_join_on_node(GroupName, Pid, Meta, MRef, RequesterNode, CallbackMethod, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    Time = erlang:system_time(),
    %% add to local table
    add_to_local_table(GroupName, Pid, Meta, Time, MRef, TableByName, TableByPid),
    %% callback
    syn_event_handler:call_event_handler(CallbackMethod, [Scope, GroupName, Pid, Meta]),
    %% broadcast
    syn_gen_scope:broadcast({'3.0', sync_join, GroupName, Pid, Meta, Time}, [RequesterNode], State),
    %% return
    {reply, {ok, {CallbackMethod, Time, TableByName, TableByPid}}, State}.

-spec get_groups_tuples_for_node(Node :: node(), TableByName :: atom()) -> [syn_groups_tuple()].
get_groups_tuples_for_node(Node, TableByName) ->
    ets:select(TableByName, [{
        {{'$1', '$2'}, '$3', '$4', '_', Node},
        [],
        [{{'$1', '$2', '$3', '$4'}}]
    }]).

-spec find_monitor_for_pid(Pid :: pid(), TableByPid :: atom()) -> reference() | undefined.
find_monitor_for_pid(Pid, TableByPid) when is_pid(Pid) ->
    %% we use select instead of lookup to limit the results and thus cover the case
    %% when a process is in multiple groups
    case ets:select(TableByPid, [{
        {{Pid, '_'}, '_', '_', '$5', '_'},
        [],
        ['$5']
    }], 1) of
        {[MRef], _} -> MRef;
        '$end_of_table' -> undefined
    end.

-spec find_groups_entry_by_name_and_pid(GroupName :: term(), Pid :: pid(), TableByName :: atom()) ->
    Entry :: syn_groups_entry() | undefined.
find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) ->
    case ets:lookup(TableByName, {GroupName, Pid}) of
        [] -> undefined;
        [Entry] -> Entry
    end.

-spec find_groups_entries_by_pid(Pid :: pid(), TableByPid :: atom()) -> GroupEntries :: [syn_groups_entry()].
find_groups_entries_by_pid(Pid, TableByPid) when is_pid(Pid) ->
    ets:select(TableByPid, [{
        {{Pid, '_'}, '_', '_', '_', '_'},
        [],
        ['$_']
    }]).

-spec maybe_demonitor(Pid :: pid(), TableByPid :: atom()) -> ok.
maybe_demonitor(Pid, TableByPid) ->
    %% select 2: if only 1 is returned it means that no other aliases exist for the Pid
    %% we use select instead of lookup to limit the results and thus cover the case
    %% when a process is in multiple groups
    case ets:select(TableByPid, [{
        {{Pid, '_'}, '_', '_', '$5', '_'},
        [],
        ['$5']
    }], 2) of
        {[MRef], _} when is_reference(MRef) ->
            %% no other aliases, demonitor
            erlang:demonitor(MRef, [flush]),
            ok;

        _ ->
            ok
    end.

-spec add_to_local_table(
    GroupName :: term(),
    Pid :: pid(),
    Meta :: term(),
    Time :: integer(),
    MRef :: undefined | reference(),
    TableByName :: atom(),
    TableByPid :: atom()
) -> true.
add_to_local_table(GroupName, Pid, Meta, Time, MRef, TableByName, TableByPid) ->
    %% insert
    ets:insert(TableByName, {{GroupName, Pid}, Meta, Time, MRef, node(Pid)}),
    ets:insert(TableByPid, {{Pid, GroupName}, Meta, Time, MRef, node(Pid)}).

-spec remove_from_local_table(
    Name :: term(),
    Pid :: pid(),
    TableByName :: atom(),
    TableByPid :: atom()
) -> true.
remove_from_local_table(GroupName, Pid, TableByName, TableByPid) ->
    true = ets:delete(TableByName, {GroupName, Pid}),
    true = ets:delete(TableByPid, {Pid, GroupName}).

-spec purge_groups_for_remote_node(Scope :: atom(), Node :: atom(), TableByName :: atom(), TableByPid :: atom()) -> true.
purge_groups_for_remote_node(Scope, Node, TableByName, TableByPid) when Node =/= node() ->
    %% loop elements for callback in a separate process to free scope process
    GroupsTuples = get_groups_tuples_for_node(Node, TableByName),
    spawn(fun() ->
        lists:foreach(fun({GroupName, Pid, Meta, _Time}) ->
            syn_event_handler:call_event_handler(on_process_left, [Scope, GroupName, Pid, Meta])
        end, GroupsTuples)
    end),
    ets:match_delete(TableByName, {{'_', '_'}, '_', '_', '_', Node}),
    ets:match_delete(TableByPid, {{'_', '_'}, '_', '_', '_', Node}).

-spec handle_groups_sync(
    GroupName :: term(),
    Pid :: pid(),
    Meta :: term(),
    Time :: non_neg_integer(),
    #state{}
) -> any().
handle_groups_sync(GroupName, Pid, Meta, Time, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
}) ->
    case find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) of
        undefined ->
            %% new
            add_to_local_table(GroupName, Pid, Meta, Time, undefined, TableByName, TableByPid),
            %% callback
            syn_event_handler:call_event_handler(on_process_joined, [Scope, GroupName, Pid, Meta]);

        {{GroupName, Pid}, TableMeta, TableTime, _MRef, _TableNode} when Time > TableTime ->
            %% maybe updated meta or time only
            add_to_local_table(GroupName, Pid, Meta, Time, undefined, TableByName, TableByPid),
            %% callback (call only if meta update)
            case TableMeta =/= Meta of
                true -> syn_event_handler:call_event_handler(on_group_process_updated, [Scope, GroupName, Pid, Meta]);
                _ -> ok
            end;

        {{GroupName, Pid}, _TableMeta, _TableTime, _TableMRef, _TableNode} ->
            %% race condition: incoming data is older, ignore
            ok
    end.

-spec multi_call_and_receive(
    CollectorPid :: pid(),
    Pid :: pid(),
    Meta :: term(),
    Message :: term(),
    Timeout :: non_neg_integer()
) -> any().
multi_call_and_receive(CollectorPid, Pid, Meta, Message, Timeout) ->
    %% monitor
    MRef = monitor(process, Pid),
    %% send
    Pid ! {syn_multi_call, Message, self(), Meta},
    %% wait for reply
    receive
        {syn_multi_call_reply, Pid, Reply} ->
            CollectorPid ! {reply, Pid, Reply};

        {'DOWN', MRef, _, _, _} ->
            CollectorPid ! {bad_pid, Pid}

    after Timeout ->
        CollectorPid ! {bad_pid, Pid}
    end.

-spec collect_replies(MembersOD :: orddict:orddict({pid(), Meta :: term()})) ->
    {
        Replies :: [{{pid(), Meta :: term()}, Reply :: term()}],
        BadReplies :: [{pid(), Meta :: term()}]
    }.
collect_replies(MembersOD) ->
    collect_replies(MembersOD, [], []).

-spec collect_replies(
    MembersOD :: orddict:orddict({pid(), Meta :: term()}),
    Replies :: [{{pid(), Meta :: term()}, Reply :: term()}],
    BadReplies :: [{pid(), Meta :: term()}]
) ->
    {
        Replies :: [{{pid(), Meta :: term()}, Reply :: term()}],
        BadReplies :: [{pid(), Meta :: term()}]
    }.
collect_replies([], Replies, BadReplies) -> {Replies, BadReplies};
collect_replies(MembersOD, Replies, BadReplies) ->
    receive
        {reply, Pid, Reply} ->
            {Meta, MembersOD1} = orddict:take(Pid, MembersOD),
            collect_replies(MembersOD1, [{{Pid, Meta}, Reply} | Replies], BadReplies);

        {bad_pid, Pid} ->
            {Meta, MembersOD1} = orddict:take(Pid, MembersOD),
            collect_replies(MembersOD1, Replies, [{Pid, Meta} | BadReplies])
    end.
