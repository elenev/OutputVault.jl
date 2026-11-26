# A project's settings: AbstractConfig (the interface), Config (the usual implementation) and the
# active configuration.

"""
    AbstractConfig

The interface behind [`Config`](@ref): the methods `output_root(cfg)`, `table_format(cfg)`,
`native(cfg)` and `staging_root(cfg)`. A project that computes its settings (the root from the
machine, say) defines a subtype with these methods; only `output_root` is required.
"""
abstract type AbstractConfig end

"""
    output_root(cfg) -> String

The top folder of the project's saved runs.
"""
output_root(cfg::AbstractConfig) = error("$(typeof(cfg)) must implement output_root(cfg)")

"""
    table_format(cfg) -> Union{AbstractTableFormat, Nothing}

The format of table files; `nothing` (the default) if tables are not saved.
"""
table_format(cfg::AbstractConfig) = nothing

"""
    native(cfg) -> Bool

Whether solution saves also write `native.jld2`, the solution as Julia objects. Default `true`.
"""
native(cfg::AbstractConfig) = true

"""
    staging_root(cfg) -> String

Where a solution's run folder is written before it is renamed into place. It must be on the same
file system as the runs. Default `<output_root>/.staging`.
"""
staging_root(cfg::AbstractConfig) = joinpath(output_root(cfg), ".staging")

"""
    Config(; output_root, table_format = nothing, native = true,
             staging_root = joinpath(output_root, ".staging"))

A project's settings, made active with [`set_config!`](@ref) or [`with_config`](@ref).

- `output_root`: the top folder of the saved runs.
- `table_format`: the format of table files, e.g. `OutputVault.Formats.ParquetFormat()`; needed
  only if a table is written.
- `native`: also write `native.jld2`, the solution as Julia objects, on solution saves.
- `staging_root`: where a solution's run folder is written before it is renamed into place; on
  the same file system as the runs, so that the rename is atomic.
"""
struct Config{F <: Union{Nothing, AbstractTableFormat}} <: AbstractConfig
    output_root::String
    table_format::F
    native::Bool
    staging_root::String
end

function Config(; output_root::AbstractString, table_format::Union{Nothing, AbstractTableFormat} = nothing,
                  native::Bool = true, staging_root::AbstractString = joinpath(output_root, ".staging"))
    return Config(String(output_root), table_format, native, String(staging_root))
end

output_root(cfg::Config) = cfg.output_root
table_format(cfg::Config) = cfg.table_format
native(cfg::Config) = cfg.native
staging_root(cfg::Config) = cfg.staging_root

## The active configuration

const _GLOBAL_CONFIG = Ref{Union{AbstractConfig, Nothing}}(nothing)

"""
    global_config() -> AbstractConfig

The active configuration. An error if none is set.
"""
function global_config()
    c = _GLOBAL_CONFIG[]
    if isnothing(c)
        error("No OutputVault config set. Call `OutputVault.set_config!(cfg)`.")
    end
    return c
end

"""
    set_config!(cfg::AbstractConfig) -> cfg

Make `cfg` the active configuration, used by every OutputVault function. Typically called in a
project package's `__init__`.
"""
function set_config!(cfg::AbstractConfig)
    _GLOBAL_CONFIG[] = cfg
    return cfg
end

"""
    with_config(f, cfg::AbstractConfig)

Call `f()` with `cfg` as the active configuration, then restore the previous one, also if `f`
throws.
"""
function with_config(f, cfg::AbstractConfig)
    old = _GLOBAL_CONFIG[]
    _GLOBAL_CONFIG[] = cfg
    try
        return f()
    finally
        _GLOBAL_CONFIG[] = old
    end
end
