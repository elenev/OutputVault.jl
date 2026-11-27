# OutputVault.jl

One folder for each run of a research model, with the git state of the code that produced it, and
queries across runs.

Model runs pile up across git branches, experiment definitions and variants of the model, and it is
easy to lose track of which code produced which numbers. OutputVault gives each run a folder, saves
its solution with the commit (and, if the repository was dirty, the diffs), and collects the results
computed from that solution as items saved at paths of your choice.

For example, an experiment `v1` might compare variants `base` and `high_vol` on branch `main`.
Your code computes each solution, then saves statistics for several samples and impulse responses
from several starting points. OutputVault keeps them together and reads the same statistic across
variants later, without loading the solutions. The solution can be any value needed to resume
your work; the names and contents of its result items are yours.

```
<output_root>/<branch>/res-<experdef>-<variant>/
├── native.jld2       the solution as Julia objects (optional)
├── .provenance/      git_commit.txt  [git_staged.diff  git_unstaged.diff]
├── solution/         the solution, e.g. obj.jld2  stv.jld2
└── <result items>    e.g. stats/uncond.parquet  irf/ss/stats.parquet  notes.jld2
```

- A run starts with its solution. Saving a new solution replaces the run, so results of different
  solutions never mix. Result items are saved afterwards, one at a time, in any order.
- Fixed storage rules: a Tables.jl table is a table file (Parquet), a NamedTuple a folder, anything
  else a `.jld2` file. Reading returns data; a type supplied by the caller turns it into objects.
- Plain files: Python, R, MATLAB and DuckDB read the tables without Julia code.
- Queries across runs with DuckDB, in Julia terms (`QueryShape`, `query_results`), reading only the
  files of the selected runs, and SQL macros for other languages (`sql/outputvault.sql`).
- No model package built in. A frontend package says how its types are stored (`to_storage`,
  `from_storage`, `write_portable_jld2`, `read_portable_jld2`); TransitionFunctionIteration is one, through its package
  extension.

## Example

This example needs no model package. It saves a small solution and two statistics, then queries
them. `mktempdir()` gives it a fresh output folder; use a permanent folder for your research runs.

```julia
using OutputVault, Parquet2

set_config!(Config(output_root = mktempdir(),
                   table_format = OutputVault.Formats.ParquetFormat()))

rf = RunHandle("base"; branch = "demo", experdef = "v1")
solution = (params = (α = 0.33, β = 0.96), policy = [1.0, 1.1, 1.2])
save_solution(rf, solution)                              # starts the run over, records the commit
save_result_item(rf, "stats/uncond", (variable = ["K", "C"], mean = [3.5, 1.2]))
load_result_item(rf, "stats/uncond")                     # a table with its metadata

shape = QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)
query_results(RunPattern(experdef = "v1"), shape; sample = :uncond, stat = :mean)
```

The query returns columns `branch, experdef, variant, sample, variable, stat, value`: one row per
selected cell. Add another variant with its own `RunHandle` and the same item paths to compare it
in the same query. A handle names a folder; making one does not save anything.

With TransitionFunctionIteration loaded, `save_result(rf, solve_and_simulate(mdl))` saves its
standard outputs and `compare_economies(moments, RunPattern(experdef = "v1"))` compares saved runs.

> Saving a solution replaces the run. `save_solution` deletes everything saved for the run before,
> so save again what you still need. `save_result_item` adds to the run.
>
> The branch and the git record come from the active project. `RunHandle` defaults to the branch
> of the repository holding the active Julia project, and `save_solution` records that repository's
> commit and diffs, whatever the working directory. Pass `branch = ...` on a detached HEAD, or when
> the active project is not in a git repository (the global environment, or `Pkg.test`'s temporary
> environment). The explicit `branch = "demo"` above chooses a folder; it does not check out a git
> branch or change which repository is recorded. Without a repository, saving warns and still works.

## Documentation

Start with the [executed quick start](docs/src/guide/quickstart.md), then read about
[runs and storage](docs/src/guide/concepts.md), [saving and loading](docs/src/guide/saving_loading.md),
[integrating your own types](docs/src/guide/frontends.md), [table formats](docs/src/guide/tables.md)
and [queries](docs/src/guide/queries.md). Build the documentation with

```
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/elenev/OutputVault.jl")
Pkg.add("Parquet2")   # table I/O; queries use DuckDB, included with OutputVault
```

Julia 1.12 or later; `using Parquet2` for tables.

## Compatibility

Runs saved with OutputVault 0.3 load without changes; runs saved with 0.1 do not. OutputVault 0.4
works with TransitionFunctionIteration 0.6 or later, whose extension stores TFI's types.

## Development

`julia --project=. -e 'using Pkg; Pkg.test()'` runs the tests, which save, load and query through a
temporary root and a throwaway git repository.
