%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

%% @doc get fsm for Riak Moss.

-module(riak_moss_get_fsm).

-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Test API
-export([test_link/4]).

-endif.

-include("riak_moss.hrl").

%% API
-export([start_link/2,
         stop/1,
         continue/1,
         manifest/2,
         chunk/3,
         get_metadata/1,
         get_next_chunk/1]).

%% gen_fsm callbacks
-export([init/1,
         prepare/2,
         waiting_value/3,
         waiting_metadata_request/3,
         waiting_continue_or_stop/2,
         waiting_chunks/2,
         waiting_chunks/3,
         sending_remaining/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-record(state, {from :: pid(),
                mani_fsm_pid :: pid(),
                bucket :: term(),
                key :: term(),
                metadata_cache :: term(),
                block_buffer=[] :: [{pos_integer, term()}],
                manifest :: term(),
                manifest_uuid :: term(),
                blocks_left :: list(),
                test=false :: boolean(),
                next_block=0 :: pos_integer(),
                last_block_requested :: pos_integer(),
                total_blocks :: pos_integer(),
                free_readers :: [pid()],
                all_reader_pids :: [pid()]}).

-define(BLOCK_FETCH_CONCURRENCY, 1).

%% ===================================================================
%% Public API
%% ===================================================================

start_link(Bucket, Key) ->
    gen_fsm:start_link(?MODULE, [Bucket, Key], []).

stop(Pid) ->
    gen_fsm:send_event(Pid, stop).

continue(Pid) ->
    gen_fsm:send_event(Pid, continue).

get_metadata(Pid) ->
    gen_fsm:sync_send_event(Pid, get_metadata, 60000).

get_next_chunk(Pid) ->
    gen_fsm:sync_send_event(Pid, get_next_chunk, 60000).

manifest(Pid, ManifestValue) ->
    gen_fsm:send_event(Pid, {object, self(), ManifestValue}).

chunk(Pid, ChunkSeq, ChunkValue) ->
    gen_fsm:send_event(Pid, {chunk, self(), {ChunkSeq, ChunkValue}}).

%% ====================================================================
%% gen_fsm callbacks
%% ====================================================================

init([Bucket, Key]) ->
    %% we want to trap exits because
    %% `erlang:link` isn't atomic, and
    %% since we're starting the reader
    %% through a supervisor we can't use
    %% `spawn_link`. If the process has already
    %% died before we call link, we'll get
    %% an exit Reason of `noproc`
    process_flag(trap_exit, true),

    State = #state{bucket=Bucket,
                   key=Key},
    %% purposely have the timeout happen
    %% so that we get called in the prepare
    %% state
    {ok, prepare, State, 0};
init([test, Bucket, Key, ContentLength, BlockSize]) ->
    {ok, prepare, State1, 0} = init([Bucket, Key]),
    %% purposely have the timeout happen
    %% so that we get called in the prepare
    %% state
    {ok, ReaderPid} = riak_moss_dummy_reader:start_link([self(), ContentLength, BlockSize]),
    link(ReaderPid),
    riak_moss_reader:get_manifest(ReaderPid, Bucket, Key),
    {ok, waiting_value, State1#state{free_readers=[ReaderPid], test=true}}.

%% TODO:
%% could this func use
%% use a better name?
prepare(timeout, #state{bucket=Bucket, key=Key}=State) ->
    %% start the process that will
    %% fetch the value, be it manifest
    %% or regular object
    {ok, ManiPid} = riak_moss_manifest_fsm:start_link(Bucket, Key),
    case riak_moss_manifest_fsm:get_active_manifest(ManiPid) of
        {ok, Manifest} ->
            ReaderPids = start_block_servers(?BLOCK_FETCH_CONCURRENCY),
            NewState = State#state{manifest=Manifest,
                                   mani_fsm_pid=ManiPid,
                                   all_reader_pids=ReaderPids,
                                   free_readers=ReaderPids},
            {next_state, waiting_value, NewState};
        {error, notfound} ->
            {next_state, waiting_value, State}
    end.

waiting_value(get_metadata, From, State=#state{manifest=undefined}) ->
    gen_fsm:reply(From, notfound),
    {stop, normal, State};
waiting_value(get_metadata, From, State=#state{manifest=Mfst}) ->
    NextStateTimeout = 60000,
    Metadata = Mfst#lfs_manifest_v2.metadata,
    ContentType = Mfst#lfs_manifest_v2.content_type,
    ContentLength = Mfst#lfs_manifest_v2.content_length,
    ContentMd5 = Mfst#lfs_manifest_v2.content_md5,
    LastModified = riak_moss_wm_utils:to_rfc_1123(Mfst#lfs_manifest_v2.created),
    ReturnMeta = lists:foldl(
                   fun({K, V}, Dict) -> orddict:store(K, V, Dict) end,
                   Metadata,
                   [{"last-modified", LastModified},
                    {"content-type", ContentType},
                    {"content-md5", ContentMd5},
                    {"content-length", ContentLength}]),
    NextState = case From of
                    undefined ->
                        waiting_metadata_request;
                    _ ->
                        gen_fsm:reply(From, ReturnMeta),
                        waiting_continue_or_stop
                end,
    NewState = State#state{manifest_uuid=Mfst#lfs_manifest_v2.uuid,
                           from=undefined,
                           metadata_cache=ReturnMeta},
    {next_state, NextState, NewState, NextStateTimeout}.

waiting_metadata_request(get_metadata, _From, #state{metadata_cache=Metadata}=State) ->
    {reply, Metadata, waiting_continue_or_stop, State#state{metadata_cache=undefined}}.

waiting_continue_or_stop(timeout, State) ->
    {stop, normal, State};
waiting_continue_or_stop(stop, State) ->
    {stop, normal, State};
waiting_continue_or_stop(continue, #state{manifest=Manifest,
                                          bucket=BucketName,
                                          key=Key,
                                          next_block=NextBlock,
                                          manifest_uuid=UUID,
                                          free_readers=FreeReaders}=State) ->
    BlockSequences = riak_moss_lfs_utils:block_sequences_for_manifest(Manifest),
    case BlockSequences of
        [] ->
            %% No blocks = empty file
            {stop, normal, State};
        [_|_] ->
            BlocksLeft = sets:from_list(BlockSequences),
            TotalBlocks = sets:size(BlocksLeft),

            %% start retrieving the first set of blocks
            {LastBlockRequested, UpdFreeReaders} =
                read_blocks(BucketName, Key, UUID, FreeReaders, NextBlock, TotalBlocks+1),
            NewState = State#state{blocks_left=BlocksLeft,
                                   last_block_requested=LastBlockRequested,
                                   total_blocks=TotalBlocks,
                                   free_readers=UpdFreeReaders},
            {next_state, waiting_chunks, NewState}
    end.

waiting_chunks(get_next_chunk, From, #state{block_buffer=[], from=PreviousFrom}=State) when PreviousFrom =:= undefined ->
    %% we don't have a chunk ready
    %% yet, so we'll make note
    %% of the sender and go back
    %% into waiting for another
    %% chunk
    {next_state, waiting_chunks, State#state{from=From}};
waiting_chunks(get_next_chunk,
               _From,
               State=#state{block_buffer=[{NextBlock, Block} | RestBlockBuffer],
                            next_block=NextBlock}) ->
    {reply, {chunk, Block}, waiting_chunks, State#state{block_buffer=RestBlockBuffer,
                                                        next_block=NextBlock+1}};
waiting_chunks(get_next_chunk,
               From,
               State) ->
    {next_state, waiting_chunks, State#state{from=From}}.

waiting_chunks({chunk, _Pid, {NextBlock, BlockReturnValue}}, #state{from=From,
                                                                   blocks_left=Remaining,
                                                                   manifest_uuid=UUID,
                                                                   key=Key,
                                                                   bucket=BucketName,
                                                                   next_block=NextBlock,
                                                                   free_readers=FreeReaders,
                                                                   last_block_requested=LastBlockRequested,
                                                                   total_blocks=TotalBlocks,
                                                                   block_buffer=BlockBuffer}=State) ->

    {ok, BlockValue} = BlockReturnValue,
    NewRemaining = sets:del_element(NextBlock, Remaining),
    BlocksLeft = sets:size(NewRemaining),
    case From of
        undefined ->
            UpdBlockBuffer =
                lists:sort(fun block_sorter/2,
                           [{NextBlock, BlockValue} | BlockBuffer]),
            NewState0 = State#state{blocks_left=NewRemaining,
                                   block_buffer=UpdBlockBuffer,
                                   from=undefined},
            case BlocksLeft of
                0 ->
                    NewState=NewState0,
                    NextStateName = sending_remaining;
                _ ->
                    {ReadRequests, UpdFreeReaders} =
                        read_blocks(BucketName, Key, UUID, FreeReaders, NextBlock, TotalBlocks),
                    NewState = NewState0#state{last_block_requested=LastBlockRequested+ReadRequests,
                                               free_readers=UpdFreeReaders},
                    NextStateName = waiting_chunks
            end,
            {next_state, NextStateName, NewState};
        _ ->
            NewState0 = State#state{blocks_left=NewRemaining,
                                   from=undefined},
            case BlocksLeft of
                0 ->
                    gen_fsm:reply(From, {done, BlockValue}),
                    NewState=NewState0,
                    {stop, normal, NewState};
                _ ->
                    gen_fsm:reply(From, {chunk, BlockValue}),
                    {ReadRequests, UpdFreeReaders} =
                        read_blocks(BucketName, Key, UUID, FreeReaders, LastBlockRequested+1, TotalBlocks),
                    NewState = NewState0#state{last_block_requested=LastBlockRequested+ReadRequests,
                                               free_readers=UpdFreeReaders},
                    {next_state, waiting_chunks, NewState}
            end
    end;

waiting_chunks({chunk, _Pid, {BlockSeq, BlockReturnValue}}, #state{blocks_left=Remaining,
                                                                   manifest_uuid=UUID,
                                                                   key=Key,
                                                                   bucket=BucketName,
                                                                   free_readers=FreeReaders,
                                                                   last_block_requested=LastBlockRequested,
                                                                   total_blocks=TotalBlocks,
                                                                   block_buffer=BlockBuffer}=State) ->
    %% we don't deal with missing chunks
    %% at all here, so this pattern
    %% match will fail
    {ok, BlockValue} = BlockReturnValue,
    NewRemaining = sets:del_element(BlockSeq, Remaining),
    BlocksLeft = sets:size(NewRemaining),
    UpdBlockBuffer =
        lists:sort(fun block_sorter/2,
                   [{BlockSeq, BlockValue} | BlockBuffer]),
    NewState0 = State#state{blocks_left=NewRemaining,
                            block_buffer=UpdBlockBuffer,
                            from=undefined},
    case BlocksLeft of
        0 ->
            NewState = NewState0,
            NextStateName = sending_remaining;
        _ ->
            {ReadRequests, UpdFreeReaders} =
                read_blocks(BucketName, Key, UUID, FreeReaders, LastBlockRequested+1, TotalBlocks),
            NewState = NewState0#state{last_block_requested=LastBlockRequested+ReadRequests,
                                       free_readers=UpdFreeReaders},
            NextStateName = waiting_chunks
    end,
    {next_state, NextStateName, NewState}.

sending_remaining(get_next_chunk, _From, #state{block_buffer=[{_, Block} | RestBlockBuffer]}=State) ->
    NewState = State#state{block_buffer=RestBlockBuffer},
    case RestBlockBuffer of
        [] ->
            {stop, normal, {done, Block}, NewState};
        _ ->
            {reply, {chunk, Block}, sending_remaining, NewState}
    end.

%% @private
handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private
handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_info(request_timeout, StateName, StateData) ->
    ?MODULE:StateName(request_timeout, StateData);
%% TODO:
%% we don't want to just
%% stop whenever a reader is
%% killed once we have some concurrency
%% in our readers. But since we just
%% have one reader process now, if it dies,
%% we have no reason to stick around
%%
%% @TODO Also handle reader pid death
handle_info({'EXIT', ManiPid, _Reason}, _StateName, StateData=#state{mani_fsm_pid=ManiPid}) ->
    {stop, normal, StateData};
%% @private
handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private
terminate(_Reason, _StateName, #state{test=false}) ->
    ok;
terminate(_Reason, _StateName, #state{test=true,
                                      free_readers=[ReaderPid | _]}) ->
    exit(ReaderPid, normal).

%% @private
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

%% ===================================================================
%% Internal functions
%% ===================================================================

-spec block_sorter({pos_integer(), term()}, {pos_integer(), term()}) -> boolean().
block_sorter({A, _}, {B, _}) ->
    A < B.

-spec read_blocks(binary(), binary(), binary(), [pid()], pos_integer(), pos_integer()) ->
                         {pos_integer(), [pid()]}.
read_blocks(Bucket, Key, UUID, FreeReaders, NextBlock, TotalBlocks) ->
    read_blocks(Bucket,
                binary_to_list(Key),
                UUID,
                FreeReaders,
                NextBlock,
                TotalBlocks,
                0).

-spec read_blocks(binary(),
                  binary(),
                  binary(),
                  [pid()],
                  pos_integer(),
                  pos_integer(),
                  non_neg_integer()) ->
                         {pos_integer(), [pid()]}.
read_blocks(_Bucket, _Key, _UUID, [], _, _, ReadsRequested) ->
    {ReadsRequested, []};
read_blocks(_Bucket, _Key, _UUID, FreeReaders, _TotalBlocks, _TotalBlocks, ReadsRequested) ->
    {ReadsRequested, FreeReaders};
read_blocks(Bucket, Key, UUID, [ReaderPid | RestFreeReaders], NextBlock, _TotalBlocks, ReadsRequested) ->
    riak_moss_block_server:get_block(ReaderPid, Bucket, Key, UUID, NextBlock),
    read_blocks(Bucket, Key, UUID, RestFreeReaders, NextBlock+1, _TotalBlocks, ReadsRequested+1).

%% @private
%% @doc Start a number of riak_moss_block_server processes
%% and return a list of their pids.
%% @TODO Can probably share this among the fsms.
-spec server_result(pos_integer(), [pid()]) -> [pid()].
server_result(_, Acc) ->
    case riak_moss_block_server:start_link() of
        {ok, Pid} ->
            [Pid | Acc];
        {error, Reason} ->
            lager:warning("Failed to start block server instance. Reason: ~p", [Reason]),
            Acc
    end.

-spec start_block_servers(pos_integer()) -> [pid()].
start_block_servers(NumServers) ->
    lists:foldl(fun server_result/2, [], lists:seq(1, NumServers)).

%% ===================================================================
%% Test API
%% ===================================================================

-ifdef(TEST).

test_link(Bucket, Key, ContentLength, BlockSize) ->
    gen_fsm:start_link(?MODULE, [test, Bucket, Key, ContentLength, BlockSize], []).

-endif.
