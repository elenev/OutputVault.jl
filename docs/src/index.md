# OutputVault.jl

OutputVault stores the solutions and results of research model runs. Each run has a folder named
by its git branch, experiment and variant, with a record of the code that produced it.

Use it to save a solution, add results as you compute them, and compare those results across runs.
For example, you can collect unconditional statistics for several calibrations, then query the
mean of one variable in every calibration without loading the solutions.

Tables are stored in Parquet files, which you can also read in Python, R, MATLAB or DuckDB.
Other Julia values are stored in JLD2 files. You choose the names and organization of the results
within each run.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/elenev/OutputVault.jl")
Pkg.add("Parquet2")
```

Requires Julia 1.12 or later. Load Parquet2 when saving or loading tables.

## Quick example

```julia
using OutputVault, Parquet2

set_config!(Config(output_root = mktempdir(),            # use a permanent folder for real runs
                   table_format = OutputVault.Formats.ParquetFormat()))

rf = RunHandle("base"; branch = "demo", experdef = "v1")
solution = (params = (α = 0.33, β = 0.96), policy = [1.0, 1.1, 1.2])
save_solution(rf, solution)                                # starts the run over
save_result_item(rf, "stats/uncond", (variable = ["K", "C"], mean = [3.5, 1.2]))
load_result_item(rf, "stats/uncond")                       # the table, with its metadata

shape = QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)
query_results(RunPattern(experdef = "v1"), shape; stat = :mean)   # every run of v1, in long form
```

The query returns one row per selected cell, with columns
`branch, experdef, variant, sample, variable, stat, value`. Saving another variant at the same item
paths makes it part of the same query. Plain Julia values and Tables.jl tables can be saved
directly; for your own types, see [Storing Your Own Types](@ref).

The explicit branch chooses a folder, without switching git branches. Normally omit it to use the
active project's branch. Provenance always records the active project's repository; without a
repository, saving warns and still works. Saving a solution replaces the whole run, including
previous result items.

## Where to go next

- [Quick Start](@ref): save, load and compare two runs.
- [Runs and Storage](@ref): runs, paths, the storage rules and provenance.
- [Saving and Loading](@ref): configuration, solutions, items, finding runs.
- [Storing Your Own Types](@ref): storage methods for your package's result types.
- [Table Formats](@ref): Parquet, and adding a format.
- [Queries](@ref): shapes, selections, and the SQL macros for other languages.
