# OutputVault.jl

One folder for each run of a research model, with the git state of the code that produced it, and
queries across runs.

Model runs pile up across git branches, experiment definitions and variants of the model, and it is
easy to lose track of which code produced which numbers. OutputVault gives each run a folder, saves
its solution with the commit (and, if the repository was dirty, the diffs), and collects the results
computed from that solution as items saved at paths of your choice.

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
  `from_storage`, `write_jld2`, `read_jld2`); TransitionFunctionIteration is one, through its package
  extension.

## Example

```julia
using OutputVault, Parquet2

set_config!(Config(output_root = "/path/to/outputs",
                   table_format = OutputVault.Formats.ParquetFormat()))

rf = RunHandle("base"; experdef = "v1")                 # branch: the active project's git branch
save_solution(rf, (; obj = solution))                    # starts the run over, records the commit
save_result_item(rf, "stats/uncond", (variable = ["K", "C"], mean = [3.5, 1.2]))
load_result_item(rf, "stats/uncond")                     # a table with its metadata

shape = QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)
query_results(RunPattern(experdef = "v1"), shape; sample = :uncond, stat = :mean)
```

With TransitionFunctionIteration loaded, `save_result(rf, solve_and_simulate(mdl))` saves everything
and `compare_economies(moments, RunPattern(experdef = "v1"))` compares the saved runs.

> **Saving a solution replaces the run.** `save_solution` deletes everything saved for the run before,
> so save again what you still need. `save_result_item` adds to the run.
>
> **The branch and the git record come from the active project.** `RunHandle` defaults to the branch
> of the repository holding the active Julia project, and `save_solution` records that repository's
> commit and diffs, whatever the working directory. Pass `branch = ...` on a detached HEAD.

## Documentation

A quick start, guides on runs and storage, saving and loading, frontends, table formats and queries,
and the API reference are in `docs/`. Build them with

```
julia --project=docs docs/make.jl
```

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/elenev/OutputVault.jl")
```

Julia 1.12 or later; `using Parquet2` for tables.

## Compatibility

Runs saved with OutputVault 0.3 load without changes; runs saved with 0.1 do not. OutputVault 0.4
works with TransitionFunctionIteration 0.6 or later, whose extension stores TFI's types.

## Development

`julia --project=. -e 'using Pkg; Pkg.test()'` runs the tests, which save, load and query through a
temporary root and a throwaway git repository.
