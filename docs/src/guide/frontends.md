# Frontends

A frontend is a package that stores its types through OutputVault, such as TransitionFunctionIteration
through its package extension. OutputVault does all reading and writing; the frontend says what to
store for each of its types and how to rebuild them.

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
types of a folder's members, so the parent's `from_storage` converts them.

## An example

A frontend for an economy with parameters, a panel and settings with strings and booleans:

```julia
using OutputVault, Tables, DataAPI
import OutputVault: to_storage, from_storage, write_portable_jld2, read_portable_jld2

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

# a solution with its own layout inside a .jld2 file; the model comes from the caller
struct Solution
    model::Symbol
    coefs::Vector{Float64}
end
function write_portable_jld2(io, s::Solution)
    io["coefs"] = s.coefs
    io["model_name"] = string(s.model)
end
read_portable_jld2(::Type{Solution}, io; context = nothing) = Solution(context, io["coefs"])

save_solution(rf, (; obj = Solution(:dsge, [1.0, 2.0])))       # solution/obj.jld2, plain arrays
save_result_item(rf, "economy", Economy(0.99, 2.0, "Beta", true))
load_result_item(rf, "solution/obj", Solution; context = :dsge)
load_result_item(rf, "economy", Economy)
```

## Conveniences

Functions that save or load several items at once, or that know which type each path holds, belong
in the frontend's own code. TransitionFunctionIteration's `save_result(rf, result)` calls
`save_solution` and then `save_result_item` for each output of `solve_and_simulate`, and
`load_result(rf, :stats)` loads an item as TFI's types. A frontend can also ship
[`QueryShape`](@ref)s for its tables, so that its users query them without naming paths and columns.
