# OutputVault.jl

Research models produce a lot of output: solutions, simulations, moments, impulse responses.
Across git branches, experiment definitions and variants of the model, it is easy to lose track of
which code produced which numbers. OutputVault.jl gives every run one place on disk, the same
place for every project, and records the code version next to the results.

- **A fixed layout.** `<root>/<branch>/res-<experdef>-<economy>/<component>/<object>.<ext>`.
  Tools find an object in any run without knowing the project; see [Runs and the Layout](@ref).
- **Provenance.** The solution folder holds the git commit and, for a dirty repository, the diffs.
  Saving a new solution replaces the run's folder, so a folder never mixes results of two solutions.
- **Plain files.** Solutions are plain arrays and metadata in HDF5-compatible files, tables are
  Parquet. A reader in Python, R, MATLAB or DuckDB needs no Julia code.
- **Extensions.** The core knows nothing about particular model packages or file formats. Each is a
  package extension that loads when its package does:

| Extension | Loads with | Provides |
|:--|:--|:--|
| `OutputVaultTFIExt` | TransitionFunctionIteration, StaticArrays, StructArrays | storage of TFI's solutions, steady states, simulations, moments, IRFs and interpolants; model parameters |
| `OutputVaultParquet2Ext` | Parquet2 | `Formats.ParquetFormat`: tables as Parquet files with file metadata |
| `OutputVaultDuckDBExt` | DuckDB, Tables, TransitionFunctionIteration | `assemble_moments` and `compare_economies` over saved runs |

Other solution packages and table formats extend the same interfaces; see
[Writing an Extension](@ref).

## Quick start

```julia
using OutputVault, Parquet2

set_config!(Config(
    output_root  = "/path/to/outputs",
    table_format = OutputVault.Formats.ParquetFormat(),     # tables need a format
))

rf = RunHandle("base"; experdef = "v1")                     # branch: the current git branch
save_result(rf, (; obj, stats))                             # run inside a git repository
save_result(rf, (; irf))                                    # later: adds to the run
load(rf, :stats).stats                                      # NamedTuple of the saved objects
```

The [Quick Start](@ref) page runs exactly this, with a tiny table type and no model package, and
queries the saved runs with DuckDB. With TransitionFunctionIteration, the result of `solve_and_simulate`
is already in the right shape:

```julia
using TransitionFunctionIteration
result = solve_and_simulate(mdl)
save_result(rf, merge(result, (; params = collect_parameters(result.obj))))   # TFI's collect_parameters
```

From any language with DuckDB, for example Python:

```python
import duckdb
con = duckdb.connect()
con.execute(open("outputvault.sql").read())    # the macros; the path is OutputVault.duckdb_sql_path()
con.sql("SELECT * FROM vault_stats('/path/to/outputs', experdef_glob := 'v1')")
```

## Installation

```julia
using Pkg
Pkg.add(url = "git@github.com:elenev/OutputVault.jl.git")
```

The package requires Julia 1.12 or later. Add the packages of the extensions you use
(`Parquet2` for tables, `TransitionFunctionIteration` for its types, `DuckDB` for queries).

## Where to go next

- [Quick Start](@ref): saving, adding to, loading and querying a run, with no model package.
- [A Research Run, Start to Finish](@ref): one model through solve, save, a fresh-process reload, a
  warm start, a late result and a comparison, with the things that go wrong.
- [Runs and the Layout](@ref): what a run is and where each object goes.
- [Saving and Loading](@ref): configuration, `save_result`, `load`, git provenance, finding runs.
- [TransitionFunctionIteration Objects](@ref): what is stored for TFI's types, and the file layouts.
- [Table Formats](@ref): how tables are stored and how to add a format.
- [Querying with DuckDB](@ref): the SQL macros and `assemble_moments`.
- [Writing an Extension](@ref): storing the types of another package.
