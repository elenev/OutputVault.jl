"""
    RunHandle(economy; branch=current_branch(), experdef="default")
    RunHandle(; branch, experdef, economy)

Identifies a saved run by branch, experiment definition, and economy name. The run's folder is
`<output_root>/<branch>/res-<experdef>-<economy>`.

`branch` defaults to the git branch of Julia's working directory. Passing it chooses only the folder:
the git commit saved with a solution is always that of the working directory's repository.

All fields are coerced to `String` on construction. `experdef` must not contain `-`: the run's
folder is `res-<experdef>-<economy>`, and readers (the DuckDB macros in `outputvault.sql`) split
it at the first hyphen. `economy` may contain anything.
"""
@kwdef struct RunHandle
    branch::String   = current_branch()
    experdef::String = "default"
    economy::String
    function RunHandle(branch, experdef, economy)
        e = string(experdef)
        occursin('-', e) && throw(ArgumentError("experdef \"$e\" contains '-'; the run folder res-<experdef>-<economy> splits at the first hyphen"))
        new(string(branch), e, string(economy))
    end
end

RunHandle(economy; kwargs...) = RunHandle(; economy=string(economy), kwargs...)

# ── Layout (fixed for every OutputVault user) ─────────────────────────────────────

"""
    LAYOUT

Where each saved property goes: one folder per component under the run's folder. Fixed, so that
every project's runs have the same structure and tools can find objects across runs.

| component    | properties            |
|:-------------|:----------------------|
| `solution`   | `obj`, `stv`          |
| `stats`      | `stats` (the moments `compare_economies` compares; moments by sample are saved one table per sample, `stats/<sample>.<ext>`) |
| `errstats`   | `errstats`            |
| `simulation` | `simseries`, `errs`   |
| `irf`        | `irf`                 |
| `params`     | `params` (the model's scalar parameters, see TFI's `collect_parameters`) |
| `recursions` | `claims`, `welfare` (interpolants of recursions computed at a solution's policies; each is saved when it is computed, the solution is not touched) |
"""
const LAYOUT = (solution = (:obj, :stv), stats = (:stats,), errstats = (:errstats,),
                simulation = (:simseries, :errs), irf = (:irf,), params = (:params,),
                recursions = (:claims, :welfare))

# the component with the git provenance; saving any of its properties replaces the run's folder
const SOLUTION_COMPONENT = :solution

layout_properties(component::Symbol) = haskey(LAYOUT, component) ? LAYOUT[component] :
    throw(ArgumentError("unknown component $component; OutputVault's components are $(keys(LAYOUT))"))

# ── AbstractConfig interface ────────────────────────────────────────────────────

abstract type AbstractConfig end

# Required — subtypes must implement
output_root(cfg::AbstractConfig) =
    error("$(typeof(cfg)) must implement output_root(cfg)::String")

# Optional — `nothing` means tables cannot be saved
table_format(cfg::AbstractConfig) = nothing

# Optional — how the solution is saved
solution_format(cfg::AbstractConfig) = (:portable, :native)

# Optional — where a replacing solution is written before it is moved into place (see `save_result`)
staging_root(cfg::AbstractConfig) = joinpath(tempdir(), "OutputVault")

const SOLUTION_FORMATS = (:portable, :native)

# a format or tuple of formats as a tuple of known formats
function _solution_format_tuple(f)
    t = f isa Symbol ? (f,) : Tuple(f)
    !isempty(t) && all(in(SOLUTION_FORMATS), t) ||
        throw(ArgumentError("solution_format must be :portable, :native or (:portable, :native), got $f"))
    t
end

# ── Config — project settings ───────────────────────────────────────────────────

struct Config{F <: Union{Nothing, AbstractTableFormat}} <: AbstractConfig
    output_root::String
    table_format::F
    solution_format::Tuple{Vararg{Symbol}}
    staging_root::String
end

"""
    Config(; output_root, table_format=nothing, solution_format=(:portable, :native),
             staging_root=joinpath(tempdir(), "OutputVault"))

A project's OutputVault settings. Where each object goes is fixed (`LAYOUT`); which objects are
saved is chosen in each `save_result` call.

# Arguments
- `output_root`: filesystem root for all saved outputs.
- `table_format`: an `AbstractTableFormat` (e.g. `OutputVault.Formats.ParquetFormat()`), needed to
  save objects written as tables (TFI's simulations, moments and IRFs).
- `solution_format`: how the solution is saved: `:portable` (one file per object, written by the
  package that supports its type; for TFI a documented layout of plain arrays; JLD2 for other
  values), `:native` (all of the solution's objects in one JLD2 file, `res.jld2`, as Julia objects),
  or both. Other components are saved one file per object, like the portable copy.
- `staging_root`: where `save_result` writes a new solution's run folder before moving it into place.
  If the move fails (on Windows, open files can block it), the new results stay here and
  `save_result` warns. Default: a folder in the system temp directory.
"""
function Config(;
    output_root::String,
    table_format::F       = nothing,
    solution_format       = (:portable, :native),
    staging_root::String  = joinpath(tempdir(), "OutputVault"),
) where {F <: Union{Nothing, AbstractTableFormat}}
    Config{F}(output_root, table_format, _solution_format_tuple(solution_format), staging_root)
end

output_root(cfg::Config)     = cfg.output_root
table_format(cfg::Config)    = cfg.table_format
solution_format(cfg::Config) = cfg.solution_format
staging_root(cfg::Config)    = cfg.staging_root
