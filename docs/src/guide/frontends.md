# Frontends

A frontend is a package that stores its types through OutputVault, such as TransitionFunctionIteration
through its package extension. OutputVault does all reading and writing; the frontend says what to
store for each of its types and how to rebuild them.

Plain values and Tables.jl tables work without a frontend. Add one when users should be able to
load your package's objects with their original behavior, rather than manipulate stored columns
and Dicts. The examples below run independently of the [Quick Start](@ref).

## The contract

For each of its types `T`, a frontend may define:

- `to_storage(x::T)`: the value OutputVault writes by the storage rules ([Runs and Storage](@ref)):
  a Tables.jl table (one table file), a NamedTuple (a folder) or anything else (a `.jld2` file). A type
  that is already a table needs no method.
- `from_storage(::Type{T}, data; context)`: rebuild a `T` from the data read back, a
  [`StoredTable`](@ref OutputVault.Formats.StoredTable) or a NamedTuple of the members' data.
  OutputVault calls it only with a type the caller supplied, never with one read from disk.
- `write_portable_jld2(io, x::T)` and `read_portable_jld2(::Type{T}, io; context)`: a portable layout inside a `.jld2`
  file instead of the Julia object, for example plain arrays that h5py reads. `io` is the open JLD2
  file.

`context` is whatever the caller of [`load_result_item`](@ref) passed, for a type whose files do not
store everything it needs (TransitionFunctionIteration passes the model). `from_storage` sees only the
item's own data, never other items of the run, so values that are meaningful only together form one
item. Frontends never see a path, except through the JLD2 handle.

`to_storage` applies at every level of a folder, `from_storage` does not: OutputVault cannot know the
types of a folder's members, so the parent's `from_storage` converts them. Typed loading of a table
or folder without a `from_storage` method throws `MethodError`. For a `.jld2` item the reader is
`read_portable_jld2`, whose default returns `io["value"]`; it does not call `from_storage` or check
that the stored value has type `T`.

## An object stored as a folder

A small economy holds numeric parameters and settings. Store parameters as a queryable one-row
table and settings as individual `.jld2` values:

```@example frontend
using OutputVault, Parquet2, Tables
import OutputVault: to_storage, from_storage, write_portable_jld2, read_portable_jld2

set_config!(Config(output_root = abspath("../outputs"),
                   table_format = OutputVault.Formats.ParquetFormat()))
rf = RunHandle("base"; experdef = "frontend")

struct Economy
    beta::Float64
    sigma::Float64
    distro::String
    mit::Bool
end

# a folder: a one-row parameter table (queryable) and the settings (.jld2 files)
to_storage(e::Economy) = (params = (beta = [e.beta], sigma = [e.sigma]), settings = (; e.distro, e.mit))

function from_storage(::Type{Economy}, data; context = nothing)
    params = Tables.columns(data.params)
    return Economy(only(params.beta), only(params.sigma), data.settings.distro["value"], data.settings.mit["value"])
end

economy = Economy(0.99, 2.0, "Beta", true)
save_solution(rf, (; economy))
list_run(rf)
```

The outer solution is a folder, and `to_storage(economy)` gives another folder. Its `params` member
is a table because all its members are equal-length vectors. `settings` is a folder of scalar
values, so the raw values are under `"value"` in Dicts. The parent converter above handles both:

```@example frontend
restored = load_result_item(rf, "solution/economy", Economy)
(restored.beta, restored.distro, restored.mit)
```

The parameter table can be queried directly, without reconstructing an `Economy`:

```@example frontend
shape = QueryShape("solution/economy/params"; column = :parameter)
query_results([rf], shape; parameter = :beta)
```

## An object stored in a portable file

Keep a type unchanged by `to_storage` when it needs its own layout inside a `.jld2` file. Here the
writer saves plain arrays and a name; the reader obtains a required model identifier from the
caller. The `context` keyword is available only to the reader:

```@example frontend
# a solution with its own layout inside a .jld2 file; the model comes from the caller
struct Solution
    model::Symbol
    coefs::Vector{Float64}
end
function write_portable_jld2(io, s::Solution)
    io["coefs"] = s.coefs
    io["model_name"] = string(s.model)
end
function read_portable_jld2(::Type{Solution}, io; context = nothing)
    if !(context isa Symbol) || string(context) != io["model_name"]
        throw(ArgumentError("pass the stored model's identifier as context"))
    end
    return Solution(context, io["coefs"])
end

save_result_item(rf, "fit", Solution(:dsge, [1.0, 2.0]))  # fit.jld2, plain arrays and a string
fit = load_result_item(rf, "fit", Solution; context = :dsge)
fit.coefs
```

The same hooks work with `write_object_file` and `read_object_file` outside a run. Native solution
copies bypass all these hooks and contain the original Julia objects, so a frontend may offer
both a portable reload and a native reload with compatible code.

## Conveniences

Functions that save or load several items at once, or that know which type each path holds, belong
in the frontend's own code. TransitionFunctionIteration's `save_result(rf, result)` calls
`save_solution` and then `save_result_item` for each output of `solve_and_simulate`, and
`load_result(rf, :stats)` loads an item as TFI's types. A frontend can also ship
[`QueryShape`](@ref)s for its tables, so that its users query them without naming paths and columns.
