const _GLOBAL_CONFIG = Ref{Union{AbstractConfig, Nothing}}(nothing)

function global_config()
    c = _GLOBAL_CONFIG[]
    isnothing(c) && error("No OutputVault config set. Call `OutputVault.set_config!(cfg)`.")
    return c
end

"""
    set_config!(cfg::AbstractConfig)

Store `cfg` as the module-level OutputVault configuration. Returns `cfg`.

Called in a consuming package's `__init__` so exported functions can be used without
passing `cfg` explicitly.
"""
set_config!(cfg::AbstractConfig) = (_GLOBAL_CONFIG[] = cfg; cfg)

"""
    with_config(f, cfg::AbstractConfig)

Execute `f()` with `cfg` as the active configuration, then restore the previous config.
The previous config is restored even if `f` throws. Useful in tests and multi-project
REPL sessions.
"""
function with_config(f, cfg::AbstractConfig)
    old = _GLOBAL_CONFIG[]
    _GLOBAL_CONFIG[] = cfg
    try
        f()
    finally
        _GLOBAL_CONFIG[] = old
    end
end
