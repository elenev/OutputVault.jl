# Quick Start

This page saves, adds to, loads, lists and queries runs made of plain Julia values and one type of
your own, with no model package. For a model package that stores its types through OutputVault, see
[Frontends](@ref); TransitionFunctionIteration's documentation shows one.

Suppose `v1` is a calibration experiment, `base` and `alt` are parameter choices, and each solution
will eventually have unconditional and conditional statistics. The names of those outputs are
yours: OutputVault needs no catalogue of them in advance.

Install OutputVault and Parquet2 as shown on the [home page](@ref OutputVault.jl). Run this page's
blocks in order in a Julia project inside a git repository. The branch and recorded commit come
from that project's repository. On a detached HEAD or outside a repository, pass `branch = "demo"`
to both handles below; without a repository, saving warns but works. The output under each block
is what the code printed when these docs were built in a temporary repository.

## Configure and name a run

```@example quickstart
using OutputVault, Parquet2, Tables

root = abspath("../outputs")       # your output folder
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

The solution starts the run: [`save_solution`](@ref) replaces whatever the run held before. It is
saved at the path `solution` by the storage rules: a NamedTuple is a folder, and so is the
NamedTuple `params`; a value that is not a table or a NamedTuple is a `.jld2` file
(`solution/params/α.jld2`, `solution/policy.jld2`). `.provenance/git_commit.txt`
holds the commit, and `native.jld2` holds the whole solution as Julia objects, for a fast reload with
the same code.

## Add results

```@example quickstart
save_result_item(rf, "stats/uncond", (variable = ["K", "C"], mean = [3.5, 1.2], std = [0.4, 0.1]))
save_result_item(rf, "stats/boom", (variable = ["K", "C"], mean = [3.9, 1.3], std = [0.3, 0.1]))
save_result_item(rf, "notes", (; text = "first try", converged = true))
list_run(rf)
```

Each [`save_result_item`](@ref) writes one value at a path chosen when the code runs. A NamedTuple of
equal-length vectors is a table, saved as a Parquet file; another NamedTuple is a folder; anything
else is a `.jld2` file. Saving at a path replaces what was there.
Saving `stats/boom` leaves `stats/uncond` alone; saving a whole `stats` folder replaces all samples.

## Load

```@example quickstart
stats = load_result_item(rf, "stats/uncond")
Tables.columns(stats).mean
```

The default `.jld2` writer stores a value under the key `"value"`. A folder of such files therefore
loads as a NamedTuple of Dicts:

```@example quickstart
load_result_item(rf, "notes")
```

To resume with the same Julia code, load the native solution:

```@example quickstart
saved = load_result_item(rf, "solution"; native = true)
saved.params.β, saved.policy
```

Loading returns data: a table as a [`StoredTable`](@ref OutputVault.Formats.StoredTable), a folder
as a NamedTuple of its items, a `.jld2` file as a Dict. Pass a type to get your own type back
([Your own type](#Your-own-type)).

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

The statistics and notes are gone: nothing in a run was computed from an earlier solution. Save
them again after a new solution.

## Your own type

A type of your own is stored through two methods. Here is a summary table that keeps a label in the
file's metadata:

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
instead, or `write_portable_jld2` and `read_portable_jld2` for its own layout inside a `.jld2` file ([Frontends](@ref)).
