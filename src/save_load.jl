# Each component is a folder `res-{experdef}-{economy}/{component}/` with one file per property,
# `{property}.{ext}`, at the place `LAYOUT` gives it. Components saved by OutputVault 0.1 (one
# `{component}.jld2` per component) still load.
#
# Producer interface: a package (or extension) that wants its types stored in their own formats
# declares a storage kind for them (`storage_kind`, namespaced, e.g.
# "TransitionFunctionIteration.ModelSolution"), writes them with `write_object` methods built on
# `write_table` or `jld2_record`, and restores them with `read_kind` methods. OutputVault records
# the kind under its own key ("outputvault.kind" in table metadata, "outputvault/kind" in JLD2
# files) and dispatches on it when loading. Objects without a kind are stored with JLD2.

"""
    load(cfg::AbstractConfig, rf::RunHandle, component::Symbol; solution_format = :native, model = nothing) -> NamedTuple
    load(rf::RunHandle, component::Symbol; kwargs...) -> NamedTuple

Load a saved component (see `LAYOUT`) and return a `NamedTuple` of the properties that were
saved, in layout order. Objects come back as their own types (e.g. a TFI `ModelSolution` or
`SimulationPanel`). The no-config form uses the module-level config.

For the solution, `solution_format` picks the copy that is read: `:native` (`res.jld2`, the
objects exactly as they were saved; needs compatible code) or `:portable` (one file per object;
objects that store a model, such as TFI solutions and steady states, need `model`, either a
model or a model type, see `load_solution`). Other components are always portable and ignore
both keywords.
"""
function FileIO.load(cfg::AbstractConfig, rf::RunHandle, component::Symbol;
                     solution_format::Symbol = :native, model = nothing)
    props = layout_properties(component)
    epath = economy_folder(cfg, rf)
    legacy = joinpath(epath, "$component.jld2")
    isfile(legacy) && return _load_legacy(legacy, props)
    dir = joinpath(epath, string(component))
    isdir(dir) || error("Component $component not found in $epath")
    if component === SOLUTION_COMPONENT
        _solution_format_tuple(solution_format)
        solution_format === :native && return _load_native(dir, props)
    end
    saved = filter(p -> has_object(cfg, dir, string(p)), props)
    isempty(saved) && error("No objects of component $component in $dir")
    return NamedTuple{saved}(map(p -> read_object(cfg, dir, string(p); model), saved))
end

FileIO.load(rf::RunHandle, component::Symbol; kwargs...) =
    FileIO.load(global_config(), rf, component; kwargs...)

const NATIVE_FILE = "res.jld2"

# the solution's objects as Julia saved them
function _load_native(dir, props)
    path = joinpath(dir, NATIVE_FILE)
    isfile(path) || error("No $NATIVE_FILE in $dir (saved without :native); load with solution_format = :portable")
    d = load(path)
    saved = filter(p -> haskey(d, string(p)), props)
    return NamedTuple{saved}(map(p -> d[string(p)], saved))
end

# a component saved by OutputVault 0.1: one JLD2 file keyed by property name
function _load_legacy(path, props)
    d = load(path)
    saved = filter(p -> haskey(d, string(p)), props)
    return NamedTuple{saved}(map(p -> d[string(p)], saved))
end

"""
    save_result(cfg::AbstractConfig, rf::RunHandle, result; dirty_repo_check) -> String
    save_result(rf::RunHandle, result; kwargs...) -> String

Save the properties of `result` that `LAYOUT` names, each in its component's folder under the
economy folder for `rf`, one file per property. Which objects are saved is the caller's choice:
properties that `result` lacks or that are `nothing` are not saved; properties outside the
layout are ignored. Returns the economy folder path.

The economy folder holds the results of one solution: a save that includes solution objects
(`obj`, `stv`) first deletes the folder and everything in it, so that no results of an earlier
solution remain. Saves without solution objects (e.g. IRFs computed later) add to the folder.

The solution is saved in the formats `solution_format(cfg)`: `:portable` writes one file per
object (as every other component), `:native` writes all its objects to `res.jld2` with JLD2,
exactly as they are. The solution folder also receives the git commit id (`git_commit.txt`) and,
for a dirty repository, the staged and unstaged diffs (`git_staged.diff`, `git_unstaged.diff`;
the latter includes untracked files). Solution objects get the commit id as provenance.

# Keyword arguments
- `dirty_repo_check`: `:warn` (default), `:error`, or `:ignore`. Controls behavior when
  the repository has uncommitted changes.
"""
function save_result(cfg::AbstractConfig, rf::RunHandle, result; dirty_repo_check::Symbol = :warn)
    saved = map(props -> filter(p -> !isnothing(_property(result, p)), props), LAYOUT)
    commit_id, diffs = get_commit_id(dirty_repo_check)
    isempty(saved[SOLUTION_COMPONENT]) || _clear_economy_folder(cfg, rf)
    epath = economy_folder(cfg, rf; create=true)

    for (component, props) in pairs(saved)
        isempty(props) && continue
        dir = mkpath(joinpath(epath, string(component)))
        is_solution = component === SOLUTION_COMPONENT
        provenance = is_solution ? write_git_files(dir, commit_id, diffs) : Dict{String,String}()
        formats = is_solution ? solution_format(cfg) : (:portable,)
        if :portable in formats
            for p in props
                write_object(cfg, dir, string(p), getproperty(result, p); provenance)
            end
        end
        :native in formats &&
            jldsave(joinpath(dir, NATIVE_FILE); (p => getproperty(result, p) for p in props)...)
    end

    return epath
end

save_result(rf::RunHandle, result; kwargs...) =
    save_result(global_config(), rf, result; kwargs...)

# property `p` of `result`, `nothing` if it has none
_property(result, p) = hasproperty(result, p) ? getproperty(result, p) : nothing

# delete the economy folder (`output_root/branch/res-{experdef}-{economy}`) if it exists
function _clear_economy_folder(cfg, rf)
    p = joinpath(output_path(cfg, rf.branch), "res-$(rf.experdef)-$(rf.economy)")
    isdir(p) && rm(p; recursive=true)
end

# commit id and (if any) diffs as text files; returns the commit id as provenance for the objects
function write_git_files(dir, commit_id, diffs)
    write(joinpath(dir, "git_commit.txt"), commit_id * "\n")
    isempty(diffs.staged)   || write(joinpath(dir, "git_staged.diff"), diffs.staged)
    isempty(diffs.unstaged) || write(joinpath(dir, "git_unstaged.diff"), diffs.unstaged)
    return Dict("git_commit_id" => commit_id)
end

## Producer interface: storage kinds, writers, readers

const TABLE_KIND_KEY = "outputvault.kind"
const PART_OF_KEY = "outputvault.part_of"        # parts of a NamedTuple saved as one table each
const PART_INDEX_KEY = "outputvault.part_index"
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
    write_table(cfg, stem, table; meta = Dict{String,String}())

Write a Tables.jl `table` as `stem.<ext>` with the config's table format, recording
`storage_kind(table)` and the entries `meta` in the file's metadata.
"""
function write_table(cfg::AbstractConfig, stem, table; meta = Dict{String,String}())
    fmt = table_format(cfg)
    isnothing(fmt) && throw(ArgumentError(
        "saving a $(nameof(typeof(table))) needs a table format: Config(; table_format = OutputVault.Formats.ParquetFormat()), for example"))
    kind = storage_kind(table)
    meta = isnothing(kind) ? Dict{String,String}(meta) : merge(Dict(TABLE_KIND_KEY => kind), meta)
    write_table_file(fmt, stem * "." * table_extension(fmt), table, meta)
end

"""
    write_table_parts(cfg, dir, name, parts::NamedTuple)

Write object `name`, a NamedTuple of tables, as one table per part, `dir/<part>.<ext>`. Each file
records the object it belongs to and its position, so that loading returns the NamedTuple with
its parts in order. Producers use it for objects such as moments by sample.
"""
function write_table_parts(cfg::AbstractConfig, dir, name, parts::NamedTuple)
    for (i, (part, table)) in enumerate(pairs(parts))
        write_table(cfg, joinpath(dir, string(part)), table;
                    meta = Dict(PART_OF_KEY => name, PART_INDEX_KEY => string(i)))
    end
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
    read_kind(::Val{kind}, path; model)
    read_kind(::Val{kind}, source, path, fmt)

Restore an object of the recorded `kind` from a JLD2 file, or from a table `source` read from
`path` with table format `fmt`. Producers add methods for their kinds. `model` is what the caller
of `load` supplied (`nothing`, a model or a model type), for objects that store a model.
"""
read_kind(::Val{K}, args...; kwargs...) where {K} =
    error("No reader for kind $K; load the package that stores it")

## Reading objects

# the parts of object `name` saved by write_table_parts: (index, part, path) sorted by index
function part_files(cfg::AbstractConfig, dir, name)
    fmt = table_format(cfg)
    (isnothing(fmt) || !isdir(dir)) && return Tuple{Int,Symbol,String}[]
    ext = "." * table_extension(fmt)
    parts = Tuple{Int,Symbol,String}[]
    for f in readdir(dir; join = true)
        endswith(f, ext) || continue
        source = read_table_file(fmt, f)
        DataAPI.metadata(source, PART_OF_KEY, nothing) == name || continue
        push!(parts, (parse(Int, DataAPI.metadata(source, PART_INDEX_KEY)), Symbol(basename(f)[1:end-length(ext)]), f))
    end
    sort!(parts)
end

# the file of object `name` in `dir`: `name.jld2` or `name.<table ext>`; `nothing` if neither exists
function object_file(cfg::AbstractConfig, dir, name)
    jld = joinpath(dir, name * ".jld2")
    isfile(jld) && return jld
    fmt = table_format(cfg)
    isnothing(fmt) && return nothing
    path = joinpath(dir, name * "." * table_extension(fmt))
    isfile(path) ? path : nothing
end

has_object(cfg::AbstractConfig, dir, name) =
    !isnothing(object_file(cfg, dir, name)) || !isempty(part_files(cfg, dir, name))

function read_object(cfg::AbstractConfig, dir, name; model = nothing)
    path = object_file(cfg, dir, name)
    if isnothing(path)
        parts = part_files(cfg, dir, name)
        isempty(parts) && error("No file for $name in $dir")
        fmt = table_format(cfg)
        return NamedTuple{Tuple(p[2] for p in parts)}(Tuple(read_table(fmt, p[3]) for p in parts))
    end
    endswith(path, ".jld2") ? read_jld2(path; model) : read_table(table_format(cfg), path)
end

# a JLD2 file: the reader for its recorded kind, else the stored value
function read_jld2(path; model = nothing)
    kind = recorded_kind(path)
    isnothing(kind) ? load(path, "value") : read_kind(Val(Symbol(kind)), path; model)
end

# a table: the reader for the kind recorded in its metadata
function read_table(fmt::AbstractTableFormat, path)
    source = read_table_file(fmt, path)
    kind = DataAPI.metadata(source, TABLE_KIND_KEY, nothing)
    isnothing(kind) && error("$path does not record its storage kind ($TABLE_KIND_KEY)")
    read_kind(Val(Symbol(kind)), source, path, fmt)
end

## Solution files (methods in package extensions)

"""
    save_solution(path, obj; provenance = Dict{String,String}())

Write a model solution to a single portable HDF5-compatible file of plain data. Methods come
with package extensions (TransitionFunctionIteration: grids, exogenous environment, the values of
Pfct, Vfct, Tfct and Ffct at the grid nodes, the bounds, and metadata, including the model's).
`provenance` holds strings identifying the run, e.g. a git commit.
"""
function save_solution end

"""
    load_solution(path, mdl)                 # supplied model, compared with the stored metadata
    load_solution(path, M::Type)             # model rebuilt by model_from_metadata(M, metadata)

Restore a solution written by `save_solution`.
"""
function load_solution end

"""
    save_steadystate(path, stv)

Write a steady state to a portable file of plain data, with the model's metadata.
"""
function save_steadystate end

"""
    load_steadystate(path, mdl)              # supplied model, compared with the stored metadata
    load_steadystate(path, M::Type)          # model rebuilt by model_from_metadata(M, metadata)

Restore a steady state written by `save_steadystate`.
"""
function load_steadystate end

"""
    model_metadata(mdl) -> NamedTuple

Plain-data description of a model: reals, strings, symbols, small numeric arrays and
NamedTuples of these. Stored with portable solutions and steady states, and compared with a
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

"""
    collect_parameters(obj_or_model) -> MomentArray

The model's parameters as a table to save in the `params` component: one row per parameter, one
column `value`. The default for TFI models (in the TransitionFunctionIteration extension) takes
every scalar real or Boolean field of the model (a Boolean is 0 or 1); a project can add a method
for its model type to choose differently. Save it with `save_result(rf, (; params = collect_parameters(obj)))`.
"""
function collect_parameters end

