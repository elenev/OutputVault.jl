# Querying with DuckDB

Saved runs are plain Parquet files in a fixed layout, which DuckDB can query in place, from any
language it has a client for. OutputVault ships the SQL that does it: `sql/outputvault.sql`, whose
path is [`duckdb_sql_path`](@ref)`()`. It defines *table macros* that take the output root and return
the contents of all runs under it in long form. OutputVault does not depend on DuckDB.

## Loading the macros

Python (or the DuckDB command line):

```python
import duckdb
con = duckdb.connect()
con.execute(open("outputvault.sql").read())
con.sql("SELECT * FROM vault_stats('/path/to/outputs') WHERE variable = 'K' AND stat = 'mean'")
```

DuckDB.jl runs one statement per call; [`duckdb_statements`](@ref)`()` returns them:

```julia
using DuckDB, OutputVault
con = DBInterface.connect(DuckDB.DB)
foreach(s -> DBInterface.execute(con, s), duckdb_statements())
DBInterface.execute(con, "SELECT * FROM vault_runs('/path/to/outputs')")
```

Statements in the file are separated by `;` at the end of a line, so clients that split on that
work too. The file is the same on every machine: the root is an argument.

## The macros

Each takes the output root first and returns long-form data, with the run identity as columns:

| Macro | Columns after `branch, experdef, economy` |
|:--|:--|
| `vault_runs(root)` | (none: the saved runs) |
| `vault_stats(root)` | `sample, variable, stat, value` |
| `vault_errstats(root)` | `equation, stat, value` |
| `vault_params(root)` | `parameter, value` |
| `vault_irf(root)` | `shock, stat, period, variable, value` |
| `vault_simulation(root)` | the simulation panel's columns (`__run`, `__period`, the variables) |

`value` is a `DOUBLE`. For IRFs, `period` counts from 1, the starting period before the shock; the
baseline shock is `uncond`.

The column holding a moment table's row names is the *row key* of the `MomentArray` that wrote it
(`variable`, `equation` or `parameter`), which is why the macros differ in their second column.

### Reading only what you need

The root is usually a synced folder with online-only files, and a glob over every run would open them
all. Every macro takes named arguments that narrow the files that are read:

```sql
SELECT * FROM vault_stats('/root', branch_glob := 'main', experdef_glob := 'v1');
SELECT * FROM vault_stats('/root', economies := ['base', 'alt']);
```

- `branch_glob` (default `'**'`) and `experdef_glob` (default `'*'`): glob patterns on the folder
  names.
- `economies` (default `['*']`), for the macros over per-economy components: a list of economy glob
  patterns. Each pattern must match a saved component of some run, or DuckDB reports that no
  files match.

### Splitting the economy name

OutputVault imposes no convention on economy names. To split them into columns, pass all five
arguments, the last two a regular expression with one capture group per part and the parts' names:

```sql
SELECT * FROM vault_stats('/root', '**', '*', '^([^_]+)(?:_(.+))?$', ['model', 'scheme'])
WHERE variable = 'K' AND stat = 'mean';
```

adds the columns `model` and `scheme` after `economy`, empty where a group does not match.

## Moments from saved runs: `assemble_moments`

With DuckDB, Tables and TransitionFunctionIteration loaded, [`assemble_moments`](@ref) reads exactly
the statistics that a set of TFI moments need, from the saved runs, in one query per kind of moment:

```julia
using OutputVault, DuckDB, Tables, TransitionFunctionIteration
using TransitionFunctionIteration.Transformations: DiffLevel

moments = (std_K = SimulationMoment(:K; stat = :std),
           irf_C = ImpulseMoment(:C, :up, 2; transformation = DiffLevel()))

table = assemble_moments(root, moments; branch = "main", experdef = "v1",
                         economies = [:base, :alt])
```

The result is a column table with one row per (economy, number): `branch, experdef, economy, kind,
group, variable, stat, period, value`, with `kind` one of `simulation`, `impulse` and `parameter`. It is
the form for other languages to read. For TFI, [`split_by_economy`](@ref) turns it into one `Dict` per
economy, keyed by the rows that [`OutputVault.momentrows`](@ref) lists for a moment, and everything
TFI does with moments in memory works on those:

```julia
economies = split_by_economy(table)                    # (base = Dict(...), alt = Dict(...))
getmoment(economies.base, moments.std_K)               # one economy
getmoment(economies, moments.irf_C, :alt, :base)       # across economies
compare_economies(moments, economies)                  # a MomentArray
compare_economies(moments, (:base, :alt), root; branch = "main", experdef = "v1")   # all steps
```

Calculated moments, including `@CalculatedMoment` expressions, read from these as from any source.

Parameters are rows too, `kind = "parameter"`: `assemble_moments(...; parameters = true)` adds all
saved parameters (the `params` component) of the economies, `false` none and a collection of names
those, and a `ParameterMoment` among the moments always fetches its own:

```julia
moments = (beta = ParameterMoment(:β), std_K = SimulationMoment(:K; stat = :std))
table = assemble_moments(root, moments; economies = [:base])      # includes every saved parameter
```

Only runs that have the component are queried: an economy without saved statistics, without IRFs for
an impulse moment, or without parameters, is simply absent from those rows, and a moment that cannot be
read in an economy that is present is a `KeyError` that names it. Without `economies`, every run
matching `branch` and `experdef` is opened, which downloads online-only files in a synced folder.
