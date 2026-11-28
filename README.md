# OutputVault.jl

OutputVault stores the solutions and results of quantitative scientific model runs, records the
code that produced them, and lets you query results across runs.

For example, an experiment `v1` might compare variants `base` and `high_vol` on branch `main`.
Save each solution along with the parameters and policies needed to resume your work, then add
statistics, impulse responses or other results as you compute them. You can later compare the
same statistic across variants without loading their solutions.

```
<output_root>/<branch>/res-<experdef>-<variant>/
├── native.jld2       the solution as Julia objects (optional)
├── .provenance/      git_commit.txt  [git_staged.diff  git_unstaged.diff]
├── solution/         e.g. params/  policy.jld2
└── <result items>    e.g. stats/uncond.parquet  irf/ss/stats.parquet  notes.jld2
```

Tables are saved as Parquet files, which you can also read in Python, R, MATLAB or DuckDB.
NamedTuples group results into folders; other values are saved in JLD2 files. You choose the item
names and can [define how your own types are stored](https://www.vadimelenev.com/OutputVault.jl/stable/guide/frontends/).

## Installation

```julia
using Pkg
Pkg.add("OutputVault")
Pkg.add("Parquet2")   # table I/O; queries use DuckDB, included with OutputVault
```

Julia 1.12 or later; `using Parquet2` for tables.

## Example

Save a solution, add a summary table, and query its means. `mktempdir()` gives the example a fresh
output folder; use a permanent folder for your research runs.

```julia
using OutputVault, Parquet2

set_config!(Config(output_root = mktempdir(),
                   table_format = OutputVault.Formats.ParquetFormat()))

rf = RunHandle("base"; branch = "demo", experdef = "v1")
solution = (params = (α = 0.33, β = 0.96), policy = [1.0, 1.1, 1.2])
save_solution(rf, solution)                              # starts the run over, records the commit
save_result_item(rf, "stats/uncond", (variable = ["K", "C"], mean = [3.5, 1.2]))
stats = load_result_item(rf, "stats/uncond")             # a table with its metadata
stats.mean                                               # its column `mean`

shape = QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)
query_results(RunPattern(experdef = "v1"), shape; sample = :uncond, stat = :mean)
```

The query returns columns `branch, experdef, variant, sample, variable, stat, value`: one row per
selected cell. Add another variant with its own `RunHandle` and the same item paths to compare it
in the same query. A handle names a folder; making one does not save anything.

**Saving a solution replaces the whole run**, including any results saved previously. Use
`save_result_item` to add results to an existing solution.

For project work, omit `branch = "demo"` to use the active Julia project's git branch.
`save_solution` records that project's commit and any uncommitted changes. Pass a branch explicitly
when working outside a repository or on a detached HEAD; it chooses the output folder without
switching branches. Saving outside a repository warns and still works.

## Documentation

Start with the [quick start](https://www.vadimelenev.com/OutputVault.jl/stable/guide/quickstart/), then read about
[runs and storage](https://www.vadimelenev.com/OutputVault.jl/stable/guide/concepts/), [saving and loading](https://www.vadimelenev.com/OutputVault.jl/stable/guide/saving_loading/),
[table formats](https://www.vadimelenev.com/OutputVault.jl/stable/guide/tables/) and [queries](https://www.vadimelenev.com/OutputVault.jl/stable/guide/queries/).
To extend OutputVault, see [storing your own types](https://www.vadimelenev.com/OutputVault.jl/stable/guide/frontends/)
and [adding a table format](https://www.vadimelenev.com/OutputVault.jl/stable/guide/adding_formats/).

## Development

From a checkout of this repository, run the tests with:

```sh
julia --project -e 'using Pkg; Pkg.test()'
```

Build the documentation locally with:

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

## AI use

Parts of the code and most of the tests and documentation were written with Claude Code.
Everything was reviewed by the author.
