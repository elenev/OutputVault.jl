# OutputVault.jl

One place on disk for the results of every run of a research model, the same place for every
project, with the code that produced them recorded next to them.

Model runs pile up across git branches, experiment definitions and variants of the model, and it is
easy to lose track of which code produced which numbers. OutputVault gives each run a folder,
saves a solution, its simulation, moments and impulse responses into it in plain files, and
records the git commit (and, if the repository was dirty, the diffs) with the solution.

```
<output_root>/<branch>/res-<experdef>-<economy>/
├── solution/     obj.jld2  stv.jld2  res.jld2  git_commit.txt  [git_*.diff]
├── stats/        uncond.parquet            moments by sample
├── errstats/     errstats.parquet          equation errors
├── simulation/   simseries.parquet  errs.parquet
├── irf/          irf.parquet  irf_paths.parquet
├── params/       params.parquet            the model's scalar parameters
└── recursions/   claims.jld2  welfare.jld2
```

What makes it useful:

- **The layout is fixed.** Every project and every user has the same components and objects, so
  tools find results in any run without knowing the project.
- **A folder is one solution.** Saving a new solution replaces the run's folder, so results of
  different solutions never mix. Everything else can be added to a run later.
- **Plain files.** Solutions are plain arrays and metadata in HDF5-compatible files; tables are
  Parquet with metadata that says what they are and where they came from. Python, R, MATLAB and
  DuckDB read them without Julia code, and a SQL layer queries all runs at once.
- **Provenance.** The solution folder holds the commit id and the staged and unstaged diffs
  (including untracked files), computed without touching the repository's index.
- **Light, extensible core.** The core knows nothing about particular model packages or file formats.
  Each is a package extension that loads with its package.

| Extension | Loads with | Provides |
|:--|:--|:--|
| `OutputVaultTFIExt` | TransitionFunctionIteration, StaticArrays, StructArrays | storage of TFI's solutions, steady states, simulations, moments, IRFs and interpolants |
| `OutputVaultParquet2Ext` | Parquet2 | `Formats.ParquetFormat`: tables as Parquet files |
| `OutputVaultDuckDBExt` | DuckDB, Tables, TransitionFunctionIteration | `assemble_moments`, `compare_economies` over saved runs |

Another solution package or table format adds its own extension through the same interfaces
(`storage_kind`, `write_object`, `read_kind`; `AbstractTableFormat`); see the documentation.

## Example

The configuration, run identity and saving are independent of any model package:

```julia
using OutputVault, Parquet2

set_config!(Config(
    output_root  = "/path/to/outputs",
    table_format = OutputVault.Formats.ParquetFormat(),
))

rf = RunHandle("base"; experdef = "v1")        # branch: the current git branch
save_result(rf, (; obj, stats))                # whatever the layout names; run inside a git repository
save_result(rf, (; irf))                       # later: adds to the run
load(rf, :stats).stats                         # NamedTuple of the saved objects, each as its own type
```

The documentation's Quick Start runs this with a tiny table type, no model needed, including a
DuckDB query. With TransitionFunctionIteration, the result of `solve_and_simulate` is already in the
right shape:

```julia
using TransitionFunctionIteration
result = solve_and_simulate(mdl)
save_result(rf, merge(result, (; params = collect_parameters(result.obj))))   # TFI's collect_parameters
```

Then, from any language with DuckDB (the macros are `sql/outputvault.sql`):

```sql
SELECT economy, variable, value
FROM vault_stats('/path/to/outputs', experdef_glob := 'v1')
WHERE sample = 'uncond' AND stat = 'mean';
```

> **Load what you use.** Extensions activate when their packages are loaded: `using Parquet2` for
> tables, `using TransitionFunctionIteration` (with StaticArrays and StructArrays, which it loads) for
> TFI's types, `using DuckDB, Tables` for `assemble_moments`. A missing one shows up as a message that
> names the package or a method that does not exist; the documentation has a troubleshooting table.
>
> **Saving a solution replaces the run's folder.** A `save_result` with `obj` or `stv` first deletes
> everything saved for that run (simulation, statistics, IRFs, parameters, recursions), so re-save
> what you still need. Saves without them add to the run.
>
> **Branch and git record come from the working directory.** `RunHandle` defaults to the current
> branch of the repository the process runs in, and `solution/` records that repository's commit and
> diffs, not those of the output root or the model. Start Julia from the model's repository or pass
> `branch = ...`.

Then, from any language with DuckDB (the macros are `sql/outputvault.sql`):

```sql
SELECT economy, variable, value
FROM vault_stats('/path/to/outputs', experdef_glob := 'v1')
WHERE sample = 'uncond' AND stat = 'mean';
```

## Documentation

A model-free quick start, a step-by-step lifecycle with a real model (solve and save, fresh-process
reload, warm start, late results, comparison),
guides on the layout, saving and loading, TransitionFunctionIteration objects and file layouts, table
formats, DuckDB, and writing an extension, and the API reference, are in `docs/`. Build them with

```
julia --project=docs docs/make.jl
```

## Installation

```julia
using Pkg
Pkg.add(url = "git@github.com:elenev/OutputVault.jl.git")
```

Julia 1.12 or later. Add the packages of the extensions you use.

## Status

Version 0.2.0, not yet released. The file layouts are versioned: a solution file records its schema
version and the reader accepts only the current one. Components saved by OutputVault 0.1 (one
`<component>.jld2` file each) still load.

## Development

`julia --project=. -e 'using Pkg; Pkg.test()'` runs the tests, which save and load every supported
type through a temporary root and a throwaway git repository. `CLAUDE.md` has the maintainer notes.
