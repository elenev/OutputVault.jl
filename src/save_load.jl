# Each component is a folder `res-{experdef}-{economy}/{component}/` with one file per property,
# `{property}.{ext}`. Components saved by OutputVault 0.1 (one `{component}.jld2` per component)
# still load.
#
# Producer interface: a package (or extension) that wants its types stored in their own formats
# declares a storage kind for them (`storage_kind`, namespaced, e.g.
# "TransitionFunctionIteration.ModelSolution"), writes them with `write_object` methods built on
# `write_table` or `jld2_record`, and restores them with `read_kind` methods. OutputVault records
# the kind under its own key ("outputvault.kind" in table metadata, "outputvault/kind" in JLD2
# files) and dispatches on it when loading. Objects without a kind are stored with JLD2.

"""
    load(cfg::AbstractConfig, rf::RunHandle, component::Symbol) -> NamedTuple
    load(rf::RunHandle, component::Symbol) -> NamedTuple

Load a saved component and return a `NamedTuple` keyed by the property names declared for that
component in `cfg`. Objects come back as their own types (e.g. a TFI `ModelSolution` or
`SimulationPanel`). The no-config form uses the module-level config.
"""
function FileIO.load(cfg::AbstractConfig, rf::RunHandle, component::Symbol)
    epath = economy_folder(cfg, rf)
    props = components(cfg)[component]
    legacy = joinpath(epath, "$component.jld2")
    isfile(legacy) && return _load_legacy(legacy, props)
    dir = joinpath(epath, string(component))
    isdir(dir) || error("Component $component not found in $epath")
    return NamedTuple{props}(map(p -> read_object(cfg, dir, string(p)), props))
end

FileIO.load(rf::RunHandle, component::Symbol) =
    FileIO.load(global_config(), rf, component)

# a component saved by OutputVault 0.1: one JLD2 file keyed by property name
function _load_legacy(path, props)
    d = load(path)
    return NamedTuple{props}(tuple((d[string(p)] for p in props)...))
end

"""
    save_result(cfg::AbstractConfig, rf::RunHandle, result; skip, dirty_repo_check) -> String
    save_result(rf::RunHandle, result; kwargs...) -> String

Save all components of `result` under the economy folder for `rf`, one folder per component and
one file per property. Returns the economy folder path.

The `git_component(cfg)` folder also receives the git commit id (`git_commit.txt`) and, for a
dirty repository, the staged and unstaged diffs (`git_staged.diff`, `git_unstaged.diff`; the
latter includes untracked files). Objects in that component get the commit id as provenance.

# Keyword arguments
- `skip`: tuple of component symbols to omit; defaults to `skip_components(cfg)`.
- `dirty_repo_check`: `:warn` (default), `:error`, or `:ignore`. Controls behavior when
  the repository has uncommitted changes.
"""
function save_result(cfg::AbstractConfig, rf::RunHandle, result;
        skip::Tuple{Vararg{Symbol}} = skip_components(cfg),
        dirty_repo_check::Symbol    = :warn)

    commit_id, diffs = get_commit_id(dirty_repo_check)
    epath = economy_folder(cfg, rf; create=true)

    for (component, props) in pairs(components(cfg))
        component in skip && continue
        dir = mkpath(joinpath(epath, string(component)))
        provenance = component === git_component(cfg) ?
            write_git_files(dir, commit_id, diffs) : Dict{String,String}()
        for p in props
            write_object(cfg, dir, string(p), getproperty(result, p); provenance)
        end
    end

    return epath
end

save_result(rf::RunHandle, result; kwargs...) =
    save_result(global_config(), rf, result; kwargs...)

# commit id and (if any) diffs as text files; returns the commit id as provenance for the objects
function write_git_files(dir, commit_id, diffs)
    write(joinpath(dir, "git_commit.txt"), commit_id * "\n")
    isempty(diffs.staged)   || write(joinpath(dir, "git_staged.diff"), diffs.staged)
    isempty(diffs.unstaged) || write(joinpath(dir, "git_unstaged.diff"), diffs.unstaged)
    return Dict("git_commit_id" => commit_id)
end

## Producer interface: storage kinds, writers, readers

const TABLE_KIND_KEY = "outputvault.kind"
const JLD2_KIND_KEY = "outputvault/kind"

"""
    storage_kind(x) -> Union{String, Nothing}

The kind OutputVault records with `x`, which selects the `read_kind` method that restores it.
Producers define it for their types, namespaced by package (e.g.
`"TransitionFunctionIteration.ModelSolution"`). Default `nothing`: stored with JLD2 as is.
"""
storage_kind(x) = nothing

"""
    write_object(cfg, dir, name, x; provenance)

Write `x` into `dir` as `name.<ext>`. Producers add methods for their types, built on
`write_table` or `jld2_record` so that the kind is recorded; other objects are stored with JLD2
as `name.jld2`. `provenance` holds strings identifying the run (the git commit id, for the git
component).
"""
write_object(cfg::AbstractConfig, dir, name, x; provenance = Dict{String,String}()) =
    jldsave(joinpath(dir, name * ".jld2"); value = x)

"""
    write_table(cfg, stem, table)

Write a Tables.jl `table` as `stem.<ext>` with the config's table format, recording
`storage_kind(table)` in the file's metadata.
"""
function write_table(cfg::AbstractConfig, stem, table)
    fmt = table_format(cfg)
    isnothing(fmt) && throw(ArgumentError(
        "saving a $(nameof(typeof(table))) needs a table format: Config(; table_format = TableFormat(...))"))
    kind = storage_kind(table)
    meta = isnothing(kind) ? Dict{String,String}() : Dict(TABLE_KIND_KEY => kind)
    fmt.write(stem * "." * fmt.ext, table, meta)
end

"""
    jld2_record(f, path, x) -> path

Create the JLD2 file `path`, record `storage_kind(x)` in it, and call `f(io)` to write the rest.
"""
function jld2_record(f, path, x)
    jldopen(path, "w") do io
        io[JLD2_KIND_KEY] = storage_kind(x)
        f(io)
    end
    return path
end

"""
    recorded_kind(path) -> Union{String, Nothing}

The storage kind recorded in a JLD2 file, or `nothing`.
"""
recorded_kind(path) = jldopen(io -> haskey(io, JLD2_KIND_KEY) ? io[JLD2_KIND_KEY] : nothing, path, "r")

"""
    read_kind(::Val{kind}, path)
    read_kind(::Val{kind}, source, path, fmt)

Restore an object of the recorded `kind` from a JLD2 file, or from a table `source` read from
`path` with table format `fmt`. Producers add methods for their kinds.
"""
read_kind(::Val{K}, args...) where {K} =
    error("No reader for kind $K; load the package that stores it")

## Reading objects

# object `name` in `dir`, from `name.jld2` or `name.<table ext>`
function read_object(cfg::AbstractConfig, dir, name)
    jld = joinpath(dir, name * ".jld2")
    isfile(jld) && return read_jld2(jld)
    fmt = table_format(cfg)
    if !isnothing(fmt)
        path = joinpath(dir, name * "." * fmt.ext)
        isfile(path) && return read_table(fmt, path)
    end
    error("No file for $name in $dir")
end

# a JLD2 file: the reader for its recorded kind, else the stored value
function read_jld2(path)
    kind = recorded_kind(path)
    isnothing(kind) ? load(path, "value") : read_kind(Val(Symbol(kind)), path)
end

# a table: the reader for the kind recorded in its metadata
function read_table(fmt::TableFormat, path)
    source = fmt.read(path)
    kind = DataAPI.metadata(source, TABLE_KIND_KEY, nothing)
    isnothing(kind) && error("$path does not record its storage kind ($TABLE_KIND_KEY)")
    read_kind(Val(Symbol(kind)), source, path, fmt)
end

## Solution files (methods in package extensions)

"""
    save_solution(path, obj; provenance = Dict{String,String}())

Write a model solution to a single HDF5-compatible file. Methods come with package extensions
(TransitionFunctionIteration: grids, exogenous environment and the values of Pfct, Vfct, Tfct
and Ffct at the grid nodes as plain arrays, metadata, and an exact JLD2 copy of the model).
`provenance` holds strings identifying the run, e.g. a git commit.
"""
function save_solution end

"""
    load_solution(path)                      # model restored from the exact copy in the file
    load_solution(path, mdl)                 # supplied model, compared with the stored metadata
    load_solution(path, M::Type)             # model rebuilt by model_from_metadata(M, metadata)

Restore a solution written by `save_solution`.
"""
function load_solution end

"""
    save_steadystate(path, stv)

Write a steady state as plain data, with the model's metadata but not the model itself (the
model is stored once, with the solution).
"""
function save_steadystate end

"""
    load_steadystate(path)                   # model from the solution file in the same folder
    load_steadystate(path, mdl)              # supplied model, compared with the stored metadata
    load_steadystate(path, M::Type)          # model rebuilt by model_from_metadata(M, metadata)

Restore a steady state written by `save_steadystate`.
"""
function load_steadystate end

"""
    model_metadata(mdl) -> NamedTuple

Plain-data description of a model: reals, strings, symbols, small numeric arrays and
NamedTuples of these. Stored with saved solutions and steady states, and compared with a
supplied model when one is loaded. Methods for TransitionFunctionIteration models come with
its extension; overload it for models whose fields include derived objects, together with
`model_from_metadata`.
"""
function model_metadata end

"""
    model_from_metadata(::Type{M}, metadata::NamedTuple) -> M

Rebuild a model of type `M` from `model_metadata` output (used by `load_solution(path, M)`).
"""
function model_from_metadata end
