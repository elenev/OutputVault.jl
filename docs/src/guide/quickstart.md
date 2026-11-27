# Quick Start

This tutorial saves two calibrations of a model, adds summary statistics and compares their means.
The experiment is called `v1`, and its two parameter choices are `base` and `alt`. The values are
illustrative; substitute your model's solutions and statistics when using this in your own work.

Install OutputVault and Parquet2 as shown on the [home page](@ref OutputVault.jl). Run this page's
blocks in order in a Julia project inside a git repository. The branch and recorded commit come
from that project's repository. On a detached HEAD or outside a repository, pass `branch = "demo"`
to both handles below. Saving outside a repository warns and still works.

## Configure and name a run

```@example quickstart
using OutputVault, Parquet2, Tables

root = abspath("../outputs")       # outside the repository, so saved runs leave it clean
set_config!(Config(output_root = root,
                   table_format = OutputVault.Formats.ParquetFormat()))   # tables as Parquet files

rf = RunHandle("base"; experdef = "v1")       # branch: the current git branch
```

A run is one folder, `<root>/<branch>/res-v1-base/`, named by the three parts of the
[`RunHandle`](@ref): the git branch, the experiment definition (`experdef`) and the variant
([Runs and Storage](@ref)).
Making the handle creates no files. Repeating this tutorial with the same root and names replaces
its previous runs; choose another experiment name to keep both versions.

## Save a solution

```@example quickstart
save_solution(rf, (; params = (α = 0.33, β = 0.96), policy = [1.0, 1.1, 1.2]))
list_run(rf)
```

[`save_solution`](@ref) starts the run, replacing anything saved under this run's name. Here,
`params` becomes a folder of parameter files, and the policy vector is saved in
`solution/policy.jld2`. The [Runs and Storage](@ref) guide explains how values become files and
folders.

The run also contains `.provenance/git_commit.txt`, with the code's commit, and `native.jld2`,
with a copy of the complete solution for reloading in Julia.

## Add results

```@example quickstart
save_result_item(rf, "stats/uncond", (variable = ["K", "C"], mean = [3.5, 1.2], std = [0.4, 0.1]))
save_result_item(rf, "stats/boom", (variable = ["K", "C"], mean = [3.9, 1.3], std = [0.3, 0.1]))
save_result_item(rf, "notes", (; text = "first try", converged = true))
list_run(rf)
```

Each [`save_result_item`](@ref) adds a result at the given path. The statistics are NamedTuples of
equal-length vectors, so they become Parquet tables; `notes` becomes a folder of JLD2 files.
Saving `stats/boom` again replaces that sample. Saving at `stats` replaces all samples in the folder.

## Load

```@example quickstart
stats = load_result_item(rf, "stats/uncond")
Tables.columns(stats).mean
```

Pass a type to read one value from a `.jld2` file:

```@example quickstart
load_result_item(rf, "notes/text", String)
```

Without a type, the file's raw contents load. The default `.jld2` writer stores a value under the
key `"value"`, so the `notes` folder loads as a NamedTuple of Dicts:

```@example quickstart
load_result_item(rf, "notes")
```

To resume with the same Julia code, load the native solution:

```@example quickstart
saved = load_result_item(rf, "solution"; native = true)
saved.params.β, saved.policy
```

The statistics load as a [`StoredTable`](@ref OutputVault.Formats.StoredTable), which you can read
through Tables.jl. To restore a custom result type, pass its type to `load_result_item`; see
[Your own type](#Your-own-type).

## Query across runs

A second run of the same experiment:

```@example quickstart
alt = RunHandle("alt"; experdef = "v1")
save_solution(alt, (; params = (α = 0.30, β = 0.96)))
save_result_item(alt, "stats/uncond", (variable = ["K", "C"], mean = [3.1, 1.1], std = [0.5, 0.2]))
find_runs(RunPattern(experdef = "v1"))
```

A [`QueryShape`](@ref) describes a family of tables: here every table under `stats/`, with the
sample name from the file name, rows identified by `variable`, and the other columns (the
statistics) turned into rows of a column `stat`:

```@example quickstart
shape = QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)
query_results(RunPattern(experdef = "v1"), shape; sample = :uncond, stat = :mean)
```

There are two rows per run, one for `K` and one for `C`. The `sample` column comes from the path,
`variable` from the table's key column, and `stat` from its column names. Without `stat = :mean`,
each variable also contributes a row for `std`. Select one key with `variable = :C`, or include
nested git branches with `RunPattern(branch = "**", experdef = "v1")`.

[`query_results`](@ref) reads only the files of the selected runs and samples, with DuckDB, and
returns a column table ([Queries](@ref)).

## Saving a solution starts the run over

```@example quickstart
save_solution(rf, (; params = (α = 0.33, β = 0.95)))
list_run(rf).items.path
```

The previous statistics and notes have been removed. Recompute and save the results for the new
solution, or use a different variant name to keep both solutions and their results.

## Your own type

For a custom summary type, define a Tables.jl interface and a `from_storage` method. This lets you
save it as a table and load it back as a `Summary`, retaining its label in the file's metadata:

```@example quickstart
using DataAPI

struct Summary
    label::String
    variable::Vector{String}
    mean::Vector{Float64}
end

# a Tables.jl table with a label in its file-level metadata
Tables.istable(::Type{Summary}) = true
Tables.columnaccess(::Type{Summary}) = true
Tables.columns(s::Summary) = (variable = s.variable, mean = s.mean)
DataAPI.metadatasupport(::Type{Summary}) = (read = true, write = false)
DataAPI.metadatakeys(::Summary) = ("label",)
DataAPI.metadata(s::Summary, ::AbstractString; style = false) = s.label

# rebuild it from the data OutputVault reads back
OutputVault.from_storage(::Type{Summary}, data; context = nothing) =
    Summary(DataAPI.metadata(data, "label"), Tables.columns(data).variable, Tables.columns(data).mean)

save_result_item(rf, "summary", Summary("baseline", ["K", "C"], [3.4, 1.19]))
s = load_result_item(rf, "summary", Summary)
(s.label, s.mean)
```

`Summary` is a table, so it is saved as one, with its metadata; `from_storage` turns the table read
back into a `Summary`. A type that is not a table can define `to_storage` to say what to save
instead, or `write_portable_jld2` and `read_portable_jld2` for its own layout inside a `.jld2` file ([Storing Your Own Types](@ref)).
