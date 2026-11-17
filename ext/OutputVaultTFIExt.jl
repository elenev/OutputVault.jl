# OutputVault for TransitionFunctionIteration: writers and readers for TFI's types, and model
# metadata for TFI models.
#
# Portable solution files: plain HDF5-compatible arrays and metadata written with JLD2, with no
# Julia objects, so they read without the code that wrote them (the native copy, res.jld2, is
# written by OutputVault's save_result). Layout (schema version 2):
#   outputvault/kind (recorded by OutputVault.jld2_record)
#   meta/{schema_version, tfi_version, created, solution_id, model_type, singletons}
#   meta/model/... (model_metadata tree), meta/provenance/<key> (strings supplied by the caller)
#   grid/<axis> (vectors; a singleton axis is a length-1 vector), grid/__axes (axis order)
#   exogenv/points/<var>, exogenv/points/__names (variable order), exogenv/mtrans, exogenv/ssidx
#   Pfct/<var>, Vfct/<var>, Ffct/<var>: arrays over the grid axes (Pfct in unconstrained space)
#   Tfct/<var>: arrays over the grid axes and next period's exogenous state
#   <fct>/__vars (variable order)
#   Pfct/__bounds/<var>, Tfct/__bounds/<var>: [lower, upper] for each variable, plus __names
#     (variable order). The model comes from a supplied model or model_from_metadata.
# Steady-state files: outputvault/kind, meta/{schema_version, tfi_version, model_type}, meta/model/..., and
# guess/, endog/, exog/, values/ (one entry per name, plus __names for the order). The model is
# not stored: it comes from a supplied model or model_from_metadata.
# The schema version changes when a change breaks readers of earlier files; the reader accepts
# only the current version. Added entries do not change it (readers ignore unknown keys).
# Files are written uncompressed: h5py cannot read JLD2's compressed (chunked) datasets.
# Tables (panels, moments, IRFs) go through the config's table format; their own metadata come from
# TFI's DataAPI interface, and OutputVault adds the storage kind.
module OutputVaultTFIExt

using OutputVault, FileIO, JLD2, StaticArrays, StructArrays
using OutputVault: AbstractConfig, write_table, write_table_parts, jld2_record, table_extension, read_table_file
import OutputVault: storage_kind, write_object, read_kind, save_solution, load_solution,
                    save_steadystate, load_steadystate, model_metadata, model_from_metadata
import TransitionFunctionIteration as TFI
using TransitionFunctionIteration: AbstractModel, ModelSolution, SteadyState, MomentArray,
    SimulationPanel, SimulationErrorPanel, IRFResult, irf_paths, solution_id, Exogenv,
    StateSpaceGrid, Interpolant, unigrids, points, transition_matrix, ssidx, coefficients,
    varnames, dims, singletons, compare_economies

const SCHEMA_VERSION = 2
const FCTS = (:Pfct, :Vfct, :Tfct, :Ffct)
const STV_PARTS = (:guess, :endog, :exog, :values)

## compare_economies over saved runs: the components that the moments need: stats, IRFs and parameters

# the moments that are not calculated, including the inputs of calculated ones
leaf_moments(m::TFI.CalculatedMoment) = reduce(vcat, map(leaf_moments, collect(values(m.inputs))))
leaf_moments(m::TFI.AbstractMoment) = [m]
leaf_moments(x) = [TFI.SimulationMoment(x)]    # a bare variable name

function TFI.compare_economies(
        moments::NamedTuple,
        economies::NamedTuple{K, NTuple{N, OutputVault.RunHandle}} where {K, N};
        kwargs...)
    leaves = reduce(vcat, map(leaf_moments, collect(values(moments))); init = TFI.AbstractMoment[])
    needs_stats = any(m -> m isa TFI.SimulationMoment, leaves)
    needs_irf = any(m -> m isa TFI.ImpulseMoment, leaves)
    needs_params = any(m -> m isa TFI.ParameterMoment, leaves)
    results = map(economies) do e
        TFI.EconomyResult(; stats = needs_stats ? FileIO.load(e, :stats).stats : nothing,
                          irf = needs_irf ? FileIO.load(e, :irf).irf : nothing,
                          params = needs_params ? FileIO.load(e, :params).params : nothing)
    end
    return compare_economies(moments, results; kwargs...)
end

## Storage kinds, writers and readers

const STORED_TYPES = Union{ModelSolution, SteadyState, MomentArray, SimulationPanel, SimulationErrorPanel, IRFResult, Interpolant}
storage_kind(x::STORED_TYPES) = "TransitionFunctionIteration." * string(nameof(typeof(x)))
# the kind of a stored type by name, as dispatched on by read_kind
kind(name) = Val{Symbol("TransitionFunctionIteration.", name)}

write_object(cfg::AbstractConfig, dir, name, obj::ModelSolution; provenance = Dict{String,String}()) =
    save_solution(joinpath(dir, name * ".jld2"), obj; provenance)
write_object(cfg::AbstractConfig, dir, name, stv::SteadyState; provenance = Dict{String,String}()) =
    save_steadystate(joinpath(dir, name * ".jld2"), stv)
write_object(cfg::AbstractConfig, dir, name, x::Union{SimulationPanel, SimulationErrorPanel};
             provenance = Dict{String,String}()) =
    write_table(cfg, joinpath(dir, name), x)
# a MomentArray names its column of row names itself (its row key: `variable` for statistics,
# `equation` for error statistics, `parameter` for parameters), and the file's metadata records it
write_object(cfg::AbstractConfig, dir, name, x::MomentArray; provenance = Dict{String,String}()) =
    write_table(cfg, joinpath(dir, name), x)
# moments by sample (describe(...).moments): one table per sample, `<sample>.<ext>`
write_object(cfg::AbstractConfig, dir, name, s::TFI.SamplesTuple; provenance = Dict{String,String}()) =
    write_table_parts(cfg, dir, name, s)
# an IRF is two tables: statistics (`name`) and raw paths (`name_paths`, empty if none were saved)
function write_object(cfg::AbstractConfig, dir, name, irf::IRFResult; provenance = Dict{String,String}())
    write_table(cfg, joinpath(dir, name), irf)
    write_table(cfg, joinpath(dir, name * "_paths"), irf_paths(irf))
end

# an Interpolant over a state-space grid (e.g. recursions computed at a solution's policies): its grid
# and one array per variable, as in a solution file, so that it loads without the solution
function write_object(cfg::AbstractConfig, dir, name, fct::Interpolant; provenance = Dict{String,String}())
    jld2_record(joinpath(dir, name * ".jld2"), fct) do io
        io["meta/schema_version"] = SCHEMA_VERSION
        io["meta/tfi_version"] = TFI.tfi_version()
        io["meta/created"] = Libc.strftime("%Y-%m-%dT%H:%M:%S", time())
        for (k, v) in provenance
            io["meta/provenance/$k"] = string(v)
        end
        write_grid(io, fct.ssg)
        write_fct(io, "fct", fct)
    end
end

function read_kind(::kind(:Interpolant), path; model = nothing)
    jldopen(path, "r") do io
        check_schema(io)
        read_fct(io, "fct", read_grid(io))
    end
end

# the grid of a file: the exogenous axis is the indices 1:n (as StateSpaceGrid(exogenv, ...) builds it)
function read_grid(io)
    axes = Tuple(Symbol(a) for a in io["grid/__axes"])
    grids = NamedTuple{axes}(map(a -> a == :exst ? (1:length(io["grid/exst"])) : io["grid/$a"], axes))
    StateSpaceGrid(grids)
end

read_kind(::kind(:ModelSolution), path; model = nothing) = load_solution(path, _required_model(model, path))
read_kind(::kind(:SteadyState), path; model = nothing) = load_steadystate(path, _required_model(model, path))

_required_model(model, path) = isnothing(model) ? throw(ArgumentError(
    "$path is a portable file without the model: load with model = <model or model type>, or read the native copy")) : model
read_kind(::kind(:SimulationPanel), source, path, fmt) = SimulationPanel(source)
read_kind(::kind(:SimulationErrorPanel), source, path, fmt) = SimulationErrorPanel(source)
read_kind(::kind(:MomentArray), source, path, fmt) = MomentArray(source)
function read_kind(::kind(:IRFResult), source, path, fmt)
    paths = splitext(path)[1] * "_paths." * table_extension(fmt)
    isfile(paths) ? IRFResult(source, read_table_file(fmt, paths)) : IRFResult(source)
end

## Model metadata

const MAX_METADATA_ARRAY_LENGTH = 1_000
const MAX_METADATA_DEPTH = 4

# Default for TFI models: the model's fields, recursively (NamedTuples, dictionaries with Symbol
# or String keys, structs; at most MAX_METADATA_DEPTH levels), keeping reals, strings, symbols and
# numeric arrays/tuples with at most MAX_METADATA_ARRAY_LENGTH elements. Anything else (functions,
# interpolants, large arrays) is left out.
model_metadata(mdl::AbstractModel) = something(_plain_metadata(mdl, 0), (;))
model_from_metadata(::Type{M}, metadata::NamedTuple) where {M<:AbstractModel} = M(; metadata...)

# plain values pass through, anything else becomes `nothing` (dropped)
_plain_metadata(x::Union{Real,AbstractString,Symbol}, depth) = x
_plain_metadata(x::Union{Array{<:Real},AbstractRange{<:Real},StaticArray{<:Tuple,<:Real}}, depth) =
    length(x) <= MAX_METADATA_ARRAY_LENGTH ? collect(x) : nothing
_plain_metadata(x::Tuple{Vararg{Real}}, depth) = length(x) <= MAX_METADATA_ARRAY_LENGTH ? collect(x) : nothing
_plain_metadata(x::NamedTuple, depth) = _plain_namedtuple(pairs(x), depth)
_plain_metadata(x::AbstractDict{<:Union{Symbol,AbstractString}}, depth) = _plain_namedtuple(x, depth)
_plain_metadata(::Union{AbstractArray,AbstractDict,Function,Module,Type,Ptr}, depth) = nothing
function _plain_metadata(x, depth)
    T = typeof(x)
    isstructtype(T) && fieldcount(T) > 0 || return nothing
    _plain_namedtuple((f => getfield(x, f) for f in fieldnames(T)), depth)
end

function _plain_namedtuple(prs, depth)
    depth >= MAX_METADATA_DEPTH && return nothing
    kept = Pair{Symbol,Any}[]
    for (k, v) in prs
        pv = _plain_metadata(v, depth + 1)
        pv === nothing || push!(kept, Symbol(k) => pv)
    end
    isempty(kept) ? nothing : NamedTuple(kept)
end

# nested metadata as String pairs with dotted keys, so that two models' metadata can be compared
# key by key
function flatten_metadata(nt::NamedTuple, prefix::AbstractString)
    out = Dict{String,String}()
    for (k, v) in pairs(nt)
        key = isempty(prefix) ? string(k) : string(prefix, ".", k)
        v isa NamedTuple ? merge!(out, flatten_metadata(v, key)) : (out[key] = string(v))
    end
    out
end

model_type_name(mdl) = string(parentmodule(typeof(mdl)), ".", nameof(typeof(mdl)))

## Solution files: writing

function save_solution(path::AbstractString, obj::ModelSolution;
                       provenance::AbstractDict = Dict{String,String}())
    jld2_record(path, obj) do io
        io["meta/schema_version"] = SCHEMA_VERSION
        io["meta/tfi_version"] = TFI.tfi_version()
        io["meta/created"] = Libc.strftime("%Y-%m-%dT%H:%M:%S", time())
        io["meta/solution_id"] = solution_id(obj)
        for (k, v) in provenance
            io["meta/provenance/$k"] = string(v)
        end
        io["meta/model_type"] = model_type_name(obj.model)
        io["meta/singletons"] = collect(map(string, singletons(obj.ssg)))
        write_tree(io, "meta/model", model_metadata(obj.model))
        write_grid(io, obj.ssg)
        write_exogenv(io, obj.exogenv)
        for name in FCTS
            fct = getfield(obj, name)
            isnothing(fct) || write_fct(io, string(name), fct)
        end
        write_bounds(io, "Pfct/__bounds", obj.Pfct_bounds)
        write_bounds(io, "Tfct/__bounds", obj.Tfct_bounds)
    end
end

# nested NamedTuple as groups
function write_tree(io, prefix, nt::NamedTuple)
    for (k, v) in pairs(nt)
        v isa NamedTuple ? write_tree(io, "$prefix/$k", v) : (io["$prefix/$k"] = v)
    end
end

# a flat NamedTuple of numbers or numeric arrays as one entry per name, plus the order
function write_namedtuple(io, prefix, nt::NamedTuple)
    io["$prefix/__names"] = collect(map(string, keys(nt)))
    for (k, v) in pairs(nt)
        io["$prefix/$k"] = _plain_value(v, k)
    end
end
_plain_value(v::Number, k) = v
_plain_value(v::AbstractArray{<:Number}, k) = collect(v)
_plain_value(v, k) = throw(ArgumentError("cannot store $k::$(typeof(v)) as plain data"))

function write_grid(io, ssg)
    grids = unigrids(ssg)
    io["grid/__axes"] = collect(map(string, keys(grids)))
    for (k, g) in pairs(grids)
        io["grid/$k"] = g isa Number ? [g] : collect(g)
    end
end

function write_exogenv(io, exogenv)
    write_namedtuple(io, "exogenv/points", map(collect, StructArrays.components(points(exogenv))))
    io["exogenv/mtrans"] = Matrix(transition_matrix(exogenv))
    io["exogenv/ssidx"] = ssidx(exogenv)
end

# one array per variable over the full grid (singleton axes have length 1); a trailing axis for vector outputs
function write_fct(io, name, fct)
    coefs = coefficients(fct)
    io["$name/__vars"] = collect(map(string, varnames(fct)))
    for (i, var) in enumerate(varnames(fct))
        io["$name/$var"] = eltype(coefs) <: SMatrix ?
            stack(c -> Vector(c[i, :]), coefs) |> a -> permutedims(a, (2:ndims(a)..., 1)) :
            map(c -> c[i], coefs)
    end
end

# bounds of each variable as [lower, upper] (±Inf where unbounded), in variable order
function write_bounds(io, prefix, nt::NamedTuple)
    io["$prefix/__names"] = collect(map(string, keys(nt)))
    for (k, b) in pairs(nt)
        io["$prefix/$k"] = bound_interval(b)
    end
end
bound_interval(::TFI.Unbounded) = [-Inf, Inf]
bound_interval(b::TFI.LowerBounded) = [Float64(b.lower), Inf]
bound_interval(b::TFI.UpperBounded) = [-Inf, Float64(b.upper)]
bound_interval(b::TFI.IntervalBounded) = [Float64(b.lower), Float64(b.upper)]

## Solution files: reading

function load_solution(path::AbstractString, mdl::AbstractModel)
    jldopen(path, "r") do io
        check_model(io, mdl)
        check_exogenv(io, mdl)
        rebuild(io, mdl)
    end
end

function load_solution(path::AbstractString, ::Type{M}) where {M<:AbstractModel}
    jldopen(path, "r") do io
        rebuild(io, model_from_metadata(M, read_tree(io, "meta/model")))
    end
end

read_tree(io, prefix) = haskey(io, prefix) ? read_group(io[prefix]) : (;)
read_group(g) = NamedTuple(Symbol(k) => (v = g[k]; v isa JLD2.Group ? read_group(v) : v) for k in keys(g))

function read_namedtuple(io, prefix)
    names = io["$prefix/__names"]
    NamedTuple{Tuple(Symbol(n) for n in names)}(Tuple(io["$prefix/$n"] for n in names))
end

# warn if the supplied model's metadata differ from the stored ones
function check_model(io, mdl)
    stored = flatten_metadata(read_tree(io, "meta/model"), "")
    supplied = flatten_metadata(model_metadata(mdl), "")
    differ = sort!([k for k in union(keys(stored), keys(supplied)) if get(stored, k, nothing) != get(supplied, k, nothing)])
    isempty(differ) || @warn "The supplied model's metadata differ from the stored model's" keys = first(differ, 10)
end

# warn if the supplied model's exogenous environment differs from the stored one (which is used)
function check_exogenv(io, mdl)
    exogenv = try Exogenv(mdl) catch; nothing end
    isnothing(exogenv) || isapprox(exogenv, read_exogenv(io)) ||
        @warn "The supplied model's exogenous environment differs from the stored one (the stored one is used)"
end

read_exogenv(io) = Exogenv(; pts = StructArray(read_namedtuple(io, "exogenv/points")),
                             mtrans = io["exogenv/mtrans"], ssidx = io["exogenv/ssidx"])

function check_schema(io)
    io["meta/schema_version"] == SCHEMA_VERSION ||
        throw(ArgumentError("file schema $(io["meta/schema_version"]), this OutputVault reads $SCHEMA_VERSION"))
end

function rebuild(io, mdl)
    check_schema(io)
    exogenv = read_exogenv(io)
    axes = Tuple(Symbol(a) for a in io["grid/__axes"])
    endog_axes = Tuple(a for a in axes if a != :exst)
    ssg = StateSpaceGrid(exogenv, NamedTuple{endog_axes}(map(a -> io["grid/$a"], endog_axes)))
    fcts = NamedTuple{FCTS}(map(name -> haskey(io, string(name)) ? read_fct(io, string(name), ssg) : nothing, FCTS))
    obj = ModelSolution(; model = mdl, exogenv, ssg, fcts.Pfct, fcts.Vfct, fcts.Tfct, fcts.Ffct,
                          Pfct_bounds = read_bounds(io, "Pfct/__bounds"), Tfct_bounds = read_bounds(io, "Tfct/__bounds"))
    solution_id(obj) == io["meta/solution_id"] ||
        @warn "The restored solution's id differs from the stored one: the file may be corrupted"
    obj
end

read_bounds(io, prefix) = map(interval_bound, read_namedtuple(io, prefix))
function interval_bound((lo, hi))
    isinf(lo) && isinf(hi) && return TFI.Unbounded()
    isinf(hi) && return TFI.LowerBounded(lo)
    isinf(lo) && return TFI.UpperBounded(hi)
    TFI.IntervalBounded(lo, hi)
end

# interpolant from per-variable arrays; singleton axes dropped to match the grid's points
function read_fct(io, name, ssg)
    vars = Tuple(Symbol(v) for v in io["$name/__vars"])
    arrays = map(v -> io["$name/$v"], vars)
    gridsize = Tuple(values(dims(ssg)))
    keep = Tuple(i for (i, a) in enumerate(keys(dims(ssg))) if !(a in singletons(ssg)))
    pointsize = gridsize[collect(keep)]
    vector_valued = ndims(first(arrays)) == length(gridsize) + 1
    values_at(I) = NamedTuple{vars}(map(a -> vector_valued ? SVector{size(a, ndims(a))}(a[I, :]) : a[I], arrays))
    nodes = reshape([values_at(I) for I in CartesianIndices(gridsize)], pointsize)
    Interpolant(ssg, StructArray(nodes))
end

## Steady-state files

function save_steadystate(path::AbstractString, stv::SteadyState)
    jld2_record(path, stv) do io
        io["meta/schema_version"] = SCHEMA_VERSION
        io["meta/tfi_version"] = TFI.tfi_version()
        io["meta/model_type"] = model_type_name(stv.model)
        write_tree(io, "meta/model", model_metadata(stv.model))
        for part in STV_PARTS
            write_namedtuple(io, string(part), getfield(stv, part))
        end
    end
end

function load_steadystate(path::AbstractString, mdl::AbstractModel)
    jldopen(path, "r") do io
        check_model(io, mdl)
        rebuild_steadystate(io, mdl)
    end
end

load_steadystate(path::AbstractString, ::Type{M}) where {M<:AbstractModel} =
    jldopen(io -> rebuild_steadystate(io, model_from_metadata(M, read_tree(io, "meta/model"))), path, "r")

function rebuild_steadystate(io, mdl)
    check_schema(io)
    parts = NamedTuple{STV_PARTS}(map(part -> read_namedtuple(io, string(part)), STV_PARTS))
    SteadyState(; model = mdl, parts...)
end

end # module
