# The project execution platform — the prelude's platforms/defs.bzl copied and
# configured, as its own comment instructs. One difference: the executor config
# participates in the NativeLink action cache when the mode file asks
# (narsil.remote_cache=1, set by @mode/nativelink): local execution, remote
# cache READ, and upload of local results. Remote EXECUTION stays off — the
# straylight workers don't carry the devshell ghc on PATH (yet).

def _execution_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    cfg = ConfigurationInfo(constraints = constraints, values = {})

    remote_cache = read_root_config("narsil", "remote_cache", "0") == "1"

    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = True,
            remote_enabled = False,
            remote_cache_enabled = remote_cache,
            allow_cache_uploads = remote_cache,
            use_windows_path_separators = ctx.attrs.use_windows_path_separators,
        ),
    )

    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(platforms = [platform]),
    ]

execution_platform = rule(
    impl = _execution_platform_impl,
    attrs = {
        "cpu_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "os_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "use_windows_path_separators": attrs.bool(),
    },
)

def _host_cpu_configuration() -> str:
    arch = host_info().arch
    if arch.is_aarch64:
        return "prelude//cpu:arm64"
    else:
        return "prelude//cpu:x86_64"

def _host_os_configuration() -> str:
    os = host_info().os
    if os.is_macos:
        return "prelude//os:macos"
    elif os.is_windows:
        return "prelude//os:windows"
    else:
        return "prelude//os:linux"

def narsil_execution_platform(name):
    execution_platform(
        name = name,
        cpu_configuration = _host_cpu_configuration(),
        os_configuration = _host_os_configuration(),
        use_windows_path_separators = host_info().os.is_windows,
        visibility = ["PUBLIC"],
    )
