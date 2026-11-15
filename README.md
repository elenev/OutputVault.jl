# OutputVault.jl

## Problem

Research model runs produce output across many git branches, experiment
definitions, and parameter configurations. It is easy to lose track of which
code version produced a given set of results, especially when runs are long and
the output directory accumulates results from many development cycles.

## Approach

OutputVault organizes outputs under a configurable root directory:
`branch/res-{experdef}-{economy}/{component}/{property}.{ext}`. Where each object goes is fixed
for every project (`LAYOUT`), so tools such as `compare_economies` find objects in any run:

| component    | properties                                          |
|:-------------|:----------------------------------------------------|
| `solution`   | `obj`, `stv`                                        |
| `stats`      | `stats` (the moments `compare_economies` compares)  |
| `errstats`   | `errstats`                                          |
| `simulation` | `simseries`, `errs`                                 |
| `irf`        | `irf`                                               |

Moments by sample (`describe(simseries).moments`) are saved one table per sample,
`stats/<sample>.<ext>`; each file records its position, so loading returns the samples in order.

Which objects are saved is chosen in each call: `save_result` saves the properties of the result
that the layout names, skipping missing or `nothing` ones and ignoring the rest. The solution
folder also receives the commit ID (`git_commit.txt`) and, for a dirty repository, the staged
and unstaged diffs (`git_staged.diff`, `git_unstaged.diff`, including untracked files). The
diffs are computed without touching the repository's index.

The solution is saved in two formats by default (`solution_format = (:portable, :native)`).
The native copy, `solution/res.jld2`, holds the solution's objects exactly as they are in Julia:
quick to load, but it needs code compatible with the code that wrote it, so it is meant for work
done soon after the solve. The portable copy is one file per object in a documented layout of
plain data, meant for long-term storage. Other components are always portable.

Portable objects are stored by type. With TransitionFunctionIteration loaded, a
`ModelSolution` goes to an HDF5-compatible JLD2 file of plain arrays and metadata, a
`SteadyState` to plain data, and simulations, error panels, moment tables and IRFs to tables in a format the
project chooses, with their provenance in the file's metadata. Other objects are stored with
JLD2. Loading returns each object as its own type.

Project settings (output root, table format, solution format) are set in a `Config` struct. For library authors who need more flexibility, the
`AbstractConfig` interface allows dispatch-based customization. The active
config is registered globally via `set_config!`, typically in the host
package's `__init__`, so downstream code calls `save_result` and `load`
without threading a config argument through the call stack.

## Installation

```julia
using Pkg
Pkg.add(url="git@github.com:elenev/OutputVault.jl.git")
```

## Saving results

Configure the vault in your package's `__init__` (or at the top of a script):

```julia
import OutputVault

function __init__()
    OutputVault.set_config!(OutputVault.Config(
        output_root     = "/path/to/outputs",
        table_format    = OutputVault.Formats.ParquetFormat(),   # needs `using Parquet2`
        solution_format = (:portable, :native),   # default; or :portable or :native alone
    ))
end
```

Then save a result whose properties are named in the layout:

```julia
using OutputVault

rb = RunHandle("baseline")               # branch defaults to current git branch
save_result(rb, (; obj, stv, stats, errstats, simseries, errs))   # everything
save_result(rb, (; obj, stv, stats, errstats))                    # without the simulation
```

A save that includes solution objects replaces the run's folder: everything saved earlier for
that run is deleted first, so the folder never mixes results of different solutions. Saves
without solution objects (e.g. IRFs computed later) add to the folder.

`save_result` warns (or errors, if `dirty_repo_check=:error`) when the
repository has uncommitted changes, and stores the diffs alongside the commit
ID in the solution folder.

Tables need a `table_format`. Built-in formats are in `OutputVault.Formats` and load with their
IO package (`ParquetFormat`, with `using Parquet2`). Other formats implement the contract of
`AbstractTableFormat` (`table_extension`, `write_table_file`, `read_table_file`), or are given as
functions with `TableFormat(; ext, write, read)`. TFI's tables restore as their own types only
from formats that keep file-level metadata.

## Loading results

```julia
rb = RunHandle("baseline")
sol  = load(rb, :solution)     # native copy: NamedTuple (obj = ModelSolution, stv = SteadyState)
sol  = load(rb, :solution; solution_format = :portable, model = MyModel)   # portable copy
stat = load(rb, :stats)        # NamedTuple of the saved properties: (stats = ...,)
```

To load from a specific branch or experiment definition:

```julia
rb = RunHandle("baseline"; branch="feature-x", experdef="highrisk")
sol = load(rb, :solution)
```

A portable load needs `model`: a model, compared with the stored metadata, or a model type, to
rebuild the model from the stored metadata with `model_from_metadata`. Single portable files can
be read directly with `load_solution(path, model)` and `load_steadystate(path, model)`.

Components saved by OutputVault 0.1 (one `{component}.jld2` file per component) still load.

## Querying outputs with DuckDB

`sql/outputvault.sql` (path: `duckdb_sql_path()`) defines DuckDB table macros over an output
root, for analysis in any language with a DuckDB client. They take the root as an argument, so
the file is the same on every machine:

| macro                    | columns                                                       |
|:-------------------------|:--------------------------------------------------------------|
| `vault_stats(root)`      | `branch, experdef, economy, sample, variable, stat, value`    |
| `vault_errstats(root)`   | `branch, experdef, economy, equation, stat, value`            |
| `vault_params(root)`     | `branch, experdef, economy, parameter, value`                 |
| `vault_irf(root)`        | `branch, experdef, economy, shock, stat, period, variable, value` |
| `vault_simulation(root)` | `branch, experdef, economy`, then the panel's columns         |
| `vault_runs(root)`       | `branch, experdef, economy`                                   |

Every macro takes the named arguments `branch_glob` (default `'**'`) and `experdef_glob`
(default `'*'`), glob patterns that narrow the files that are read; with a synced root of
online-only files this keeps downloads to the runs you ask for:

```sql
SELECT * FROM vault_stats('/path/to/output_root', branch_glob := 'houseshock', experdef_glob := '20261114');
```

The run identity comes from the folder names, so `experdef` must not contain `-` (`RunHandle`
enforces it); `economy` may contain anything. OutputVault imposes no convention on economy names.
To split them into columns, pass all five arguments, the last two a regex with one group per part
and the parts' names:

```sql
SELECT * FROM vault_stats('/path/to/output_root', '**', '*', '^([^_]+)(?:_(.+))?$', ['model', 'scheme'])
WHERE variable = 'K' AND stat = 'mean';
```

Python: `con.execute(open(path).read())`. DuckDB.jl runs one statement per call:

```julia
using DuckDB, OutputVault
con = DBInterface.connect(DuckDB.DB)
foreach(s -> DBInterface.execute(con, s), duckdb_statements())
DBInterface.execute(con, "SELECT * FROM vault_stats('$root')")
```

## Storing other packages' types

A package can have its types stored in formats of its own: define `OutputVault.storage_kind`
for them (a namespaced string), `OutputVault.write_object` methods that write through
`OutputVault.write_table` or `OutputVault.jld2_record` (which record the kind), and
`OutputVault.read_kind` methods that restore them. The TransitionFunctionIteration extension is
built this way.

## Moments of saved runs (DuckDB and TransitionFunctionIteration loaded)

`assemble_moments(root, moments; branch, experdef, economies)` reads the statistics that TFI
moment specifications (`SimulationMoment`, `ImpulseMoment`) name from the saved runs, with one
DuckDB query per kind of moment, and returns the long table that TFI's
`compare_economies(moments, economy_names, table)` reads. `compare_economies(moments,
economy_names, root; branch, experdef)` does both steps. The model's parameters are saved in the
`params` component: `save_result(rf, (; params = collect_parameters(obj)))`; the default takes
every scalar real or Boolean field of the model.

The `recursions` component holds interpolants computed at a solution's policies (`claims`, `welfare`,
one file each, `recursions/<name>.jld2`, with their grid so they load without the solution). Saving
them never touches the solution component, so they can be computed and saved later.

