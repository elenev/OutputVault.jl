# Writing an Extension

OutputVault's core stores nothing but what its extensions teach it. A package that has its own types
to store, or a data format to store them in, extends three small interfaces. Everything below is
tested against the core with a producer type of its own; `OutputVaultTFIExt` is the full example.

## The producer interface

A *producer* is a package with types to store. For each type it defines a *storage kind*, a
namespaced string that is recorded in the file and selects the reader when the object is loaded:

| Function | Defined by the producer for its type | Purpose |
|:--|:--|:--|
| `OutputVault.storage_kind(x)` | `"MyPackage.Counter"` | the kind recorded in the file; default `nothing` (the object is stored with JLD2 as it is) |
| `OutputVault.write_object(cfg, dir, name, x; provenance)` | write `x` into `dir` as `name.<ext>` | the writer |
| `OutputVault.read_kind(Val(kind), ...)` | rebuild an object of that kind | the reader |

The core never names a producer's keys, and producers never name the core's: the producer writes
through two helpers that record the kind, and the reader receives the file.

### A type stored as plain data

```julia
using OutputVault, JLD2

struct Counter
    counts::Vector{Int}
end

OutputVault.storage_kind(::Counter) = "MyPackage.Counter"

function OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, x::Counter;
                                  provenance = Dict{String,String}())
    OutputVault.jld2_record(joinpath(dir, name * ".jld2"), x) do io     # records the kind, then calls f(io)
        io["counts"] = x.counts
    end
end

OutputVault.read_kind(::Val{Symbol("MyPackage.Counter")}, path; model = nothing) =
    Counter(JLD2.load(path, "counts"))
```

`provenance` holds strings that identify the run (the git commit id, for objects of the solution
component); write them into the file if the object should carry them. `model` is what the caller of
`load` supplied, for objects that store a model.

Now the object works wherever the layout has a property for it:

```julia
save_result(rf, (; claims = Counter([1, 2, 3])))
load(rf, :recursions).claims                          # Counter([1, 2, 3])
```

### A type stored as a table

Tables go through the configuration's [table format](@ref "Table Formats"), so the producer needs no
file format of its own:

```julia
using Tables, DataAPI

struct Series
    t::Vector{Float64}
    x::Vector{Float64}
end

Tables.istable(::Type{Series}) = true
Tables.columnaccess(::Type{Series}) = true
Tables.columns(s::Series) = (t = s.t, x = s.x)

OutputVault.storage_kind(::Series) = "MyPackage.Series"

OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, s::Series; provenance = Dict{String,String}()) =
    OutputVault.write_table(cfg, joinpath(dir, name), s)      # records the kind in the file's metadata

OutputVault.read_kind(::Val{Symbol("MyPackage.Series")}, source, path, fmt) =
    Series(collect(Float64, Tables.getcolumn(source, :t)), collect(Float64, Tables.getcolumn(source, :x)))
```

`write_table` writes the table with the metadata it publishes through DataAPI.jl (a type that
defines `DataAPI.metadata` for its table has it stored) plus the storage kind. `read_kind` receives the
table as read by the format, and its file-level metadata through `DataAPI.metadata(source, key, default)`.
An object saved as several tables, such as moments by sample, uses `write_table_parts` and gets back
a `NamedTuple` of its parts in order.

### Where to put the methods

Put them in a package extension of OutputVault, so that OutputVault stays light and the producer
needs no dependency on OutputVault, or in the producer itself, which then depends on OutputVault.
`OutputVaultTFIExt` is the first kind. In OutputVault's `Project.toml`:

```toml
[weakdeps]
MyPackage = "uuid..."

[extensions]
OutputVaultMyPackageExt = "MyPackage"
```

with the methods in `ext/OutputVaultMyPackageExt.jl`, in a module of that name. Choose storage kinds
that start with the producer's package name, so that kinds of different producers never clash.

## Model metadata

A producer that stores solutions of models needs a way to rebuild the model from the file.
Two functions are the hooks, with fallbacks for TFI's models in `OutputVaultTFIExt`:

- `model_metadata(mdl)` returns a `NamedTuple` of plain values (numbers, strings, symbols, numeric
  arrays) that describe the model; it is written into the solution file.
- `model_from_metadata(::Type{M}, metadata)` rebuilds a model of type `M` from it.

Overload both for a model type whose fields are not all plain data.

## A new table format

Formats are the other axis: see [Table Formats](@ref) for the three functions and the package
extension pattern (`OutputVaultParquet2Ext` is the model: eleven lines).

## What the layout does not do

The layout (`LAYOUT`) is fixed for every project: components and objects are not registered by
extensions. A producer's types go in the existing objects. A genuinely new component or object
is a change to OutputVault itself, which keeps every project's runs the same shape.

## Testing an extension

Test against a temporary output root and a throwaway git repository (the solution component records
the commit id): save a result with `dirty_repo_check = :ignore`, `load` it, and compare. OutputVault's
own tests do exactly this for a test-only producer type, in `test/test_save_load.jl`.
