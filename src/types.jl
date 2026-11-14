"""
    RunHandle(economy; branch=current_branch(), experdef="default")
    RunHandle(; branch, experdef, economy)

Identifies a saved run by branch, experiment definition, and economy name.

All fields are coerced to `String` on construction.
"""
@kwdef struct RunHandle
    branch::String   = current_branch()
    experdef::String = "default"
    economy::String
    RunHandle(branch, experdef, economy) = new(string(branch), string(experdef), string(economy))
end

RunHandle(economy; kwargs...) = RunHandle(; economy=string(economy), kwargs...)

# ── AbstractConfig interface ────────────────────────────────────────────────────

abstract type AbstractConfig end

# Required — subtypes must implement
output_root(cfg::AbstractConfig) =
    error("$(typeof(cfg)) must implement output_root(cfg)::String")
components(cfg::AbstractConfig) =
    error("$(typeof(cfg)) must implement components(cfg)::NamedTuple")

# Optional — subtypes must implement (defaults provided by Config keyword args)
git_component(cfg::AbstractConfig) =
    error("$(typeof(cfg)) must implement git_component(cfg)::Symbol")
skip_components(cfg::AbstractConfig) =
    error("$(typeof(cfg)) must implement skip_components(cfg)::Tuple")

# Optional — `nothing` means tables cannot be saved
table_format(cfg::AbstractConfig) = nothing

# ── TableFormat ─────────────────────────────────────────────────────────────────

"""
    TableFormat(; ext, write, read)

How tables are stored: the file extension, `write(path, table, meta)`, which writes the table
with its own metadata plus the file-level entries `meta` (a `Dict{String,String}`), and
`read(path)`, which returns a Tables.jl source with the file's metadata. For parquet:

    TableFormat(ext = "parquet", read = Parquet2.Dataset,
                write = (path, table, meta) -> Parquet2.writefile(path, table; metadata = meta))
"""
@kwdef struct TableFormat{W, R}
    ext::String
    write::W
    read::R
end

# ── Config — data-driven concrete implementation ────────────────────────────────

struct Config{C <: NamedTuple, N, F <: Union{Nothing, TableFormat}} <: AbstractConfig
    output_root::String
    git_component::Symbol
    skip_components::NTuple{N, Symbol}
    components::C
    table_format::F
end

"""
    Config(; output_root, components, git_component=:solution, skip_components=(:simulation,),
             table_format=nothing)

Concrete `AbstractConfig` implementation. All four values are stored as fields and returned
unchanged by the corresponding accessor methods.

# Arguments
- `output_root`: filesystem root for all saved outputs.
- `components`: `NamedTuple` mapping component `Symbol` to a tuple of property `Symbol`s,
  e.g. `(solution=(:obj, :stv), stats=(:stats,))`.
- `git_component`: component that receives `git_commit_id` and `git_diffs` on save.
- `skip_components`: components omitted by default in `save_result`.
- `table_format`: a `TableFormat`, needed to save tables (simulations, moments, IRFs).
"""
function Config(;
    output_root::String,
    components::C,
    git_component::Symbol = :solution,
    skip_components       = (:simulation,),
    table_format::F       = nothing,
) where {C <: NamedTuple, F <: Union{Nothing, TableFormat}}
    sc = NTuple{length(skip_components), Symbol}(skip_components)
    Config{C, length(sc), F}(output_root, git_component, sc, components, table_format)
end

output_root(cfg::Config)     = cfg.output_root
components(cfg::Config)      = cfg.components
git_component(cfg::Config)   = cfg.git_component
skip_components(cfg::Config) = cfg.skip_components
table_format(cfg::Config)    = cfg.table_format
