# Storing Your Own Types

Use storage methods to let users save and reload your package's result types. The collection of
these methods, along with any save, load or query functions you provide, is called a *frontend*.

For an object stored as a table or folder, define `to_storage` to choose its representation and
`from_storage` to rebuild it. For an object stored in its own JLD2 file, you can define a layout
inside that file. Both approaches are illustrated below.

A type that already implements Tables.jl can be saved directly; add `from_storage` to restore it
as that type when loading.

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
values, so the raw values are under `"value"` in Dicts. The `from_storage` method above handles both:

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

To make a JLD2 file readable without your Julia type definitions, store ordinary arrays, numbers
and strings with `write_portable_jld2`. Define `read_portable_jld2` to reconstruct the object.
Leave `to_storage` at its default, which returns the object unchanged.

Here the saved solution belongs to a particular model. The reader checks the model identifier
passed through `context` before loading its coefficients:

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

Use the same methods with `write_object_file` and `read_object_file` to save an object outside a
run. The optional `native.jld2` solution copy stores the original Julia objects directly and needs
compatible Julia code to reload them.

## How conversion works

`to_storage` is applied to every member of a folder. On loading, `from_storage` is called for the
type passed to `load_result_item(rf, path, T)`. Its input is a
[`StoredTable`](@ref OutputVault.Formats.StoredTable) or a NamedTuple containing the folder's data.
Convert any nested members inside that method, as the `Economy` example does for its settings.
Loading a table or folder as a type without a `from_storage` method throws `MethodError`.

For JLD2 files, `read_portable_jld2` receives the open file instead. Its default reads the value
under `"value"`, without checking its type. Define your own reader to validate the contents or
rebuild the object from its stored parts.

Both readers receive the caller's `context` keyword. Use it for additional information needed to
rebuild the object, such as its model. A reader has access to the item's own data and this context;
save values that must be restored together as one item.

## Save, load and query functions for your package

Give frequently used result paths names in your package's API. A `save_run` function might save
the solution and several result items; a matching loader can pass the appropriate type when
loading each path. Define [`QueryShape`](@ref)s for your tables so users can select results without
having to remember their stored paths and column names.
