# Querying with DuckDB

Saved TFI runs are Parquet files in a fixed layout, which DuckDB queries in place, from any language
it has a client for. OutputVault ships the SQL that does it: `sql/outputvault.sql`, whose path is
[`duckdb_sql_path`](@ref)`()`. It defines *table macros* that take the output root and return the
contents of all runs under it in long form. OutputVault itself does not depend on DuckDB: install
DuckDB for the language you query from.

The macros read the Parquet tables of the layout's components (`stats`, `errstats`, `params`, `irf`,
`simulation`) in the column layouts that TFI's types are stored in, described below. They do not
read JLD2 files, or tables of another format.

## Loading the macros

From Python (or the DuckDB command line), read the file at the path that
`OutputVault.duckdb_sql_path()` returns in Julia, or a copy of it:

```python
import duckdb
con = duckdb.connect()
con.execute(open("/path/to/outputvault.sql").read())
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

The tables they read: moment tables have a column of row names (`variable` for statistics, `equation`
for error statistics, `parameter` for parameters) and one numeric column per statistic; IRF tables have
the columns `__shock`, `__stat`, `__period` and one per variable; a simulation panel is read as it is.
TFI writes its types this way. A table of your own type is read by the macro of its component if it
has the same columns.

### Reading only what you need

The root may be a synced folder with online-only files, where a glob over every run would download
them all. Every macro takes named arguments that narrow the files that are read:

```sql
SELECT * FROM vault_stats('/root', branch_glob := 'main', experdef_glob := 'v1');
SELECT * FROM vault_stats('/root', economies := ['base', 'alt']);
```

- `branch_glob` (default `'**'`) and `experdef_glob` (default `'*'`): glob patterns on the folder
  names.
- `economies` (default `['*']`), for every macro but `vault_runs`: a list of economy glob patterns.
  Each pattern must match a saved component of some run, or DuckDB reports that no files match.

Without these arguments, a macro opens the files of every run under the root.

### Splitting the economy name

OutputVault imposes no convention on economy names. To split them into columns, pass five
positional arguments, the root, `branch_glob`, `experdef_glob`, a regular expression with one capture
group per part, and the parts' names. Every macro takes this form:

```sql
SELECT * FROM vault_stats('/root', '**', '*', '^([^_]+)(?:_(.+))?$', ['model', 'scheme'])
WHERE variable = 'K' AND stat = 'mean';
```

adds the columns `model` and `scheme` after `economy`, empty where a group does not match. This form
takes no `economies` list: it reads every economy that matches the globs.

## Moments from saved runs: `assemble_moments`

With DuckDB, Tables and TransitionFunctionIteration loaded, [`assemble_moments`](@ref) selects from the
saved runs the numbers that a set of TFI moments need:

```julia
using OutputVault, DuckDB, Tables, TransitionFunctionIteration
using TransitionFunctionIteration.Transformations: DiffLevel

moments = (std_K = SimulationMoment(:K; stat = :std),
           irf_C = ImpulseMoment(:C, :up, 2; transformation = DiffLevel()))

table = assemble_moments(root, moments; branch = "main", experdef = "v1",
                         economies = [:base, :alt], parameters = false)
```

The result is a column table with one row per number: `branch, experdef, economy, kind, group,
variable, stat, period, value`, with `kind` one of `simulation`, `impulse` and `parameter`. It is the
form for other languages to read.

What it holds:

- the statistics and IRF points that the moments name, including the inputs of calculated moments;
- by default, every saved parameter of each run as well (`kind = "parameter"`). `parameters = false`
  adds none, a collection of names adds those, and a `ParameterMoment` among the moments always fetches
  its own parameter;
- only runs that match `branch` and `experdef` (glob patterns, by default every branch and every
  experdef) and, if given, `economies`;
- for each kind of number, only the runs that saved its component: a run without IRFs has no
  `impulse` rows, and a run without statistics no `simulation` rows.

The table holds only the selected rows, but DuckDB still opens every file of the components it reads in
the matching runs. In a synced folder with online-only files, that downloads them: narrow `branch`,
`experdef` and `economies` to the runs you need.

## Naming runs: `split_by_economy`

[`split_by_economy`](@ref) turns the table into one entry per run, the form TFI's `getmoment` and
`compare_economies` read:

```julia
economies = split_by_economy(table; key = :economy, order = [:base, :alt])   # (base = ..., alt = ...)
getmoment(economies.base, moments.std_K)               # one economy
getmoment(economies, moments.irf_C, :alt, :base)       # across economies
compare_economies(moments, economies)                  # a MomentArray; the base is the first, base
```

A run is identified by its branch, experdef and economy. By default each entry is named by all three,
`<branch>__<experdef>__<economy>` (`main__v1__base`), so runs of different branches or experdefs never
mix. `key` asks for shorter names: `key = :economy` gives `base`, `key = (:experdef, :economy)` gives
`v1__base`. Characters other than letters, digits and `_` become `_`. If the shorter names are not
unique, because the table has `base` from two branches for example, `split_by_economy` throws an error
that lists the runs. Narrow `branch` and `experdef` in `assemble_moments`, as above, or use a longer
key.

`order` lists the entries to keep, by their names under `key`, in the order you want; a name that is
not in the table is an error. The order matters for comparisons: the first economy is the base. Without
`order`, entries come in the order of the table's rows, which is not a reliable choice of base.

A moment that cannot be read in an economy, because the run never saved that statistic, IRF or
parameter, is a `KeyError` that names the missing entry. Absent results are never read as zero.

For all steps at once:

```julia
compare_economies(moments, (:base, :alt), root; branch = "main", experdef = "v1")
```

reads the economies you name, names them by economy, and uses the first as the base. If `branch` and
`experdef` (by default every branch and experdef) match a name in more than one run, it is the same
error as above.

## Calculated moments and parameters

Impulse moments select their reference path with `basis = :uncond` by default, or a custom name
such as `ImpulseMoment(:C, :up, 2; transformation = DiffLevel(), basis = :control)`.
Only transformations that require a basis fetch that reference row; a level moment works even
when no baseline path was saved. This is the same behavior as reading an in-memory IRF.

Calculated moments, including `@CalculatedMoment` expressions, read from these entries as from any
source. `assemble_moments` selects the rows of every input of a calculated moment, so nothing extra is
specified for them:

```julia
mean(v) = SimulationMoment(v)
sd(v)   = SimulationMoment(v; stat = :std)

moments = (sd_K   = sd(:K),
           cv_K   = @CalculatedMoment(sd(:K) / mean(:K)),            # needs the `simulation` rows of K
           irf_per_beta = CalculatedMoment(nt -> nt.irf_C / nt.beta,
                                           (irf_C = ImpulseMoment(:C, :up, 2; transformation = DiffLevel()),
                                            beta  = ParameterMoment(:β))))

table = assemble_moments(root, moments; branch = "main", experdef = "v1", economies = [:base, :alt])
compare_economies(moments, split_by_economy(table; key = :economy, order = [:base, :alt]))
```
