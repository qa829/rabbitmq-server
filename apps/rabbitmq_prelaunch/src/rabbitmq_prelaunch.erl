-module(rabbitmq_prelaunch).

-export([run/0,
         shutdown_func/1]).

-define(PT_KEY, {?MODULE, shutdown_func_state}).

run() ->
    try
        run(node())
    catch
        throw:{error, _} = Exception ->
            Exception;
        Class:Reason:Stacktrace ->
            log_exception(Class, Reason, Stacktrace, false),
            {error, {exception, Class, Reason, Stacktrace}}
    end.

run(nonode@nohost) ->
    %% Configure dbg if requested.
    rabbitmq_prelaunch_logging:enable_quick_dbg(rabbit_env:dbg_config()),

    %% Get informations to setup logging.
    Context0 = rabbit_env:get_context_before_logging_init(),

    %% Setup logging for the prelaunch phase.
    ok = rabbitmq_prelaunch_logging:enable_prelaunch_logging(Context0, true),
    rabbit_env:log_process_env(),

    %% Load rabbitmq-env.conf, redo logging setup and continue.
    Context1 = rabbit_env:get_context_after_logging_init(Context0),
    ok = rabbitmq_prelaunch_logging:enable_prelaunch_logging(Context1, true),
    rabbit_env:log_process_env(),

    %% Complete context now that we have the final environment loaded.
    Context2 = rabbit_env:get_context_after_reloading_env(Context1),
    store_context(Context2),

    Context = Context2#{initial_pass => true},
    rabbit_env:log_context(Context),

    rabbit_env:context_to_code_path(Context),
    rabbit_env:context_to_app_env_vars(Context),

    %% 1. Write PID file
    ok = setup_shutdown_func(Context),
    _ = write_pid_file(Context),

    %% If one step fails, we remove the PID file and return the error.
    try
        stop_mnesia(),

        %% 2. Feature flags registry
        ok = rabbitmq_prelaunch_feature_flags:setup(Context),

        %% 3. Configuration check + loading
        ok = rabbitmq_prelaunch_conf:setup(Context),

        %% 4. Logging
        ok = rabbitmq_prelaunch_logging:setup(Context),

        %% 5. HiPE compilation
        ok = rabbitmq_prelaunch_hipe:setup(Context),

        %% 6. Erlang distribution check + start
        ok = rabbitmq_prelaunch_dist:setup(Context),

        %% 7. Clustering
        ok = rabbitmq_prelaunch_cluster:setup(Context),

        %% We return `ignore` to let the supervisor know that there is
        %% no child process running permanently.
        ignore
    catch
        throw:{error, _} = Exception ->
            remove_pid_file(Context),
            Exception;
        Class:Reason:Stacktrace ->
            log_exception(Class, Reason, Stacktrace, true),
            remove_pid_file(Context),
            {error, {exception, Class, Reason, Stacktrace}}
    end;
run(_) ->
    rabbit_log_prelaunch:notice("Prelaunch executed again"),
    Context0 = get_context(),

    Context = Context0#{initial_pass => false},
    rabbit_env:log_context(Context),

    try
        stop_mnesia(),

        %% 1. Feature flags registry
        ok = rabbitmq_prelaunch_feature_flags:setup(Context),

        %% 2. Logging
        ok = rabbitmq_prelaunch_logging:setup(Context),

        %% 3. Clustering
        ok = rabbitmq_prelaunch_cluster:setup(Context),

        %% We return `ignore` to let the supervisor know that there is
        %% no child process running permanently.
        ignore
    catch
        throw:{error, _} = Exception ->
            Exception;
        Class:Reason:Stacktrace ->
            log_exception(Class, Reason, Stacktrace, true),
            {error, {exception, Class, Reason, Stacktrace}}
    end.

store_context(Context) ->
    rabbitmq_prelaunch_helpers:set_env(context, Context).

get_context() ->
    case rabbitmq_prelaunch_helpers:get_env(context) of
        {ok, Context} -> Context;
        undefined     -> undefined
    end.

stop_mnesia() ->
    %% Stop Mnesia now. It is started because `rabbit` depends on it
    %% (and this `rabbitmq_prelaunch` too). But because distribution
    %% is not configured yet at the time it is started, it is
    %% non-functionnal. We can stop it now, setup distribution and
    %% `rabbit` will take care of starting it again.
    %%
    %% Having Mnesia started also messes with cluster consistency
    %% checks.
    rabbit_log_prelaunch:debug("Ensuring Mnesia is stopped"),
    mnesia:stop().

setup_shutdown_func(Context) ->
    ThisMod = ?MODULE,
    ThisFunc = shutdown_func,
    ChainedShutdownFunc = application:get_env(kernel, shutdown_func),
    case ChainedShutdownFunc of
        {ok, {ChainedMod, ChainedFunc}} ->
            rabbit_log_prelaunch:debug(
              "Setting up kernel shutdown function: ~s:~s/1 "
              "(chained with ~s:~s/1)",
              [ThisMod, ThisFunc, ChainedMod, ChainedFunc]);
        _ ->
            rabbit_log_prelaunch:debug(
              "Setting up kernel shutdown function: ~s:~s/1",
              [ThisMod, ThisFunc])
    end,
    ok = persistent_term:put(?PT_KEY, {Context, ChainedShutdownFunc}),
    ok = application:set_env(
           kernel, shutdown_func, {?MODULE, shutdown_func},
           [{persistent, true}]).

shutdown_func(Reason) ->
    {Context, ChainedShutdownFunc} = persistent_term:get(?PT_KEY),
    remove_pid_file(Context),
    case ChainedShutdownFunc of
        {ok, {ChainedMod, ChainedFunc}} -> ChainedMod:ChainedFunc(Reason);
        _                               -> ok
    end.

write_pid_file(#{pid_file := PidFile}) ->
    rabbit_log_prelaunch:debug("Writing PID file: ~s", [PidFile]),
    Parent = filename:dirname(PidFile),
    case rabbitmq_prelaunch_helpers:mkdir_p(Parent) of
        ok ->
            OSPid = os:getpid(),
            case file:write_file(PidFile, OSPid) of
                ok ->
                    ok;
                {error, Reason} = Error ->
                    rabbit_log_prelaunch:warning(
                      "Failed to write PID file \"~s\": ~s",
                      [PidFile, file:format_error(Reason)]),
                    Error
            end;
        {error, Reason} = Error ->
            rabbit_log_prelaunch:warning(
              "Failed to create PID file \"~s\" directory: ~s",
              [PidFile, file:format_error(Reason)]),
            Error
    end;
write_pid_file(_) ->
    ok.

remove_pid_file(#{keep_pid_file_on_exit := true}) ->
    ok;
remove_pid_file(#{pid_file := PidFile}) ->
    _ = file:delete(PidFile);
remove_pid_file(_) ->
    ok.

log_exception(Class, Reason, Stacktrace, true) ->
    rabbit_log_prelaunch:error("Exception during prelaunch phase:"),
    [rabbit_log_prelaunch:error("~s", [Line])
     || Line <- string:split(
                  lager:pr_stacktrace(Stacktrace, {Class, Reason}),
                  [$\n],
                  all)];
log_exception(Class, Reason, Stacktrace, false) ->
    io:format(standard_error, "Exception during prelaunch phase:~n", []),
    [io:format(standard_error, "~s~n", [Line])
     || Line <- string:split(
                  lager:pr_stacktrace(Stacktrace, {Class, Reason}),
                  [$\n],
                  all)].
