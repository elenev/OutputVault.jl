# OutputVault.jl

Research models produce a lot of output: solutions, simulations, moments, impulse responses. Across
git branches, experiment definitions and variants of a model, it is easy to lose track of which code
produced which numbers. OutputVault.jl gives every run one folder, records the git state of the code
next to its solution, and queries results across runs.

- One folder per run: `<root>/<branch>/res-<experdef>-<variant>/`. A run starts with its solution;
  results computed from it are saved later, one item at a time, at paths chosen when the code runs.
- Provenance: the commit of the active project's repository and, for a dirty repository, its diffs.
  Saving a new solution replaces the run, so a run never mixes results of two solutions.
- Files other languages read: tables are Parquet files, which Python, R, MATLAB and DuckDB read
  without Julia. Other values are JLD2 files, as Julia objects or in a layout their package defines.
- Queries across runs with DuckDB, in Julia terms: [`query_results`](@ref) returns the cells of a
  family of tables in long form, reading only the files of the selected runs.
- No model package built in: a package (a frontend) says how its types are stored, and OutputVault
  does the reading and writing. TransitionFunctionIteration is one, through its package extension.

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
paths makes it part of the same query. No model integration is needed for plain Julia values or
Tables.jl tables; [Frontends](@ref) explains how a package restores its own types.

The explicit branch chooses a folder, without switching git branches. Normally omit it to use the
active project's branch. Provenance always records the active project's repository; without a
repository, saving warns and still works. Saving a solution replaces the whole run, including
previous result items.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/elenev/OutputVault.jl")
Pkg.add("Parquet2")
```

With SSH access to GitHub, `url = "git@github.com:elenev/OutputVault.jl.git"` works too. The package
requires Julia 1.12 or later. Tables need `using Parquet2`.

## Where to go next

- [Quick Start](@ref): saving, loading, listing and querying runs, with no model package.
- [Runs and Storage](@ref): runs, paths, the storage rules and provenance.
- [Saving and Loading](@ref): configuration, solutions, items, finding runs.
- [Frontends](@ref): storing the types of a package.
- [Table Formats](@ref): Parquet, and adding a format.
- [Queries](@ref): shapes, selections, and the SQL macros for other languages.
