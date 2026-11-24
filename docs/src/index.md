# OutputVault.jl

Research models produce a lot of output: solutions, simulations, moments, impulse responses.
Across git branches, experiment definitions and variants of the model, it is easy to lose track of
which code produced which numbers. OutputVault.jl gives every run one place on disk, the same
place for every project, and records the code version next to the results.

- **A fixed layout.** `<root>/<branch>/res-<experdef>-<economy>/<component>/<object>.<ext>`.
  Tools find an object in any run without knowing the project; see [Runs and the Layout](@ref).
- **Provenance.** The solution folder holds the git commit and, for a dirty repository, the diffs.
  Saving a new solution replaces the run's folder, so a folder never mixes results of two solutions.
- **Files other languages read.** TransitionFunctionIteration's solutions are plain arrays and metadata
  in HDF5-compatible files, and its simulations, moments and IRFs are Parquet tables, which Python, R,
  MATLAB or DuckDB read without Julia. Any other Julia value can be saved too: OutputVault stores it with
  JLD2 as a Julia object, which needs Julia and the same types to read.
- **Support for packages and formats.** Each is a package extension that loads when its package does:

| Extension | Loads with | Provides |
|:--|:--|:--|
| `OutputVaultTFIExt` | TransitionFunctionIteration | storage of TFI's solutions, steady states, simulations, moments, IRFs and interpolants |
| `OutputVaultParquet2Ext` | Parquet2 | `Formats.ParquetFormat`: tables as Parquet files |
| `OutputVaultDuckDBExt` | DuckDB, Tables, TransitionFunctionIteration | `assemble_moments` and `compare_economies` over saved runs |

Other solution packages and table formats can be supported the same way; see
[Writing an Extension](@ref).

## Quick start

With TransitionFunctionIteration, run from inside the model's git repository:

```julia
using OutputVault, Parquet2, TransitionFunctionIteration

set_config!(Config(
    output_root  = "/path/to/outputs",
    table_format = OutputVault.Formats.ParquetFormat(),     # TFI's tables as Parquet
))

result = solve_and_simulate(mdl)                            # mdl: your model; (; obj, stv, simseries, ...)
rf = RunHandle("base"; experdef = "v1")                     # branch: the current git branch
save_result(rf, result)                                     # a new run: needs the solution, obj
save_result(rf, (; params = collect_parameters(result.obj)))   # later: adds to the run
load(rf, :stats).stats                                      # the saved moments, as TFI's own type
```

The [Quick Start](@ref) page does the same with plain Julia values and no model package, and
[A Research Run, Start to Finish](@ref) follows a model from solve to comparison.

From any language with DuckDB, for example Python:

```python
import duckdb
sql = "/path/to/outputvault.sql"    # in Julia: using OutputVault; OutputVault.duckdb_sql_path()
con = duckdb.connect()
con.execute(open(sql).read())       # OutputVault's SQL macros
con.sql("SELECT * FROM vault_stats('/path/to/outputs', experdef_glob := 'v1')")
```

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/elenev/OutputVault.jl")
```

With SSH access to GitHub, `url = "git@github.com:elenev/OutputVault.jl.git"` works too. The package
requires Julia 1.12 or later. Add the packages of the extensions you use (`Parquet2` for tables,
`TransitionFunctionIteration` for its types, `DuckDB` and `Tables` for queries).

## Where to go next

- [Quick Start](@ref): saving, adding to, loading and querying a run, with no model package.
- [A Research Run, Start to Finish](@ref): one model through solve, save, a fresh-process reload, a
  warm start, a late result and a comparison, with the things that go wrong.
- [Runs and the Layout](@ref): what a run is and where each object goes.
- [Saving and Loading](@ref): configuration, `save_result`, replacing a run, `load`, finding runs.
- [TransitionFunctionIteration Objects](@ref): what is stored for TFI's types, and the file layouts.
- [Table Formats](@ref): how tables are stored and how to add a format.
- [Querying with DuckDB](@ref): the SQL macros, `assemble_moments` and naming runs.
- [Writing an Extension](@ref): storing the types of another package.
