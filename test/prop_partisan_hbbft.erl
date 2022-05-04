%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Christopher S. Meiklejohn.  All Rights Reserved.
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

-module(prop_partisan_hbbft).

-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-include("partisan.hrl").

-include_lib("proper/include/proper.hrl").

-compile([export_all]).

-define(TIMEOUT, 10000).
-define(RETRY_SECONDS, 240).

%%%===================================================================
%%% Generators
%%%===================================================================

message() ->
    crypto:strong_rand_bytes(128).

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

-record(node_state, {messages}).

%% What node-specific operations should be called.
node_commands() ->
    [
        {call, ?MODULE, submit_transaction, [node_name(), message()]},
        {call, ?MODULE, trigger_sync, [node_name(), node_name()]}
    ].

%% Assertion commands.
node_assertion_functions() ->
    [check].

%% Global functions.
node_global_functions() ->
    [sleep, check].

%% What should the initial node state be.
node_initial_state() ->
    node_debug("initializing", []),
    #node_state{messages=[]}.

%% Names of the node functions so we kow when we can dispatch to the node
%% pre- and postconditions.
node_functions() ->
    lists:map(fun({call, _Mod, Fun, _Args}) -> Fun end, node_commands()).

%% Precondition.
node_precondition(_NodeState, {call, ?MODULE, submit_transaction, [_Node, _Message]}) ->
    true;
node_precondition(_NodeState, {call, ?MODULE, trigger_sync, [Node1, Node2]}) ->
    Node1 /= Node2;
node_precondition(_NodeState, {call, ?MODULE, wait, [_Node]}) ->
    true;
node_precondition(_NodeState, {call, ?MODULE, sleep, []}) ->
    true;
node_precondition(_NodeState, {call, ?MODULE, check, []}) ->
    true;
node_precondition(_NodeState, _Command) ->
    false.

%% Next state.
node_next_state(_State, #node_state{messages=Messages}=NodeState, _Response, {call, ?MODULE, submit_transaction, [_Node, Message]}) ->
    NodeState#node_state{messages=Messages ++ [Message]};
node_next_state(_State, NodeState, _Response, _Command) ->
    NodeState.

%% Postconditions for node commands.
node_postcondition(_NodeState, {call, ?MODULE, trigger_sync, [_Node1, _Node2]}, ok) ->
    true;
node_postcondition(_NodeState, {call, ?MODULE, submit_transaction, [_Node, _Message]}, _Result) ->
    true;
node_postcondition(_NodeState, {call, ?MODULE, wait, [_Node]}, _Result) ->
    true;
node_postcondition(_NodeState, {call, ?MODULE, sleep, []}, _Result) ->
    true;
node_postcondition(_NodeState, {call, ?MODULE, check, []}, undefined) ->
    true;
node_postcondition(#node_state{messages=Messages}=_NodeState, {call, ?MODULE, check, []}, Chains) ->
    %% Get pubkey.
    [{pubkey, PubKey}] = ets:lookup(prop_partisan, pubkey),

    %% Get initial messages.
    [{initial_messages, InitialMessages}] = ets:lookup(prop_partisan, initial_messages),

    [{workers, Workers}] = ets:lookup(prop_partisan, workers),

    lists:foreach(fun(Chain) ->
                          %node_debug("Chain: ~p~n", [Chain]),
                          %node_debug("chain is of height ~p~n", [length(Chain)]),

                          %% verify they are cryptographically linked,
                          true = partisan_hbbft_worker:verify_chain(Chain, PubKey),

                          %% check all transactions are unique
                          BlockTxns = lists:flatten([partisan_hbbft_worker:block_transactions(B) || B <- Chain]),
                          true = length(BlockTxns) == sets:size(sets:from_list(BlockTxns)),

                          %% check they're all members of the original message list
                          true = sets:is_subset(sets:from_list(BlockTxns), sets:from_list(Messages ++ InitialMessages)),

                          %node_debug("length(BlockTxns): ~p", [length(BlockTxns)]),
                          %node_debug("length(Messages ++ InitialMessages): ~p", [length(Messages ++ InitialMessages)]),
                          %% find all the transactions still in everyone's buffer
                          StillInBuf = sets:intersection([ sets:from_list(B) || B <- buffers(Workers)]),

                          %node_debug("length(StillInBuf): ~p", [sets:size(StillInBuf)]),

                          %Difference = sets:subtract(sets:subtract(sets:from_list(Messages ++ InitialMessages), sets:from_list(BlockTxns)), StillInBuf),
                          %node_debug("Difference: ~p", [sets:to_list(Difference)]),

                          case length(BlockTxns) =:= length(Messages ++ InitialMessages) - sets:size(StillInBuf) of
                              true -> ok;
                              false ->
                                  statuses(Workers),
                                  erlang:error(failed)
                          end,

                          %node_debug("chain contains ~p distinct transactions~n", [length(BlockTxns)])
                        ok
                  end, sets:to_list(Chains)),

    node_debug("Waiting for buffer flush before final assertion...", []),

    %% Make sure only the tolerance level of nodes has crashed.
    Crashed = lists:foldl(fun({_Node, {ok, W}}, Acc) ->
        try
            {ok, _Status} = partisan_hbbft_worker:get_status(W),
            Acc
        catch
            _:_ ->
                Acc + 1
        end
    end, 0, Workers),

    BufferEmpty = case wait_until(fun() ->
                          StillInBuf = sets:intersection([ sets:from_list(B) || B <- buffers(Workers)]),
                          length(sets:to_list(StillInBuf)) =:= 0
                  end, ?RETRY_SECONDS*2, 500) of 
        ok ->
            true;
        _ ->
            false
    end,

    StillInBuf = sets:intersection([ sets:from_list(B) || B <- buffers(Workers)]),
    StillInBufLength = length(sets:to_list(StillInBuf)),
    node_debug("StillInBufLength: ~p", [StillInBufLength]),

    %% Check we actually converged and made a chain.
    OneChain = (1 == sets:size(Chains)),
    NonTrivialLength = (0 < length(hd(sets:to_list(Chains)))),

    node_debug("OneChain: ~p", [OneChain]),
    Length = length(hd(sets:to_list(Chains))),
    node_debug("NonTrivialLength: ~p", [NonTrivialLength]),
    node_debug("Length: ~p", [Length]),
    node_debug("BufferEmpty: ~p", [BufferEmpty]),

    node_debug("Crashed: ~p", [Crashed]),

    Tolerance = case os:getenv("FAULT_TOLERANCE") of 
        false ->
            1;
        ToleranceString ->
            list_to_integer(ToleranceString)
    end,

    Result = OneChain andalso NonTrivialLength andalso BufferEmpty andalso Crashed =< Tolerance,
    node_debug("postcondition: ~p", [Result]),
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
check() ->
    %% Get workers.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),

    %% Get at_least_one_transaction.
    case ets:lookup(prop_partisan, at_least_one_transaction) of 
        [{at_least_one_transaction, true}] ->
            %% Wait for all the worker's mailboxes to settle and wait for the chains to converge.
            wait_until(fun() ->
                            Chains = chains(Workers),

                            % node_debug("Chains: ~p", [sets:to_list(Chains)]),
                            node_debug("message_queue_lens(Workers): ~p should = 0", [message_queue_lens(Workers)]),
                            node_debug("sets:size(Chains): ~p should = 1", [sets:size(Chains)]),
                            node_debug("length(hd(sets:to_list(Chains))): ~p should /= 0", [length(hd(sets:to_list(Chains)))]),

                            0 == message_queue_lens(Workers) andalso
                            1 == sets:size(Chains) andalso
                            0 /= length(hd(sets:to_list(Chains)))
                       end, ?RETRY_SECONDS*2, 500),

            Chains = chains(Workers),
            node_debug("~p distinct chains~n", [sets:size(Chains)]),

            Chains;
        [] ->
            undefined
    end.

%% @private
submit_transaction(Node, Message) ->
    ?PROPERTY_MODULE:command_preamble(Node, [submit_transaction, Node]),

    %% Get workers.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),

    %% Mark that we did at least one transaction.
    true = ets:insert(prop_partisan, {at_least_one_transaction, true}),

    %% Submit transaction to all workers.
    lists:foreach(fun({_Node, {ok, Worker}}) ->
        partisan_hbbft_worker:submit_transaction(Message, Worker)
    end, Workers),

    %% Start on demand on all nodes.
    lists:foreach(fun({_Node, {ok, Worker}}) ->
        partisan_hbbft_worker:start_on_demand(Worker)
    end, Workers),

    ?PROPERTY_MODULE:command_conclusion(Node, [submit_transaction, Node]),

    ok.

trigger_sync(Node1, Node2) ->
    ?PROPERTY_MODULE:command_preamble(Node1, [trigger_sync, Node1, Node2]),

    %% Get workers.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),

    %% Get node 1's worker.
    {ok, Node1Worker} = proplists:get_value({Node1, ?NAME(Node1)}, Workers),

    %% Get node 2's worker.
    {ok, Node2Worker} = proplists:get_value({Node2, ?NAME(Node2)}, Workers),

    partisan_hbbft_worker:sync(Node1Worker, Node2Worker),

    ?PROPERTY_MODULE:command_conclusion(Node1, [trigger_sync, Node1, Node2]),

    ok.

%% @private
wait(Node) ->
    ?PROPERTY_MODULE:command_preamble(Node, [wait]),

    node_debug("waiting...", []),
    timer:sleep(1000),

    ?PROPERTY_MODULE:command_conclusion(Node, [wait]),

    ok.

%% @private
sleep() ->
    RunnerNode = node(),

    ?PROPERTY_MODULE:command_preamble(RunnerNode, [sleep]),

    %% Get workers.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),

    %% Start on demand on all nodes.
    lists:foreach(fun({_Node, {ok, Worker}}) ->
        % node_debug("forcing start on demand for node: ~p, worker: ~p", [Node, Worker]),
        %% This may fail if the node has been crashed because it was faulty.
        catch partisan_hbbft_worker:start_on_demand(Worker)
    end, Workers),

    %node_debug("sleeping for 60 seconds...", []),
    %timer:sleep(60000),

    ?PROPERTY_MODULE:command_conclusion(RunnerNode, [sleep]),

    ok.

%%%===================================================================
%%% Helper Functions
%%%===================================================================

-define(NODE_DEBUG, true).

%% How many nodes?
node_num_nodes() ->
    7.

%% Should we do node debugging?
node_debug(Line, Args) ->
    case ?NODE_DEBUG of
        true ->
            logger:info("~p: " ++ Line, [?MODULE] ++ Args);
        false ->
            ok
    end.

%% @private
node_begin_property() ->
    partisan_trace_orchestrator:start_link().

%% @private
node_begin_case() ->
    %% Get nodes.
    [{nodes, Nodes}] = ets:lookup(prop_partisan, nodes),

    %% Enable pid encoding.
    lists:foreach(fun({ShortName, _}) ->
        % node_debug("enabling pid_encoding at node ~p", [ShortName]),
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [pid_encoding, true])
    end, Nodes),

    %% Enable replay (for pre-interposition async.)
    lists:foreach(fun({ShortName, _}) ->
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [replaying, true])
    end, Nodes),
    partisan_config:set(replaying, true),

    %% Enable shrink (for pre-interposition async.)
    lists:foreach(fun({ShortName, _}) ->
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [shrinking, true])
    end, Nodes),
    partisan_config:set(shrinking, true),

    %% Disable tracing.
    lists:foreach(fun({ShortName, _}) ->
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [tracing, false])
    end, Nodes),
    partisan_config:set(shrinking, true),

    %% Load, configure, and start hbbft.
    lists:foreach(fun({ShortName, _}) ->
        % node_debug("loading hbbft at node ~p", [ShortName]),
        case rpc:call(?NAME(ShortName), application, load, [hbbft]) of 
            ok ->
                ok;
            {error, {already_loaded, hbbft}} ->
                ok;
            Other ->
                exit({error, {load_failed, Other}})
        end,

        % node_debug("starting hbbft at node ~p", [ShortName]),
        {ok, _} = rpc:call(?NAME(ShortName), application, ensure_all_started, [hbbft])
    end, Nodes),

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Start hbbft test
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 

    node_debug("warming up hbbft...", []),
    node_debug("nodes: ~p", [Nodes]),

    %% Master starts the dealer.
    N = length(Nodes),
    F = (N div 3),
    BatchSize = 1,
    {ok, Dealer} = dealer:new(N, F+1, 'SS512'),
    {ok, {PubKey, PrivateKeys}} = dealer:deal(Dealer),

    %% Store pubkey.
    true = ets:insert(prop_partisan, {pubkey, PubKey}),

    %% each node gets a secret key
    NodesSKs = lists:zip(Nodes, PrivateKeys),

    %% load partisan_hbbft_worker on each node
    {Mod, Bin, _} = code:get_object_code(partisan_hbbft_worker),
    _ = lists:map(fun(Node) -> rpc:call(Node, erlang, load_module, [Mod, Bin]) end, Nodes),

    %% start a hbbft_worker on each node
    Workers = lists:map(fun({I, {{Name1, _} = FullName, SK}}) ->
        {ok, Worker} = rpc:call(?NAME(Name1), partisan_hbbft_worker, start_link, [N, F, I, tpke_privkey:serialize(SK), BatchSize, false]),
        node_debug("worker started on node ~p with pid ~p", [Name1, Worker]),
        {FullName, {ok, Worker}}
    end, enumerate(NodesSKs)),
    ok = global:sync(),

    %% store workers in the ets table
    true = ets:insert(prop_partisan, {workers, Workers}),

    case os:getenv("BOOTSTRAP") of 
        "true" ->
            node_debug("beginning bootstrap...", []),

            %% Configure the number of bootstrap transactions.
            NumMsgs = case os:getenv("BOOTSTRAP_MESSAGES") of 
                false ->
                    N * BatchSize;
                Other ->
                    list_to_integer(Other)
            end,
            node_debug("setting number of bootstrap messages to: ~p", [NumMsgs]),

            %% generate a bunch of msgs
            Msgs = [crypto:strong_rand_bytes(128) || _ <- lists:seq(1, NumMsgs)],

            %% feed the nodes some msgs
            node_debug("submitting transactions...", []),
            lists:foreach(fun(Msg) ->
                node_debug("=> message ~p", [Msg]),

                lists:foreach(fun({_Node, {ok, Worker}}) ->
                    node_debug("=> => txn for worker ~p", [Worker]),
                    partisan_hbbft_worker:submit_transaction(Msg, Worker)
                end, Workers)
            end, Msgs),
            node_debug("transactions submitted!", []),

            %% Start on demand on all nodes.
            node_debug("issuing start_on_demands...", []),
            lists:foreach(fun({_Node, {ok, Worker}}) ->
                partisan_hbbft_worker:start_on_demand(Worker)
            end, Workers),

            node_debug("waiting for mailboxes to settle...", []),
            %% wait for all the worker's mailboxes to settle and.
            %% wait for the chains to converge
            case wait_until(fun() ->
                                    Chains = chains(Workers),

                                    node_debug("====================================", []),
                                    % node_debug("Chains: ~p", [sets:to_list(Chains)]),
                                    node_debug("message_queue_lens(Workers): ~p should = 0", [message_queue_lens(Workers)]),
                                    node_debug("sets:size(Chains): ~p should = 1", [sets:size(Chains)]),
                                    node_debug("length(hd(sets:to_list(Chains))): ~p should /= 0", [length(hd(sets:to_list(Chains)))]),

                                    case length(hd(sets:to_list(Chains))) > 0 of
                                        true ->
                                            lists:foreach(fun(X) ->
                                                node_debug("looking at chain ~p...", [X]),
                                                Chain = lists:nth(X, sets:to_list(Chains)),

                                                %% check all transactions are unique
                                                node_debug("=> number of blocks: ~p", [length(Chain)]),
                                                BlockTxns = lists:flatten([partisan_hbbft_worker:block_transactions(B) || B <- Chain]),
                                                node_debug("=> number of transactions: ~p", [length(BlockTxns)])
                                            end, lists:seq(1, length(sets:to_list(Chains)))),
                                            
                                            ok;
                                        false ->
                                            ok
                                    end,

                                    0 == message_queue_lens(Workers) andalso
                                    1 == sets:size(Chains) andalso
                                    0 /= length(hd(sets:to_list(Chains)))
                            end, 60*2, 500) of
                ok ->
                    ok;
                _ ->
                    statuses(Workers),
                    erlang:error(failed)
            end,
            node_debug("mailboxes settled...", []),

            Chains = sets:from_list(lists:map(fun({_Node, {ok, Worker}}) ->
                                                    {ok, Blocks} = partisan_hbbft_worker:get_blocks(Worker),
                                                    Blocks
                                            end, Workers)),
            node_debug("~p distinct chains~n", [sets:size(Chains)]),

            lists:foreach(fun(Chain) ->
                                %node_debug("Chain: ~p~n", [Chain]),
                                node_debug("chain is of height ~p~n", [length(Chain)]),

                                %% verify they are cryptographically linked,
                                true = partisan_hbbft_worker:verify_chain(Chain, PubKey),

                                %% check all transactions are unique
                                BlockTxns = lists:flatten([partisan_hbbft_worker:block_transactions(B) || B <- Chain]),
                                true = length(BlockTxns) == sets:size(sets:from_list(BlockTxns)),

                                %% check they're all members of the original message list
                                true = sets:is_subset(sets:from_list(BlockTxns), sets:from_list(Msgs)),
                                node_debug("chain contains ~p distinct transactions~n", [length(BlockTxns)])
                        end, sets:to_list(Chains)),

            %% check we actually converged and made a chain
            true = (1 == sets:size(Chains)),
            true = (0 < length(hd(sets:to_list(Chains)))),

            %% Insert into initial messages.
            true = ets:insert(prop_partisan, {initial_messages, Msgs}),

            %% TEMP: force a failure here.
            case os:getenv("BOOTSTRAP_FAILURE") of 
                "true" ->
                    exit({error, forced_failure});
                _ ->
                    ok
            end,

            ok;
        _ ->
            node_debug("bypassing bootstrap...", []),

            %% Insert into initial messages.
            true = ets:insert(prop_partisan, {initial_messages, []}),

            ok
    end,

    %% Sleep.
    node_debug("sleeping for convergence", []),
    timer:sleep(1000),
    node_debug("done.", []),

    node_debug("hbbft initialized!", []),

    ok.

%% @private
node_crash(Node) ->
    node_debug("node crash executing for node ~p", [Node]),

    %% Get full name of node to crash.
    NodeToCrash = ?NAME(Node),

    %% Get workers and terminate them if they are on that node.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),

    lists:foreach(fun({_, {ok, W}}) -> 
        case node(W) of 
            NodeToCrash ->
                node_debug("terminating process: ~p", [W]),
                catch partisan_hbbft_worker:stop(W);
            _ ->
                ok
        end
    end, Workers),
    ok = global:sync(),

    %% Stop hbbft.
    % node_debug("stopping hbbft on node ~p", [Node]),
    % ok = rpc:call(?NAME(Node), application, stop, [hbbft]),

    ok.

%% @private
node_end_case() ->
    node_debug("ending case", []),

    %% Get workers and terminate them.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),
    lists:foreach(fun({_, {ok, W}}) -> catch partisan_hbbft_worker:stop(W) end, Workers),
    ok = global:sync(),

    %% Get nodes.
    [{nodes, Nodes}] = ets:lookup(prop_partisan, nodes),

    %% Stop hbbft.
    lists:foreach(fun({ShortName, _}) ->
        % node_debug("stopping hbbft on node ~p", [ShortName]),
        case rpc:call(?NAME(ShortName), application, stop, [hbbft]) of 
            ok ->
                ok;
            {badrpc, nodedown} ->
                ok;
            {error, {not_started, hbbft}} ->
                ok;
            Error ->
                node_debug("cannot terminate hbbft: ~p", [Error]),
                exit({error, shutdown_failed})
        end
    end, Nodes),

    ok.

%% @private
enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).

%% @private
random_n(N, List) ->
    lists:sublist(shuffle(List), N).

%% @private
shuffle(List) ->
    [X || {_,X} <- lists:sort([{rand:uniform(), N} || N <- List])].

%% @private
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    node_debug("wait_until trying again, retries remaining: ~p...", [Retry]),
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.

%% @private
message_queue_lens(Workers) ->
    Values = lists:map(fun({{Name1, _}, {ok, W}}) ->
        try
            Result = rpc:call(?NAME(Name1), erlang, process_info, [W, message_queue_len]),
            element(2, Result)
        catch
            _:_ ->
                0
        end
    end, Workers),
    lists:sum(Values).

%% @private
chains(Workers) ->
    sets:from_list(lists:foldl(fun({_Node, {ok, W}}, Acc) ->
                                        % node_debug("getting blocks for worker: ~p", [W]),

                                        try
                                            {ok, Blocks} = partisan_hbbft_worker:get_blocks(W),
                                            % node_debug("=> Blocks: ~p", [Blocks]),
                                            Acc ++ [Blocks]
                                        catch
                                            _:Error ->
                                                node_debug("=> received error: ~p", [Error]),
                                                Acc
                                        end
                               end, [], Workers)).

%% @private
statuses(Workers) ->
    sets:from_list(lists:foldl(fun({_Node, {ok, W}}, Acc) ->
                                        node_debug("getting status for worker: ~p", [W]),

                                        try
                                            {ok, Status} = partisan_hbbft_worker:get_status(W),
                                            #{buf := Buf, round := Round, acs := #{completed_bba_count := BBAC, successful_bba_count := BBAS, completed_rbc_count := RBCC}} = Status,
                                            node_debug("=> Status: rbc completed: ~p bba completed ~p bba successful ~p Buffer size ~p Round ~p", [RBCC, BBAC, BBAS, Buf, Round]),
                                            Acc ++ [Status]
                                        catch
                                            _:Error ->
                                                node_debug("=> received error: ~p", [Error]),
                                                Acc
                                        end
                               end, [], Workers)).

%% @private
buffers(Workers) ->
    lists:foldl(fun({_Node, {ok, W}}, Acc) ->
                        try
                            {ok, Buf} = partisan_hbbft_worker:get_buf(W),
                            Acc ++ [Buf]
                        catch
                            _:Error ->
                                node_debug("=> received error: ~p", [Error]),
                                Acc
                        end
                end, [], Workers).
