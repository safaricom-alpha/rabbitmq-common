-module(rabbit_env).

-include_lib("kernel/include/file.hrl").

-export([get_context_before_logging_init/1,
         get_context_after_logging_init/1,
         is_dev_environment/0,
         log_context/1,
         context_to_app_env_vars/1,
         context_to_app_env_vars_no_logging/1,
         context_to_code_path/1]).

-define(RPC_TIMEOUT, 10000).

get_context_before_logging_init(TakeFromRemoteNode) ->
    %% The order of steps below is important because some of them
    %% depends on previous steps.
    Steps = [
             fun node_name_and_type/1,
             fun maybe_setup_dist_for_remote_query/1,
             fun log_levels/1,
             fun config_files/1,
             fun log_files/1,
             fun mnesia_dir/1,
             fun quorum_dir/1,
             fun pid_file/1,
             fun feature_flags_file/1,
             fun plugins_dirs/1,
             fun maybe_stop_dist_for_remote_query/1
            ],

    run_context_steps(context_base(TakeFromRemoteNode), Steps).

get_context_after_logging_init(EarlyContext) ->
    %% The order of steps below is important because some of them
    %% depends on previous steps.
    Steps = [
             fun tcp_configuration/1
            ],

    run_context_steps(EarlyContext, Steps).

context_base(TakeFromRemoteNode)
  when TakeFromRemoteNode =:= false orelse is_atom(TakeFromRemoteNode) ->
    OSType = os:type(),
    #{os_type => OSType,
      dev_environment => is_dev_environment(),
      from_remote_node => TakeFromRemoteNode}.

run_context_steps(Context, Steps) ->
    lists:foldl(
      fun(Step, Context1) -> Step(Context1) end,
      Context,
      Steps).

log_context(Context) ->
    rabbit_log_prelaunch:debug("Context (based on environment variables):"),
    lists:foreach(
      fun(Key) ->
              Value = maps:get(Key, Context),
              rabbit_log_prelaunch:debug("  - ~s: ~p", [Key, Value])
      end,
      lists:sort(maps:keys(Context))).

context_to_app_env_vars(Context) ->
    rabbit_log_prelaunch:debug(
      "Setting default application environment variables:"),
    Fun = fun({App, Param, Value}) ->
                  rabbit_log_prelaunch:debug(
                    "  - ~s:~s = ~p", [App, Param, Value]),
                  ok = application:set_env(
                         App, Param, Value, [{persistent, true}])
          end,
    context_to_app_env_vars1(Context, Fun).

context_to_app_env_vars_no_logging(Context) ->
    Fun = fun({App, Param, Value}) ->
                  ok = application:set_env(
                         App, Param, Value, [{persistent, true}])
          end,
    context_to_app_env_vars1(Context, Fun).

context_to_app_env_vars1(
  #{erlang_dist_tcp_port := DistTcpPort,
    mnesia_dir := MnesiaDir,
    feature_flags_file := FFFile,
    quorum_queue_dir := QuorumQueueDir,
    plugins_path := PluginsPath,
    plugins_expand_dir := PluginsExpandDir,
    enabled_plugins_file := EnabledPluginsFile} = Context,
  Fun) ->
    lists:foreach(
      Fun,
      %% Those are all the application environment variables which
      %% were historically set on the erl(1) command line in
      %% rabbitmq-server(8).
      [{kernel, inet_dist_listen_min, DistTcpPort},
       {kernel, inet_dist_listen_max, DistTcpPort},
       {kernel, inet_default_connect_options, [{nodelay, true}]},
       {sasl, errlog_type, error},
       {os_mon, start_cpu_sup, false},
       {os_mon, start_disksup, false},
       {os_mon, start_memsup, false},
       {mnesia, dir, MnesiaDir},
       {ra, data_dir, QuorumQueueDir},
       {rabbit, feature_flags_file, FFFile},
       {rabbit, plugins_dir, PluginsPath},
       {rabbit, plugins_expand_dir, PluginsExpandDir},
       {rabbit, enabled_plugins_file, EnabledPluginsFile}]),

    case Context of
        #{amqp_ipaddr_and_tcp_port := {IpAddr, TcpPort}}
          when IpAddr /= undefined andalso TcpPort /= undefined ->
            Fun({rabbit, tcp_listeners, [{IpAddr, TcpPort}]});
        _ ->
            ok
    end,
    ok.

context_to_code_path(#{dev_environment := false,
                       plugins_path := PluginsPath}) ->
    Dirs = get_user_lib_dirs(PluginsPath),
    add_paths_to_code_path(Dirs);
context_to_code_path(#{dev_environment := true,
                       plugins_path := PluginsPath}) ->
    Dirs = get_user_lib_dirs(PluginsPath),
    add_paths_to_code_path(Dirs).

add_paths_to_code_path(Dirs) ->
    Path = code:get_path(),
    add_paths_to_code_path1(Path, lists:reverse(Dirs)).

add_paths_to_code_path1(Path, [Dir | Rest]) ->
    case lists:member(Dir, Path) of
        true  -> ok;
        false -> code:add_patha(Dir)
    end,
    add_paths_to_code_path1(Path, Rest);
add_paths_to_code_path1(_, []) ->
    ok.

%% -------------------------------------------------------------------
%% Code copied from `kernel/src/code_server.erl`.
%%
%% The goal is to mimic the behavior of the `$ERL_LIBS` environment
%% variable.

get_user_lib_dirs(Path) ->
    Sep = case os:type() of
              {win32, _} -> ";";
              _          -> ":"
          end,
    SplitPath = string:lexemes(Path, Sep),
    get_user_lib_dirs_1(SplitPath).

get_user_lib_dirs_1([Dir|DirList]) ->
    case erl_prim_loader:list_dir(Dir) of
        {ok, Dirs} ->
            Paths = make_path(Dir, Dirs),
            %% Only add paths trailing with ./ebin.
            [P || P <- Paths, filename:basename(P) =:= "ebin"] ++
                get_user_lib_dirs_1(DirList);
        error ->
            get_user_lib_dirs_1(DirList)
    end;
get_user_lib_dirs_1([]) -> [].

%%
%% Create the initial path.
%%
make_path(BundleDir, Bundles0) ->
    Bundles = choose_bundles(Bundles0),
    make_path(BundleDir, Bundles, []).

choose_bundles(Bundles) ->
    ArchiveExt = archive_extension(),
    Bs = lists:sort([create_bundle(B, ArchiveExt) || B <- Bundles]),
    [FullName || {_Name,_NumVsn,FullName} <-
                     choose(lists:reverse(Bs), [], ArchiveExt)].

create_bundle(FullName, ArchiveExt) ->
    BaseName = filename:basename(FullName, ArchiveExt),
    case split_base(BaseName) of
        {Name, VsnStr} ->
            case vsn_to_num(VsnStr) of
                {ok, VsnNum} ->
                    {Name,VsnNum,FullName};
                false ->
                    {FullName,[0],FullName}
            end;
        _ ->
            {FullName,[0],FullName}
    end.

%% Convert "X.Y.Z. ..." to [K, L, M| ...]
vsn_to_num(Vsn) ->
    case is_vsn(Vsn) of
        true ->
            {ok, [list_to_integer(S) || S <- string:lexemes(Vsn, ".")]};
        _  ->
            false
    end.

is_vsn(Str) when is_list(Str) ->
    Vsns = string:lexemes(Str, "."),
    lists:all(fun is_numstr/1, Vsns).

is_numstr(Cs) ->
    lists:all(fun (C) when $0 =< C, C =< $9 -> true;
                  (_)                       -> false
              end, Cs).

choose([{Name,NumVsn,NewFullName}=New|Bs], Acc, ArchiveExt) ->
    case lists:keyfind(Name, 1, Acc) of
        {_, NV, OldFullName} when NV =:= NumVsn ->
            case filename:extension(OldFullName) =:= ArchiveExt of
                false ->
                    choose(Bs,Acc, ArchiveExt);
                true ->
                    Acc2 = lists:keystore(Name, 1, Acc, New),
                    choose(Bs,Acc2, ArchiveExt)
            end;
        {_, _, _} ->
            choose(Bs,Acc, ArchiveExt);
        false ->
            choose(Bs,[{Name,NumVsn,NewFullName}|Acc], ArchiveExt)
    end;
choose([],Acc, _ArchiveExt) ->
    Acc.

make_path(_, [], Res) ->
    Res;
make_path(BundleDir, [Bundle|Tail], Res) ->
    Dir = filename:append(BundleDir, Bundle),
    Ebin = filename:append(Dir, "ebin"),
    %% First try with /ebin
    case is_dir(Ebin) of
        true ->
            make_path(BundleDir, Tail, [Ebin|Res]);
        false ->
            %% Second try with archive
            Ext = archive_extension(),
            Base = filename:basename(Bundle, Ext),
            Ebin2 = filename:join([BundleDir, Base ++ Ext, Base, "ebin"]),
            Ebins =
                case split_base(Base) of
                    {AppName,_} ->
                        Ebin3 = filename:join([BundleDir, Base ++ Ext,
                                               AppName, "ebin"]),
                        [Ebin3, Ebin2, Dir];
                    _ ->
                        [Ebin2, Dir]
                end,
            case try_ebin_dirs(Ebins) of
                {ok,FoundEbin} ->
                    make_path(BundleDir, Tail, [FoundEbin|Res]);
                error ->
                    make_path(BundleDir, Tail, Res)
            end
    end.

try_ebin_dirs([Ebin|Ebins]) ->
    case is_dir(Ebin) of
        true -> {ok,Ebin};
        false -> try_ebin_dirs(Ebins)
    end;
try_ebin_dirs([]) ->
    error.

split_base(BaseName) ->
    case string:lexemes(BaseName, "-") of
        [_, _|_] = Toks ->
            Vsn = lists:last(Toks),
            AllButLast = lists:droplast(Toks),
            {string:join(AllButLast, "-"),Vsn};
        [_|_] ->
            BaseName
    end.

is_dir(Path) ->
    case erl_prim_loader:read_file_info(Path) of
        {ok,#file_info{type=directory}} -> true;
        _ -> false
    end.

archive_extension() ->
    init:archive_extension().

%% -------------------------------------------------------------------
%%
%% RABBITMQ_NODENAME
%%   Erlang node name.
%%   Default: rabbit@<hostname>
%%
%% RABBITMQ_USE_LONGNAME
%%   Main configuration file.
%%   Extension is optional. `.config` for the old rlang-term-based
%%   format, `.conf` for the new Cuttlefish-based format.
%%   Default: (Unix) ${SYS_PREFIX}/etc/rabbitmq/rabbitmq
%%         (Windows) ${RABBITMQ_BASE}\rabbitmq

node_name_and_type(Context) ->
    NameType = get_node_name_type(),
    Nodename = get_node_name(NameType),
    Context#{nodename => Nodename,
             split_nodename => rabbit_nodes_common:parts(Nodename),
             nodename_type => NameType}.

get_node_name_type() ->
    UseLongname = get_prefixed_env_var("RABBITMQ_USE_LONGNAME"),
    case UseLongname of
        "true" -> longnames;
        _      -> shortnames
    end.

get_node_name(NameType) ->
    LongHostname = net_adm:localhost(),
    ShortHostname = re:replace(LongHostname, "\\..*$", "", [{return, list}]),
    Nodename = case os:getenv("RABBITMQ_NODENAME") of
                   false when NameType =:= shortnames ->
                       rabbit_nodes_common:make({"rabbit", ShortHostname});
                   false when NameType =:= longnames ->
                       rabbit_nodes_common:make({"rabbit", LongHostname});
                   Value ->
                       case string:find(Value, "@") of
                           nomatch when NameType =:= shortnames ->
                               rabbit_nodes_common:make(
                                 {Value, ShortHostname});
                           nomatch when NameType =:= longnames ->
                               rabbit_nodes_common:make(
                                 {Value, LongHostname});
                           _ ->
                               rabbit_nodes_common:make(
                                 Value)
                       end
               end,
    os:putenv("RABBITMQ_NODENAME", atom_to_list(Nodename)),
    Nodename.

%% -------------------------------------------------------------------
%%
%% RABBITMQ_CONFIG_FILE
%%   Main configuration file.
%%   Extension is optional. `.config` for the old rlang-term-based
%%   format, `.conf` for the new Cuttlefish-based format.
%%   Default: (Unix) ${SYS_PREFIX}/etc/rabbitmq/rabbitmq
%%         (Windows) ${RABBITMQ_BASE}\rabbitmq
%%
%% RABBITMQ_ADVANCED_CONFIG_FILE
%%   Advanced configuration file.
%%   Erlang-term-based format with a `.config` extension.
%%   Default: (Unix) ${SYS_PREFIX}/etc/rabbitmq/advanced.config
%%         (Windows) ${RABBITMQ_BASE}\advanced.config
%%
%% Now unused:
%%
%% RABBITMQ_SCHEMA_DIR [UNUSED]
%%   Directory where all detected Cuttlefish schemas are written.
%%   Replaced by the use of Cuttlefish as a libray.
%%
%% RABBITMQ_GENERATED_CONFIG_DIR [UNUSED]
%%   Directory where final configuration (generated from
%%   Cuttlefish-based configuration) is written
%%   Replaced by the use of Cuttlefish as a libray.

config_files(Context) ->
    ConfigBaseDir = get_config_base_dir(Context),
    MainConfigFileNoEx = get_main_config_file_noex(ConfigBaseDir),
    AdvancedConfigFileNoEx = get_advanced_config_file_noex(ConfigBaseDir),
    Context#{config_base_dir => ConfigBaseDir,
             main_config_file_noex => MainConfigFileNoEx,
             advanced_config_file_noex => AdvancedConfigFileNoEx}.

get_config_base_dir(#{os_type := {unix, _}}) ->
    SysPrefix = get_sys_prefix(),
    Dir = filename:join([SysPrefix, "etc", "rabbitmq"]),
    normalize_path(Dir);
get_config_base_dir(#{os_type := {win32, _}}) ->
    Dir = get_rabbitmq_base(),
    normalize_path(Dir).

get_main_config_file_noex(ConfigBaseDir) ->
    File = get_prefixed_env_var(
             "RABBITMQ_CONFIG_FILE",
             filename:join(ConfigBaseDir, "rabbitmq")),
    File1 = re:replace(File, "\\.(conf|config)$", "", [{return, list}]),
    Normalized = normalize_path(File1),
    os:putenv("RABBITMQ_CONFIG_FILE", Normalized),
    Normalized.

get_advanced_config_file_noex(ConfigBaseDir) ->
    File = get_prefixed_env_var(
             "RABBITMQ_ADVANCED_CONFIG_FILE",
             filename:join(ConfigBaseDir, "advanced")),
    File1 = re:replace(File, "\\.config$", "", [{return, list}]),
    Normalized = normalize_path(File1),
    os:putenv("RABBITMQ_ADVANCED_CONFIG_FILE", Normalized),
    Normalized.

%% -------------------------------------------------------------------
%%
%% RABBITMQ_LOG_BASE
%%   Directory to write log files
%%   Default: (Unix) ${SYS_PREFIX}/var/log/rabbitmq
%%         (Windows) ${RABBITMQ_BASE}\log
%%
%% RABBITMQ_LOGS
%%   Main log file
%%   Default: ${RABBITMQ_LOG_BASE}/${RABBITMQ_NODENAME}.log
%%
%% RABBITMQ_UPDATE_LOG
%%   Upgrade-procesure-specific log file
%%   Default: ${RABBITMQ_LOG_BASE}/${RABBITMQ_NODENAME}_upgrade.log
%%
%% RABBITMQ_LOG
%%   Log level; overrides the configuration file value
%%   Default: (undefined)

log_levels(Context) ->
    LogLevels = get_log_levels(),
    Context#{log_levels => LogLevels}.

log_files(Context) ->
    LogBaseDir = get_log_base_dir(Context),
    MainLogFile = get_main_log_file(Context, LogBaseDir),
    UpgradeLogFile = get_upgrade_log_file(Context, LogBaseDir),
    Context#{log_base_dir => LogBaseDir,
             main_log_file => MainLogFile,
             upgrade_log_file => UpgradeLogFile}.

get_log_levels() ->
    LogValue = get_prefixed_env_var("RABBITMQ_LOG"),
    case LogValue of
        false -> undefined;
        _     -> get_log_levels1(string:lexemes(LogValue, ","), #{})
    end.

get_log_levels1([CategoryValue | Rest], Result) ->
    case string:lexemes(CategoryValue, "=") of
        ["+color"] ->
            Result1 = Result#{color => true},
            get_log_levels1(Rest, Result1);
        ["-color"] ->
            Result1 = Result#{color => false},
            get_log_levels1(Rest, Result1);
        [CategoryOrLevel] ->
            case parse_level(CategoryOrLevel) of
                undefined ->
                    Result1 = Result#{CategoryOrLevel => debug},
                    get_log_levels1(Rest, Result1);
                Level ->
                    Result1 = Result#{global => Level},
                    get_log_levels1(Rest, Result1)
            end;
        [Category, Level0] ->
            case parse_level(Level0) of
                undefined ->
                    get_log_levels1(Rest, Result);
                Level ->
                    Result1 = Result#{Category => Level},
                    get_log_levels1(Rest, Result1)
            end
    end;
get_log_levels1([], Result) ->
    Result.

parse_level("debug")     -> debug;
parse_level("info")      -> info;
parse_level("notice")    -> notice;
parse_level("warning")   -> warning;
parse_level("error")     -> error;
parse_level("critical")  -> critical;
parse_level("alert")     -> alert;
parse_level("emergency") -> emergency;
parse_level("none")      -> none;
parse_level(_)           -> undefined.

get_log_base_dir(#{os_type := {unix, _}}) ->
    SysPrefix = get_sys_prefix(),
    Default = filename:join([SysPrefix, "etc", "rabbitmq"]),
    Normalized = normalize_path(get_prefixed_env_var(
                                  "RABBITMQ_LOG_BASE", Default)),
    os:putenv("RABBITMQ_LOG_BASE", Normalized),
    Normalized;
get_log_base_dir(#{os_type := {win32, _}}) ->
    RabbitmqBase = get_rabbitmq_base(),
    Default = filename:join([RabbitmqBase, "log"]),
    Normalized = normalize_path(get_prefixed_env_var(
                                  "RABBITMQ_LOG_BASE", Default)),
    os:putenv("RABBITMQ_LOG_BASE", Normalized),
    Normalized.

get_main_log_file(#{nodename := Nodename}, LogBaseDir) ->
    Default = filename:join(LogBaseDir, atom_to_list(Nodename) ++ ".log"),
    Value = get_prefixed_env_var("RABBITMQ_LOGS", Default),
    Normalized = case Value of
                     "-" -> Value;
                     _   -> normalize_path(Value)
                 end,
    os:putenv("RABBITMQ_LOGS", Normalized),
    Normalized.

get_upgrade_log_file(#{nodename := Nodename}, LogBaseDir) ->
    Default = filename:join(LogBaseDir,
                            atom_to_list(Nodename) ++ "_upgrade.log"),
    Normalized = normalize_path(get_prefixed_env_var(
                                  "RABBITMQ_UPGRADE_LOG", Default)),
    os:putenv("RABBITMQ_UPDATE_LOG", Normalized),
    Normalized.

%% -------------------------------------------------------------------
%%
%% RABBITMQ_MNESIA_BASE
%%   Directory where to create Mnesia directory.
%%   Default: (Unix) ${SYS_PREFIX}/var/lib/rabbitmq/mnesia
%%         (Windows) ${RABBITMQ_BASE}/db
%%
%% RABBITMQ_MNESIA_DIR
%%   Directory where to put Mnesia data.
%%   Default: ${RABBITMQ_MNESIA_BASE}/${RABBITMQ_NODENAME}

mnesia_dir(Context) ->
    MnesiaBaseDir = get_mnesia_base_dir(Context),
    MnesiaDir = get_mnesia_dir(Context, MnesiaBaseDir),
    Context#{mnesia_base_dir => MnesiaBaseDir,
             mnesia_dir => MnesiaDir}.

get_mnesia_base_dir(#{from_remote_node := false} = Context) ->
    get_mnesia_base_dir_from_env(Context);
get_mnesia_base_dir(#{from_remote_node := Remote} = Context) ->
    case get_prefixed_env_var("RABBITMQ_MNESIA_BASE") of
        false -> get_mnesia_base_dir_from_node(Context, Remote);
        _     -> get_mnesia_base_dir_from_env(Context)
    end.

get_mnesia_base_dir_from_env(Context) ->
    Default = get_default_mnesia_base_dir(Context),
    Dir = get_prefixed_env_var("RABBITMQ_MNESIA_BASE", Default),
    Normalized = normalize_path(Dir),
    os:putenv("RABBITMQ_MNESIA_BASE", Normalized),
    Normalized.

get_mnesia_base_dir_from_node(Context, Remote) ->
    Ret = query_remote(Remote, os, getenv, ["RABBITMQ_MNESIA_BASE"]),
    case Ret of
        {ok, Dir} when Dir =/= false ->
            Normalized = normalize_path(Dir),
            os:putenv("RABBITMQ_MNESIA_BASE", Normalized),
            Normalized;
        {badrpc, nodedown} ->
            get_mnesia_base_dir(Context)
    end.

get_default_mnesia_base_dir(Context) ->
    DataDir = get_rabbitmq_data_dir(Context),
    Basename = case Context of
                   #{os_type := {unix, _}}  -> "mnesia";
                   #{os_type := {win32, _}} -> "db"
               end,
    filename:join(DataDir, Basename).

get_mnesia_dir(#{from_remote_node := false} = Context, MnesiaBaseDir) ->
    get_mnesia_dir_from_env(Context, MnesiaBaseDir);
get_mnesia_dir(#{from_remote_node := Remote} = Context, MnesiaBaseDir) ->
    case get_prefixed_env_var("RABBITMQ_MNESIA_DIR") of
        false -> get_mnesia_dir_from_node(Context, MnesiaBaseDir, Remote);
        _     -> get_mnesia_dir_from_env(Context, MnesiaBaseDir)
    end.

get_mnesia_dir_from_env(#{nodename := Nodename}, MnesiaBaseDir) ->
    Dir = get_prefixed_env_var(
            "RABBITMQ_MNESA_DIR",
            filename:join(MnesiaBaseDir, Nodename)),
    Normalized = normalize_path(Dir),
    os:putenv("RABBITMQ_MNESIA_DIR", Normalized),
    Normalized.

get_mnesia_dir_from_node(Context, MnesiaBaseDir, Remote) ->
    Ret = query_remote(Remote, application, get_env, [mnesia, dir]),
    case Ret of
        {ok, undefined} ->
            throw({query, Remote, {mnesia, dir, undefined}});
        {ok, {ok, Dir}} ->
            Normalized = normalize_path(Dir),
            os:putenv("RABBITMQ_MNESIA_DIR", Normalized),
            Normalized;
        {badrpc, nodedown} ->
            get_mnesia_dir_from_env(Context, MnesiaBaseDir)
    end.

%% -------------------------------------------------------------------
%%
%% RABBITMQ_QUORUM_DIR
%%   Directory where to store Ra state for quorum queues.
%%   Default: ${RABBITMQ_MNESIA_DIR}/quorum

quorum_dir(Context) ->
    QuorumQueueDir = get_quorum_queue_dir(Context),
    Context#{quorum_queue_dir => QuorumQueueDir}.

get_quorum_queue_dir(#{mnesia_dir := MnesiaDir}) ->
    Default = filename:join(MnesiaDir, "quorum"),
    Dir = get_prefixed_env_var("RABBITMQ_QUORUM_DIR", Default),
    normalize_path(Dir).

%% -------------------------------------------------------------------
%%
%% RABBITMQ_PID_FILE [Unix only]
%%   File used to write the Erlang VM OS PID.
%%   Default: ${RABBITMQ_MNESIA_DIR}.pid

pid_file(#{os_type := {unix, _}} = Context) ->
    PidFile = get_pid_file_path(Context),
    Context#{pid_file => PidFile};
pid_file(#{os_type := {win32, _}} = Context) ->
    Context.

get_pid_file_path(#{mnesia_base_dir := MnesiaBaseDir,
                    nodename := Nodename}) ->
    File = get_prefixed_env_var(
             "RABBITMQ_PID_FILE",
             filename:join(MnesiaBaseDir, atom_to_list(Nodename) ++ ".pid")),
    Normalized = normalize_path(File),
    os:putenv("RABBITMQ_PID_FILE", Normalized),
    Normalized.

%% -------------------------------------------------------------------
%%
%% RABBITMQ_FEATURE_FLAGS_FILE
%%   File used to store enabled feature flags.
%%   Default: ${RABBITMQ_MNESIA_BASE}/${RABBITMQ_NODENAME}-feature_flags

feature_flags_file(Context) ->
    FFFile = get_feature_flags_file(Context),
    Context#{feature_flags_file => FFFile}.

get_feature_flags_file(#{from_remote_node := false} = Context) ->
    get_feature_flags_file_from_env(Context);
get_feature_flags_file(#{from_remote_node := Remote} = Context) ->
    case get_prefixed_env_var("RABBITMQ_FEATURE_FLAGS_FILE") of
        false -> get_feature_flags_file_from_node(Context, Remote);
        _     -> get_feature_flags_file_from_env(Context)
    end.

get_feature_flags_file_from_env(#{mnesia_base_dir := MnesiaBaseDir,
                                  nodename := Nodename}) ->
    Default = filename:join(MnesiaBaseDir,
                            atom_to_list(Nodename) ++ "-feature_flags"),
    File = get_env_var("RABBITMQ_FEATURE_FLAGS_FILE", Default),
    Normalized = normalize_path(File),
    os:putenv("RABBITMQ_FEATURE_FLAGS_FILE", Normalized),
    Normalized.

get_feature_flags_file_from_node(Context, Remote) ->
    Ret = query_remote(Remote,
                        application, get_env, [rabbit, feature_flags_file]),
    case Ret of
        {ok, undefined} ->
            throw({query, Remote, {rabbit, feature_flags_file, undefined}});
        {ok, {ok, File}} ->
            Normalized = normalize_path(File),
            os:putenv("RABBITMQ_FEATURE_FLAGS_FILE", Normalized),
            Normalized;
        {badrpc, nodedown} ->
            get_feature_flags_file_from_env(Context)
    end.

%% -------------------------------------------------------------------
%%
%% RABBITMQ_PLUGINS_DIR
%%   List of directories where to look for plugins.
%%   Directories are separated by:
%%     ':' on Unix
%%     ';' on Windows
%%   Default: ${RABBITMQ_HOME}/plugins
%%
%% RABBITMQ_ENABLED_PLUGINS_FILE
%%   File where the list of enabled plugins is stored.
%%   Default: (Unix) ${SYS_PREFIX}/etc/rabbitmq/enabled_plugins
%%         (Windows) ${RABBITMQ_BASE}\enabled_plugins

plugins_dirs(Context) ->
    PluginsPath = get_plugins_path(Context),
    PluginsExpandDir = get_plugins_expand_dir(Context),
    EnabledPluginsFile = get_enabled_plugins_file(Context),
    Context#{plugins_path => PluginsPath,
             plugins_expand_dir => PluginsExpandDir,
             enabled_plugins_file => EnabledPluginsFile}.

get_plugins_path(#{from_remote_node := false} = Context) ->
    get_plugins_path_from_env(Context);
get_plugins_path(#{from_remote_node := Remote} = Context) ->
    case get_prefixed_env_var("RABBITMQ_PLUGINS_DIR") of
        false -> get_plugins_path_from_node(Context, Remote);
        _     -> get_plugins_path_from_env(Context)
    end.

get_plugins_path_from_env(Context) ->
    Path = get_prefixed_env_var(
             "RABBITMQ_PLUGINS_DIR", get_default_plugins_path(Context)),
    os:putenv("RABBITMQ_PLUGINS_DIR", Path),
    Path.

get_plugins_path_from_node(Context, Remote) ->
    Ret = query_remote(Remote, application, get_env, [rabbit, plugins_dir]),
    case Ret of
        {ok, undefined} ->
            throw({query, Remote, {rabbit, plugins_dir, undefined}});
        {ok, {ok, Path}} ->
            os:putenv("RABBITMQ_PLUGINS_DIR", Path),
            Path;
        {badrpc, nodedown} ->
            get_plugins_path_from_env(Context)
    end.

get_default_plugins_path(#{dev_environment := false}) ->
    CommonPlugin = code:lib_dir(rabbit_common),
    filename:dirname(CommonPlugin);
get_default_plugins_path(#{dev_environment := true}) ->
    {ok, Cwd} = file:get_cwd(),
    filename:join(Cwd, "plugins").

get_plugins_expand_dir(#{mnesia_base_dir := MnesiaBaseDir,
                         nodename := Nodename}) ->
    Dir = get_prefixed_env_var(
            "RABBITMQ_PLUGINS_EXPAND_DIR",
            filename:join(MnesiaBaseDir,
                          atom_to_list(Nodename) ++ "-plugins-expand")),
    Normalized = normalize_path(Dir),
    os:putenv("RABBITMQ_PLUGINS_EXPAND_DIR", Dir),
    Normalized.

get_enabled_plugins_file(#{from_remote_node := false} = Context) ->
    get_enabled_plugins_file_from_env(Context);
get_enabled_plugins_file(#{from_remote_node := Remote} = Context) ->
    case get_prefixed_env_var("RABBITMQ_ENABLED_PLUGINS_FILE") of
        false -> get_enabled_plugins_file_from_node(Context, Remote);
        _     -> get_enabled_plugins_file_from_env(Context)
    end.

get_enabled_plugins_file_from_env(Context) ->
    ConfigBaseDir = get_config_base_dir(Context),
    Default = filename:join(ConfigBaseDir, "enabled_plugins"),
    File = get_prefixed_env_var("RABBITMQ_ENABLED_PLUGINS_FILE", Default),
    Normalized = normalize_path(File),
    os:putenv("RABBITMQ_ENABLED_PLUGINS_FILE", Normalized),
    Normalized.

get_enabled_plugins_file_from_node(Context, Remote) ->
    Ret = query_remote(Remote,
                       application, get_env, [rabbit, enabled_plugins_file]),
    case Ret of
        {ok, undefined} ->
            throw({query, Remote, {rabbit, enabled_plugins_file, undefined}});
        {ok, {ok, File}} ->
            os:putenv("RABBITMQ_ENABLED_PLUGINS_FILE", File),
            File;
        {badrpc, nodedown} ->
            get_enabled_plugins_file_from_env(Context)
    end.

%% -------------------------------------------------------------------
%%
%% RABBITMQ_NODE_IP_ADDRESS
%%   AMQP TCP IP address to listen on
%%   Default: unset (i.e. listen on all interfaces)
%%
%% RABBITMQ_NODE_PORT
%%   AMQP TCP port.
%%   Default: 5672
%%
%% RABBITMQ_DIST_PORT
%%   Erlang distribution TCP port.
%%   Default: ${RABBITMQ_NODE_PORT} + 20000

tcp_configuration(Context) ->
    AmqpIpAddress = get_amqp_ipaddr(),
    AmqpTcpPort = get_amqp_tcp_port(),
    DistTcpPort = get_erlang_dist_tcp_port(AmqpTcpPort),
    Context#{amqp_ipaddr_and_tcp_port => {AmqpIpAddress, AmqpTcpPort},
             erlang_dist_tcp_port => DistTcpPort}.

get_amqp_ipaddr() ->
    get_prefixed_env_var("RABBITMQ_NODE_IP_ADDRESS", "auto").

get_amqp_tcp_port() ->
    Default = 5672,
    case get_prefixed_env_var("RABBITMQ_NODE_PORT") of
        false ->
            Default;
        TcpPortStr ->
            try
                erlang:list_to_integer(TcpPortStr)
            catch
                _:badarg ->
                    rabbit_log_prelaunch:error(
                      "Invalid value for $RABBITMQ_NODE_PORT: ~p",
                      [TcpPortStr]),
                    throw({exit, ex_config})
            end
    end.

get_erlang_dist_tcp_port(AmqpTcpPort) ->
    Default = AmqpTcpPort + 20000,
    case get_prefixed_env_var("RABBITMQ_DIST_PORT") of
        false ->
            Default;
        TcpPortStr ->
            try
                erlang:list_to_integer(TcpPortStr)
            catch
                _:badarg ->
                    rabbit_log_prelaunch:error(
                      "Invalid value for $RABBITMQ_DIST_PORT: ~p",
                      [TcpPortStr]),
                    throw({exit, ex_config})
            end
    end.

%% -------------------------------------------------------------------
%%
%%  SYS_PREFIX [Unix only]
%%    Default: ""
%%
%%  RABBITMQ_BASE [Windows only]
%%    Directory where to put RabbitMQ data.
%%    Default: !APPDATA!\RabbitMQ

get_rabbitmq_data_dir(#{os_type := {unix, _}}) ->
    SysPrefix = get_sys_prefix(),
    filename:join([SysPrefix, "var", "lib", "rabbitmq"]);
get_rabbitmq_data_dir(#{os_type := {win32, _}}) ->
    get_rabbitmq_base().

get_sys_prefix() ->
    normalize_path(get_env_var("SYS_PREFIX", "")).

get_rabbitmq_base() ->
    case get_env_var("RABBITMQ_BASE") of
        false ->
            AppData = get_env_var("APPDATA"),
            filename:join(AppData, "RabbitMQ");
        Value ->
            normalize_path(Value)
    end.

%% -------------------------------------------------------------------
%% Helpers.
%% -------------------------------------------------------------------

get_env_var(VarName) ->
    case os:getenv(VarName) of
        false -> false;
        ""    -> false;
        Value -> Value
    end.

get_env_var(VarName, DefaultValue) ->
    case get_env_var(VarName) of
        false -> DefaultValue;
        Value -> Value
    end.

get_prefixed_env_var("RABBITMQ_" ++ Suffix = VarName) ->
    case get_env_var(VarName) of
        false -> get_env_var(Suffix);
        Value -> Value
    end.

get_prefixed_env_var(VarName, DefaultValue) ->
    case get_prefixed_env_var(VarName) of
        false -> DefaultValue;
        Value -> Value
    end.

normalize_path("" = Path) ->
    Path;
normalize_path(Path) ->
    filename:join(filename:split(Path)).

is_dev_environment() ->
    %LibDir = code:lib_dir(rabbit_common),
    {_, _, File} = code:get_object_code(?MODULE),
    LibDir = filename:dirname(filename:dirname(File)),
    %% Module can be:
    %%     1. rabbit_common/ebin/rabbit_env.beam.
    %%        LibDir = rabbit_common
    %%     2. rabbit/escript/$cli/rabbit_env.beam.
    %%        LibDir = rabbit/escript
    ErlangMkLoc1 = filename:join(LibDir, "erlang.mk"),
    ErlangMkLoc2 = filename:join(filename:dirname(LibDir), "erlang.mk"),
    filelib:is_regular(ErlangMkLoc1) orelse filelib:is_regular(ErlangMkLoc2).

maybe_setup_dist_for_remote_query(#{from_remote_node := false} = Context) ->
    Context;
maybe_setup_dist_for_remote_query(#{from_remote_node := Remote} = Context) ->
    {NamePart, HostPart} = rabbit_nodes_common:parts(Remote),
    NameType = case string:find(HostPart, ".") of
                   nomatch -> shortnames;
                   _       -> longnames
               end,
    setup_dist_for_remote_query(Context, NamePart, HostPart, NameType, 50).

setup_dist_for_remote_query(_, _, _, _, 0) ->
    {error, ex_unavailable};
setup_dist_for_remote_query(Context,
                            NamePart, HostPart, NameType,
                            Attempts) ->
    RndNamePart = NamePart ++ "_ctl_" ++ integer_to_list(rand:uniform(100)),
    Nodename = rabbit_nodes_common:make({RndNamePart, HostPart}),
    case net_kernel:start([Nodename, NameType]) of
        {ok, _} -> Context;
        _       -> setup_dist_for_remote_query(Context,
                                               NamePart, HostPart, NameType,
                                               Attempts - 1)
    end.

maybe_stop_dist_for_remote_query(#{from_remote_node := false} = Context) ->
    Context;
maybe_stop_dist_for_remote_query(Context) ->
    net_kernel:stop(),
    Context.

query_remote(Remote, Mod, Func, Args) ->
    Ret = rpc:call(Remote, Mod, Func, Args, ?RPC_TIMEOUT),
    case Ret of
        {badrpc, nodedown} = Error -> Error;
        {badrpc, _} = Error        -> throw({query, Remote, Error});
        _                          -> {ok, Ret}
    end.
