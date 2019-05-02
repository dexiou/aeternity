-module(aesc_session_noise).
-behaviour(gen_server).

-include("aesc_codec.hrl").

-export([connect/3
       , accept/2
       , close/1]).

-export([channel_open/2
       , channel_accept/2
       , funding_created/2
       , funding_signed/2
       , funding_locked/2
       , deposit_created/2
       , deposit_signed/2
       , deposit_locked/2
       , channel_reestablish/2
       , channel_reestablish_ack/2
       , update/2
       , update_ack/2
       , update_error/2
       , dep_created/2
       , dep_signed/2
       , dep_locked/2
       , dep_error/2
       , wdraw_created/2
       , wdraw_signed/2
       , wdraw_locked/2
       , wdraw_error/2
       , error/2
       , inband_msg/2
       , leave/2
       , leave_ack/2
       , shutdown/2
       , shutdown_ack/2]).

-export([init/1
       , handle_call/3
       , handle_cast/2
       , handle_info/2
       , terminate/2
       , code_change/3]).

-record(st, {parent :: pid()
           , parent_mon_ref :: reference()
           , econn }).

channel_open       (Session, Msg) -> cast(Session, {msg, ?CH_OPEN      , Msg}).
channel_accept     (Session, Msg) -> cast(Session, {msg, ?CH_ACCEPT    , Msg}).
funding_created    (Session, Msg) -> cast(Session, {msg, ?FND_CREATED  , Msg}).
funding_signed     (Session, Msg) -> cast(Session, {msg, ?FND_SIGNED   , Msg}).
funding_locked     (Session, Msg) -> cast(Session, {msg, ?FND_LOCKED   , Msg}).
deposit_created    (Session, Msg) -> cast(Session, {msg, ?DEP_CREATED  , Msg}).
deposit_signed     (Session, Msg) -> cast(Session, {msg, ?DEP_SIGNED   , Msg}).
deposit_locked     (Session, Msg) -> cast(Session, {msg, ?DEP_LOCKED   , Msg}).
channel_reestablish(Session, Msg) -> cast(Session, {msg, ?CH_REESTABL  , Msg}).
channel_reestablish_ack(Sn , Msg) -> cast(Sn     , {msg, ?CH_REEST_ACK , Msg}).
update             (Session, Msg) -> cast(Session, {msg, ?UPDATE       , Msg}).
update_ack         (Session, Msg) -> cast(Session, {msg, ?UPDATE_ACK   , Msg}).
update_error       (Session, Msg) -> cast(Session, {msg, ?UPDATE_ERR   , Msg}).
dep_created        (Session, Msg) -> cast(Session, {msg, ?DEP_CREATED  , Msg}).
dep_signed         (Session, Msg) -> cast(Session, {msg, ?DEP_SIGNED   , Msg}).
dep_locked         (Session, Msg) -> cast(Session, {msg, ?DEP_LOCKED   , Msg}).
dep_error          (Session, Msg) -> cast(Session, {msg, ?DEP_ERR      , Msg}).
wdraw_created      (Session, Msg) -> cast(Session, {msg, ?WDRAW_CREATED, Msg}).
wdraw_signed       (Session, Msg) -> cast(Session, {msg, ?WDRAW_SIGNED , Msg}).
wdraw_locked       (Session, Msg) -> cast(Session, {msg, ?WDRAW_LOCKED , Msg}).
wdraw_error        (Session, Msg) -> cast(Session, {msg, ?WDRAW_ERR    , Msg}).
error              (Session, Msg) -> cast(Session, {msg, ?ERROR        , Msg}).
inband_msg         (Session, Msg) -> cast(Session, {msg, ?INBAND_MSG   , Msg}).
leave              (Session, Msg) -> cast(Session, {msg, ?LEAVE        , Msg}).
leave_ack          (Session, Msg) -> cast(Session, {msg, ?LEAVE_ACK    , Msg}).
shutdown           (Session, Msg) -> cast(Session, {msg, ?SHUTDOWN     , Msg}).
shutdown_ack       (Session, Msg) -> cast(Session, {msg, ?SHUTDOWN_ACK , Msg}).

close(Session) ->
    try call(Session, close)
    catch
        error:_ -> ok
    end.

-define(GEN_SERVER_OPTS, []).

%% Connection establishment

connect(Host, Port, Opts) ->
    {Timeout, Retries} = get_reconnect_params(),
    gen_server:start_link(
      ?MODULE, {self(), {connect, Retries, Host, Port, Opts, Timeout}}, ?GEN_SERVER_OPTS).

accept(Port, Opts) ->
    gen_server:start_link(
      ?MODULE, {self(), {accept, Port, Opts}}, ?GEN_SERVER_OPTS).

init({Parent, Op}) ->
    %% trap exits to avoid ugly crash reports. We rely on the monitor to
    %% ensure that we close when the fsm dies
    %%
    %% TODO: For some reason, trapping exits causes
    %% aehttp_integration_SUITE:sc_ws_open/1 to fail. Investigate why.
    %% process_flag(trap_exit, true),
    proc_lib:init_ack(Parent, {ok, self()}),
    ParentMonRef = monitor(process, Parent),
    St = #st{parent = Parent,
             parent_mon_ref = ParentMonRef},
    self() ! Op,
    gen_server:enter_loop(?MODULE, ?GEN_SERVER_OPTS, St).

get_reconnect_params() ->
    %% {ConnectTimeout, Retries}
    {10000, 30}.


handle_call(_, _From, #st{econn = undefined} = St) ->
    Err = not_initialized_yet_call,
    {stop, Err, {error, Err}, St};
handle_call(close, _From, #st{econn = EConn} = St) ->
    close_econn(EConn),
    {stop, normal, ok, St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_, #st{econn = undefined} = St) ->
    {stop, not_initialized_yet_cast, St}; 
handle_cast(Msg, St) ->
    try handle_cast_(Msg, St)
    catch
        error:Reason ->
            Trace = erlang:get_stacktrace(),
            lager:error("CAUGHT error:~p trace: ~p", [Reason, Trace]),
            erlang:error(Reason, Trace)
    end.

handle_cast_({msg, M, Info}, #st{econn = EConn} = St) ->
    enoise:send(EConn, aesc_codec:enc(M, Info)),
    {noreply, St};
handle_cast_(_Msg, St) ->
    {noreply, St}.

handle_info({accept, Port, Opts}, #st{econn = undefined} = St) ->
    TcpOpts = tcp_opts(listen, Opts),
    lager:debug("listen: TcpOpts = ~p", [TcpOpts]),
    {ok, LSock} = gen_tcp:listen(Port, TcpOpts),
    {ok, TcpSock} = gen_tcp:accept(LSock),
    %% TODO: extract/check something from FinalState?
    EnoiseOpts = enoise_opts(accept, Opts),
    lager:debug("EnoiseOpts (accept) = ~p", [EnoiseOpts]),
    {ok, EConn, _FinalSt} = enoise:accept(TcpSock, EnoiseOpts),
    St1 = St#st{econn = EConn},
    inform_fsm_connection_success(St1),
    {noreply, St1};
handle_info({connect, Retries, _Host, _Port, _Opts, _Timeout}, #st{econn = undefined} = St)
    when Retries =:= 0 ->
    inform_fsm_connection_failed(St),
    {stop, not_initialized_yet, St}; 
handle_info({connect, Retries, Host, Port, Opts, Timeout}, #st{econn = undefined} = St) ->
    TcpOpts = tcp_opts(connect, Opts),
    lager:debug("connect: TcpOpts = ~p", [TcpOpts]),
    case gen_tcp:connect(Host, Port, TcpOpts, Timeout) of
        {ok, TcpSock} ->
            %% TODO: extract/check something from FinalState?
            EnoiseOpts = enoise_opts(connect, Opts),
            lager:debug("EnoiseOpts (connect) = ~p", [EnoiseOpts]),
            {ok, EConn, _FinalSt} = enoise:connect(TcpSock, EnoiseOpts),
            St1 = St#st{econn = EConn},
            inform_fsm_connection_success(St1),
            {noreply, St1};
        {error, _} ->
            timer:send_after(1000, {connect, Retries - 1, Host, Port, Opts,
                                    Timeout}),
            {noreply, St}
    end;
handle_info(_, #st{econn = undefined} = St) ->
    {stop, not_initialized_yet_info, St}; 
%% FSM had died
handle_info({'DOWN', Ref, process, Pid, _Reason},
            #st{parent_mon_ref=Ref, parent=Pid, econn=EConn}=St) ->
    lager:debug("Got DOWN from parent (~p)", [Pid]),
    close_econn(EConn),
    {stop, normal, St};
handle_info(Msg, St) ->
    try handle_info_(Msg, St)
    catch
        error:Reason ->
            Trace = erlang:get_stacktrace(),
            lager:error("CAUGHT error:~p trace: ~p", [Reason, Trace]),
            erlang:error(Reason, Trace)
    end.

handle_info_({noise, EConn, Data}, #st{econn = EConn} = St) ->
    {_Type, _Info} = Msg = aesc_codec:dec(Data),
    tell_fsm(Msg, St),
    enoise:set_active(EConn, once),
    {noreply, St};
handle_info_({tcp_closed, _Port}, #st{parent = Pid} = St) ->
    aesc_fsm:connection_died(Pid),
    {stop, normal, St};
handle_info_(_Msg, St) ->
    lager:debug("Unknown handle_info_(~p)", [_Msg]),
    {noreply, St}.

terminate(_Reason, #st{econn = EConn}) ->
    close_econn(EConn),
    ok.

code_change(_FromVsn, St, _Extra) ->
    {ok, St}.

close_econn(undefined) ->
    ok;
close_econn(EConn) ->
    try enoise:close(EConn)
    catch _:_ -> ok
    end.


cast(P, Msg) ->
    lager:debug("to noise session ~p: ~p", [P, Msg]),
    gen_server:cast(P, Msg).

call(P, Msg) ->
    lager:debug("Call to noise session ~p: ~p", [P, Msg]),
    gen_server:call(P, Msg).

tell_fsm({_, _} = Msg, #st{parent = Parent}) ->
    aesc_fsm:message(Parent, Msg).

inform_fsm_connection_success(#st{parent = Parent}) ->
    Parent ! {self(), established}.

inform_fsm_connection_failed(#st{parent = Parent}) ->
    Parent ! {self(), connection_timeout}.


tcp_opts(_Op, Opts) ->
    case lists:keyfind(tcp, 1, Opts) of
        false -> tcp_defaults();
        {_, TcpOpts} ->
            [Opt || Opt <- tcp_defaults(),
                    not tcp_opt_member(Opt, TcpOpts)]
                ++ TcpOpts
    end.


noise_defaults() ->
    [{noise, <<"Noise_XK_25519_ChaChaPoly_BLAKE2b">>}].

tcp_defaults() ->
    [{active, true},
     {reuseaddr, true},
     {mode, binary}].

tcp_opt_member({mode,M}, L) ->
    %% handle supported short forms 'binary' and 'list'
    lists:keymember(mode, 1, L) orelse lists:member(M, L);
tcp_opt_member({K,_}, L) ->
    lists:keymember(K, 1, L).


enoise_opts(_Op, Opts0) ->
    Opts = lists:keydelete(tcp, 1, Opts0),
    [Opt || {K,_} = Opt <- noise_defaults(),
            not lists:keymember(K, 1, Opts)] ++ Opts.
