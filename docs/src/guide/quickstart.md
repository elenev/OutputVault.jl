# Quick Start

This page needs only OutputVault. It saves, extends, loads and replaces a run made of plain Julia
values. A second, optional part stores a type of your own as a Parquet table and queries it with
DuckDB. For the same steps with a real model, see [A Research Run, Start to Finish](@ref).

Run the code from inside a git repository: a saved solution records the repository's commit.

## Configure and name a run

<!-- doctest: process 1 -->
```julia
using OutputVault

root = "/path/to/outputs"
set_config!(Config(output_root = root))

rf = RunHandle("base"; experdef = "v1")       # branch: the current git branch
```

A run is the saved results of one economy. Its folder is `<root>/<branch>/res-v1-base/`, from the
three names in the [`RunHandle`](@ref): the git branch, the experiment definition (`experdef`) and the
economy ([Runs and the Layout](@ref)).

## Save a solution

<!-- doctest: process 1 -->
```julia
save_result(rf, (; obj   = (α = 0.33, β = 0.96),      # the "solution": any value
                   stats = (K = 3.5, C = 1.2)))
readdir(OutputVault.economy_folder(rf))              # ["solution", "stats"]
```

`save_result` saves the properties of its argument whose names the layout knows (`obj`, `stats` and
the others in [`LAYOUT`](@ref)), each in its own folder, and ignores other names. The first save of a
run must include the solution, `obj` or `stv`: saving other results needs a run that exists.

OutputVault has no writer of its own for a `NamedTuple`, so these values are saved as Julia objects
with JLD2 (`stats/stats.jld2`). Reading them back needs Julia and the same types. Packages that
OutputVault supports, such as TransitionFunctionIteration, store their types as plain arrays and
Parquet tables instead, which other languages read ([TransitionFunctionIteration Objects](@ref)).

## Add a result later

<!-- doctest: process 1 -->
```julia
save_result(rf, (; irf = (K = [0.0, 0.01],)))
readdir(OutputVault.economy_folder(rf))              # ["irf", "solution", "stats"]
```

A save without a solution adds to the run and leaves the solution alone. Saving an object again
replaces it.

## Load

<!-- doctest: process 1 -->
```julia
load(rf, :stats).stats                               # (K = 3.5, C = 1.2)
load(rf, :solution).obj                              # (α = 0.33, β = 0.96)
```

`load` takes a component (a folder of the run) and returns a `NamedTuple` of the objects saved in it.

## Saving a solution replaces the run

<!-- doctest: process 1 -->
```julia
save_result(rf, (; obj = (α = 0.33, β = 0.95)))
readdir(OutputVault.economy_folder(rf))              # ["solution"]
```

A save that includes `obj` or `stv` writes a new run folder holding only what it contains, then
puts it in place of the old one and deletes the old one. The statistics and the IRF are gone: nothing
in a run folder was computed from another solution. Save them again after a new solution.

`save_result` returns the folder that holds the new results. That is the run's folder, unless the
swap failed (on Windows, an open file can block it). Then a warning says where the new and the old
results are, and the return value is the temporary folder holding the new ones
([Replacing a run](@ref)).

## Optional: your own type as a table

To store a type as a table, so that DuckDB, Python or R can read it, tell OutputVault how. Here is a
table of summary statistics, with one row per variable:

<!-- doctest: process 1 -->
```julia
using Parquet2, Tables

struct Summary
    variable::Vector{String}
    mean::Vector{Float64}
    std::Vector{Float64}
end

# a Tables.jl table
Tables.istable(::Type{Summary}) = true
Tables.columnaccess(::Type{Summary}) = true
Tables.columns(s::Summary) = (variable = s.variable, mean = s.mean, std = s.std)

# how OutputVault stores and restores it
OutputVault.storage_kind(::Summary) = "Demo.Summary"
OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, s::Summary; provenance = Dict{String,String}()) =
    OutputVault.write_table(cfg, joinpath(dir, name), s)
OutputVault.read_kind(::Val{Symbol("Demo.Summary")}, source, path, fmt) =
    Summary(string.(Tables.getcolumn(source, :variable)),
            collect(Float64, Tables.getcolumn(source, :mean)), collect(Float64, Tables.getcolumn(source, :std)))
```

- `storage_kind` is a name recorded in the file. When the file is loaded, it selects the reader.
- `write_object` writes the object; `write_table` writes any Tables.jl table with the configuration's
  table format.
- `read_kind` rebuilds the object from the table read back.

Being a Tables.jl table is not enough by itself: without these methods, a table is saved with JLD2
like any other value. [Writing an Extension](@ref) has the details.

Tables need a table format in the configuration. Then save a new solution with the table:

<!-- doctest: process 1 -->
```julia
set_config!(Config(output_root = root, table_format = OutputVault.Formats.ParquetFormat()))

save_result(rf, (; obj   = (α = 0.33, β = 0.95),
                   stats = Summary(["K", "C"], [3.4, 1.19], [0.4, 0.1])))
load(rf, :stats).stats.mean                          # [3.4, 1.19]
```

The table is the file `stats/stats.parquet`. DuckDB reads it in place, from Julia or any other
language:

<!-- doctest: process 1 -->
```julia
using DuckDB
con = DBInterface.connect(DuckDB.DB)
foreach(s -> DBInterface.execute(con, s), duckdb_statements())     # load OutputVault's SQL macros
DBInterface.execute(con, "SELECT economy, variable, stat, value FROM vault_stats('$root') ORDER BY variable, stat")
```

`vault_stats` returns the `stats` tables of all runs under the root in long form, one row per number.
It reads Parquet tables with a `variable` column and one column per statistic, which is how
TransitionFunctionIteration stores its moments and how `Summary` is stored here
([Querying with DuckDB](@ref)).
