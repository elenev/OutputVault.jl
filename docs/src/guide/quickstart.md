# Quick Start

This page needs no model package. It saves and loads a run with a tiny stand-in for a producer: a
table type of three lines of methods, so that you see what OutputVault does and what a package that
stores its own types has to provide ([Writing an Extension](@ref)). For the same lifecycle with a real
model, see [A Research Run, Start to Finish](@ref).

Run it from inside a git repository: the solution folder records the repository's commit.

## A producer

```julia
using OutputVault, Parquet2, Tables

# summary statistics as a table: variable, mean, std
struct Summary
    variable::Vector{String}
    mean::Vector{Float64}
    std::Vector{Float64}
end
Tables.istable(::Type{Summary}) = true
Tables.columnaccess(::Type{Summary}) = true
Tables.columns(s::Summary) = (variable = s.variable, mean = s.mean, std = s.std)

OutputVault.storage_kind(::Summary) = "Demo.Summary"
OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, s::Summary; provenance = Dict{String,String}()) =
    OutputVault.write_table(cfg, joinpath(dir, name), s)
OutputVault.read_kind(::Val{Symbol("Demo.Summary")}, source, path, fmt) =
    Summary(string.(Tables.getcolumn(source, :variable)),
            collect(Float64, Tables.getcolumn(source, :mean)), collect(Float64, Tables.getcolumn(source, :std)))
```

The kind `"Demo.Summary"` is written into the file and selects the reader when the object is loaded.
Objects without a kind are stored with JLD2 as they are.

## Configure and save

```julia
root = "/path/to/outputs"
set_config!(Config(output_root = root, table_format = OutputVault.Formats.ParquetFormat()))

rf = RunHandle("base"; experdef = "v1")                  # branch: the current git branch

save_result(rf, (; obj = (α = 0.33, β = 0.96),           # the "solution": any object
                   stats = Summary(["K", "C"], [3.5, 1.2], [0.4, 0.1])))
readdir(OutputVault.economy_folder(rf))                  # ["solution", "stats"]
```

The run is `<root>/<branch>/res-v1-base/`. `obj` and `stats` are two of the objects the layout knows
([Runs and the Layout](@ref)); the table went through the configuration's table format, as a Parquet file.

## Add a result later

```julia
save_result(rf, (; irf = Summary(["K", "C"], [0.0, 0.01], [0.0, 0.0])))
readdir(OutputVault.economy_folder(rf))                  # ["irf", "solution", "stats"]
```

A save without a solution adds to the run and leaves the solution alone.

## Load

```julia
load(rf, :stats).stats.mean                              # [3.5, 1.2]
load(rf, :solution).obj                                  # (α = 0.33, β = 0.96)
```

`load` returns a `NamedTuple` of the objects that were saved in a component, each restored as its own
type.

## Saving a solution replaces the run

```julia
save_result(rf, (; obj = (α = 0.33, β = 0.95)))
readdir(OutputVault.economy_folder(rf))                  # ["solution"]
```

A save that includes `obj` or `stv` deletes everything saved for the run first, so that nothing in the
folder was computed from another solution. The statistics and the late result are gone: save them again.

## Query every run with DuckDB

```julia
save_result(rf, (; stats = Summary(["K", "C"], [3.4, 1.19], [0.4, 0.1])))

using DuckDB
con = DBInterface.connect(DuckDB.DB)
foreach(s -> DBInterface.execute(con, s), duckdb_statements())     # load the macros
DBInterface.execute(con, "SELECT economy, variable, stat, value FROM vault_stats('$root') ORDER BY variable, stat")
```

`vault_stats` reads the `stats` tables of all runs under the root in long form, from any language with
DuckDB ([Querying with DuckDB](@ref)); a table with a `variable` column and one column per statistic is what it
expects.
