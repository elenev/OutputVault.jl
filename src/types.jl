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

# ── Config — data-driven concrete implementation ────────────────────────────────

struct Config{C <: NamedTuple, N} <: AbstractConfig
    output_root::String
    git_component::Symbol
    skip_components::NTuple{N, Symbol}
    components::C
end

"""
    Config(; output_root, components, git_component=:solution, skip_components=(:simulation,))

Concrete `AbstractConfig` implementation. All four values are stored as fields and returned
unchanged by the corresponding accessor methods.

# Arguments
- `output_root`: filesystem root for all saved outputs.
- `components`: `NamedTuple` mapping component `Symbol` to a tuple of property `Symbol`s,
  e.g. `(solution=(:obj, :stv), stats=(:stats,))`.
- `git_component`: component that receives `git_commit_id` and `git_diffs` on save.
- `skip_components`: components omitted by default in `save_result`.
"""
function Config(;
    output_root::String,
    components::C,
    git_component::Symbol = :solution,
    skip_components       = (:simulation,),
) where {C <: NamedTuple}
    sc = NTuple{length(skip_components), Symbol}(skip_components)
    Config{C, length(sc)}(output_root, git_component, sc, components)
end

output_root(cfg::Config)     = cfg.output_root
components(cfg::Config)      = cfg.components
git_component(cfg::Config)   = cfg.git_component
skip_components(cfg::Config) = cfg.skip_components
