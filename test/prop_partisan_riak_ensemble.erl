%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Christopher S. Meiklejohn.  All Rights Reserved.
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

-module(prop_partisan_riak_ensemble).

-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-include("partisan.hrl").

-include_lib("proper/include/proper.hrl").

-compile([export_all]).

-define(ASSERT_MAILBOX, true).

-define(PERFORM_SUMMARY, false).

%%%===================================================================
%%% Generators
%%%===================================================================

key() ->
    oneof(keys()).

keys() ->
    [rkey].

value() ->
    oneof([value1, value2, value3]).

node_name() ->
    oneof(names()).

names() ->
    NameFun = fun(N) -> 
        list_to_atom("node_" ++ integer_to_list(N)) 
    end,
    lists:map(NameFun, lists:seq(1, node_num_nodes())).

%%%===================================================================
%%% Node Functions
%%%===================================================================

-record(node_state, {values}).

%% How many nodes to run?
node_num_nodes() ->
    4.

%% What node-specific operations should be called.
node_commands() ->
    [{call, ?MODULE, write, [node_name(), key(), value()]}].

%% Assertion commands.
node_assertion_functions() ->
    [read].

%% Global functions.
node_global_functions() ->
    [read].

%% What should the initial node state be.
node_initial_state() ->
    node_debug("initializing", []),
    #node_state{values=dict:new()}.

%% Names of the node functions so we kow when we can dispatch to the node
%% pre- and postconditions.
node_functions() ->
    lists:map(fun({call, _Mod, Fun, _Args}) -> Fun end, node_commands()).

%% Precondition.
node_precondition(_NodeState, {call, ?MODULE, write, [_Node, _Key, _Value]}) ->
    true;
node_precondition(_NodeState, _Command) ->
    false.

%% Next state.
node_next_state(#property_state{joined_nodes=_JoinedNodes}, 
                #node_state{values=Values0}=NodeState, 
                {ok, _}, 
                {call, ?MODULE, write, [_Node, Key, Value]}) ->
    Values = dict:store(Key, Value, Values0),
    NodeState#node_state{values=Values};

%% Fallthrough.
node_next_state(_State, NodeState, _Response, _Command) ->
    NodeState.

%% Postconditions for node commands.
node_postcondition(_NodeState, {call, ?MODULE, write, [_Node, _Key, _Value]}, {ok, _}) ->
    true;
node_postcondition(#node_state{values=Values}=_NodeState, {call, ?MODULE, read, []}, Results) ->
    logger:info("results: ~p", [Results]),
    logger:info("values: ~p", [dict:to_list(Values)]),

    Result = lists:foldl(fun({Key, {obj, _, _, Key, Value}}, Acc) ->
        logger:info("looking for ~p with value ~p", [Key, Value]),

        case dict:find(Key, Values) of 
            {ok, Value} ->
                logger:info("found!", []),
                true andalso Acc;
            error ->
                case Value of 
                    notfound ->
                        true andalso Acc;
                    _ ->
                        logger:info("not found when it should be!", []),
                        false andalso Acc
                end
        end
    end, true, Results),

    Result;
node_postcondition(_NodeState, Command, Response) ->
    node_debug("generic postcondition fired (this probably shouldn't be hit) for command: ~p with response: ~p", 
               [Command, Response]),
    false.

%%%===================================================================
%%% Commands
%%%===================================================================

-define(PROPERTY_MODULE, prop_partisan).

-define(TABLE, table).
-define(RECEIVER, receiver).

-define(ETS, prop_partisan).
-define(NAME, fun(Name) -> [{_, NodeName}] = ets:lookup(?ETS, Name), NodeName end).

%% @private
write(Node, Key, Value) ->
    ?PROPERTY_MODULE:command_preamble(Node, [write, Key, Value]),

    Result = rpc:call(?NAME(Node), riak_ensemble_client, kover, [root, Key, Value, 5000], 5000),

    ?PROPERTY_MODULE:command_conclusion(Node, [write, Key, Value]),

    Result.

%% @private
read() ->
    RunnerNode = node(),

    ?PROPERTY_MODULE:command_preamble(RunnerNode, [read]),

    %% Get all keys.
    Node = hd(names()),

    Result = lists:map(fun(Key) ->
        {ok, Value} = rpc:call(?NAME(Node), riak_ensemble_client, kget, [root, Key, 5000], 5000),
        {Key, Value}
    end, keys()),

    ?PROPERTY_MODULE:command_conclusion(RunnerNode, [read]),

    Result.

%%%===================================================================
%%% Helper Functions
%%%===================================================================

-define(NODE_DEBUG, true).

%% Should we do node debugging?
node_debug(Line, Args) ->
    case ?NODE_DEBUG of
        true ->
            logger:info("~p: " ++ Line, [?MODULE] ++ Args);
        false ->
            ok
    end.

%% @private
loop() ->
    receive
        terminate ->
            ok
    end,
    loop().

%% @private
node_begin_property() ->
    partisan_trace_orchestrator:start_link().

%% @private
node_begin_case() ->
    %% Get nodes.
    [{nodes, Nodes}] = ets:lookup(prop_partisan, nodes),

    %% Enable pid encoding.
    lists:foreach(fun({ShortName, _}) ->
        node_debug("enabling pid_encoding at node ~p", [ShortName]),
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [pid_encoding, true])
    end, Nodes),

    %% Enable register_pid_for_encoding.
    lists:foreach(fun({ShortName, _}) ->
        node_debug("enabling register_pid_for_encoding at node ~p", [ShortName]),
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [register_pid_for_encoding, true])
    end, Nodes),

    %% Load, configure, and start ensemble.
    lists:foreach(fun({ShortName, _}) ->
        node_debug("starting riak_ensemble at node ~p", [ShortName]),
        ok = rpc:call(?NAME(ShortName), application, load, [riak_ensemble]),

        DataRoot = "data-root-" ++ atom_to_list(?NAME(ShortName)),

        node_debug("removing old data root: ~p", [DataRoot]),
        os:cmd("rm -rf ./" ++ DataRoot),

        node_debug("configuring riak_ensemble at node ~p for data_root ~p", [ShortName, DataRoot]),
        ok = rpc:call(?NAME(ShortName), application, set_env, [riak_ensemble, data_root, DataRoot]),

        node_debug("starting riak_ensemble at node ~p", [ShortName]),
        {ok, _} = rpc:call(?NAME(ShortName), application, ensure_all_started, [riak_ensemble])
    end, Nodes),

    %% Cluster ensemble.
    {FirstName, _} = hd(Nodes),

    %% Enable enable at node.
    node_debug("calling riak_ensemble_manager:enable/0 on node ~p", [FirstName]),
    ok = rpc:call(?NAME(FirstName), riak_ensemble_manager, enable, []),

    node_debug("waiting for cluster stability on node: ~p", [FirstName]),
    wait_stable(?NAME(FirstName), root),

    node_debug("getting leader id from node: ~p", [FirstName]),
    RootLeader = rpc:call(?NAME(FirstName), riak_ensemble_manager, rleader_pid, []),
    node_debug("root_leader: ~p", [RootLeader]),

    %% Join remote nodes to the root.
    lists:foreach(fun({ShortName, _}) ->
        %% Join the node.
        ok = rpc:call(?NAME(FirstName), riak_ensemble_manager, join, [?NAME(FirstName), ?NAME(ShortName)]),

        %% Sleep for convergenece.
        timer:sleep(10000),
        
        %% Wait on the shortname.
        wait_stable(?NAME(ShortName), root),

        % Result = rpc:call(?NAME(FirstName), riak_ensemble_manager, cluster, []),
        % logger:info("Result from cluster: ~p", [Result]),

        %% Wait for stabilization.
        wait_stable(?NAME(FirstName), root),

        %% Add member to root ensemble.
        ok = rpc:call(?NAME(FirstName), riak_ensemble_peer, update_members, [RootLeader, [{add, {root, ?NAME(ShortName)}}], 10000]),

        %% Wait until stable.
        wait_stable(?NAME(FirstName), root)
    end, tl(Nodes)),

    %% Wait for membership to be correct.
    ShouldMembers = lists:map(fun({X, _}) -> {root, ?NAME(X)} end, Nodes),
    node_debug("waiting for membership on node: ~p after join", [FirstName]),
    wait_members(?NAME(FirstName), root, ShouldMembers),

    %% Wait for root ensemble stability.
    node_debug("waiting for root ensemble stability on node: ~p after join", [FirstName]),
    wait_stable(?NAME(FirstName), root),

    %% Create partisan ensemble.
    node_debug("creating ensemble for the test on node ~p", [FirstName]),
    EnsembleId = partisan,
    Mod = riak_ensemble_basic_backend,
    Arg = [],
    ok = rpc:call(?NAME(FirstName), riak_ensemble_manager, create_ensemble, [EnsembleId, {root, ?NAME(FirstName)}, ShouldMembers, Mod, Arg]),

    %% Wait for partisan ensemble stability.
    node_debug("waiting for partisan ensemble stability on node: ~p after join", [FirstName]),
    wait_stable(?NAME(FirstName), partisan),

    %% Get members of the root ensemble.
    node_debug("getting members of the root ensemble on node ~p", [FirstName]),
    RootEnsembleMembers = rpc:call(?NAME(FirstName), riak_ensemble_manager, get_members, [root]),
    node_debug("=> ~p", [RootEnsembleMembers]),

    %% Get members of the partisan ensemble.
    node_debug("getting members of the partisan ensemble on node ~p", [FirstName]),
    PartisanEnsembleMembers = rpc:call(?NAME(FirstName), riak_ensemble_manager, get_members, [partisan]),
    node_debug("=> ~p", [PartisanEnsembleMembers]),

    %% Perform a single write to ensure the cluster is ready.
    node_debug("performing root ensemble write to ensure cluster is online and ready.", []),
    {ok, RRes} = rpc:call(?NAME(FirstName), riak_ensemble_client, kover, [root, rkey, "first", 5000], 5000),
    node_debug("write completed: ~p", [RRes]),

    %% Perform a second write to ensure the cluster is ready.
    node_debug("performing partisan ensemble write to ensure cluster is online and ready.", []),
    {ok, PRes} = rpc:call(?NAME(FirstName), riak_ensemble_client, kover, [partisan, pkey, "second", 5000], 5000),
    node_debug("write completed: ~p", [PRes]),

    ok.

%% @private
node_end_case() ->
    node_debug("ending case", []),

    ok.

%% @private
wait_stable(Node, Ensemble) ->
    case check_stable(Node, Ensemble) of
        true ->
            ok;
        false ->
            wait_stable(Node, Ensemble)
    end.

%% @private
check_stable(Node, Ensemble) ->
    case rpc:call(Node, riak_ensemble_manager, check_quorum, [Ensemble, 1000]) of
        true ->
            case rpc:call(Node, riak_ensemble_peer, stable_views, [Ensemble, 1000]) of
                {ok, true} ->
                    true;
                _Other ->
                    false
            end;
        false ->
            false
    end.

%% @private
wait_members(Node, Ensemble, Expected) ->
    Members = rpc:call(Node, riak_ensemble_manager, get_members, [Ensemble]),

    % io:format("expected: ~p~n", [Expected]),
    % io:format("members: ~p~n", [Members]),

    case (Expected -- Members) of
        [] ->
            ok;
        _ ->
            timer:sleep(1000),
            wait_members(Node, Ensemble, Expected)
    end.