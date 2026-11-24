# Writing an Extension

Without help, OutputVault saves any value with JLD2, as a Julia object. To store a package's types in
files that other languages read (plain arrays, tables), or to store tables in another file format,
add methods to OutputVault's interfaces. `OutputVaultTFIExt`, which stores TransitionFunctionIteration's
types, is a complete example.

## The producer interface

A *producer* is a package with types to store. For each type it defines a *storage kind*, a
string starting with the package's name that is recorded in the file and selects the reader when the
object is loaded, plus a writer and a reader:

| Function | Defined by the producer for its type | Purpose |
|:--|:--|:--|
| `OutputVault.storage_kind(x)` | `"MyPackage.Counter"` | the kind recorded in the file; default `nothing` |
| `OutputVault.write_object(cfg, dir, name, x; provenance)` | write `x` into `dir` as `name.<ext>` | the writer; default: JLD2, `name.jld2` |
| `OutputVault.read_kind(Val(kind), ...)` | rebuild an object of that kind | the reader |

Without a `write_object` method for its type, an object is saved with JLD2 as a Julia object, whatever
else it is: a Tables.jl table is not written as a table unless its `write_object` calls `write_table`.
The writer uses one of two helpers, `jld2_record` for plain data and `write_table` for tables, which
record the kind; the reader receives the file.

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

See [Table Formats](@ref) for the functions a format implements and how to put them in a package
extension; `OutputVaultParquet2Ext` is a short example.

## What the layout does not do

The layout (`LAYOUT`) is fixed for every project: components and objects are not registered by
extensions. A producer's types go in the existing objects. A genuinely new component or object
is a change to OutputVault itself, which keeps every project's runs the same shape.

## Testing an extension

Test against a temporary output root and a throwaway git repository (a saved solution records the
commit id): save a result with `dirty_repo_check = :ignore`, `load` it, and compare it with the
original. A result other than a solution needs a run to add to, so save a solution first.
