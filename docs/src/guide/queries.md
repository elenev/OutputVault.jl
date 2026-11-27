# Queries

[`query_results`](@ref) reads the table items of many runs at once with DuckDB and returns their
cells in long form. OutputVault writes the SQL; callers describe the tables in Julia terms.

## Shapes

A [`QueryShape`](@ref) describes one family of table items and fixes the columns of the output:

```julia
QueryShape(path_pattern; keys = (), column = :column, valuetype = Float64)
```

- `path_pattern` is an item path in which a level `{name}` is a placeholder: `"stats/{sample}"`
  matches `stats/uncond` and `stats/boom`, and the file's name becomes the value of an output column
  `sample`.
- `keys` are the table's columns that identify a row; they are copied to the output.
- The table's other columns become rows: their names go in the output column `column`, their cells
  in `value`, cast to `valuetype`.

`valuetype` may be `Float64` (the default), `Float32`, `Int64`, `Int32`, `Bool` or `String`. All output
column names must be distinct, including the run columns and `value`. Paths omit extensions;
each placeholder occupies a whole level. A fixed path such as `"params/params"` needs no placeholder.

Take the statistics table `stats/uncond.parquet` of a run:

```
variable  mean  std
c         0.71  0.02
k         2.90  0.11
```

With `QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)` the output is

```
branch  experdef  variant  sample  variable  stat  value
main    v1        base     uncond  c         mean  0.71
main    v1        base     uncond  c         std   0.02
main    v1        base     uncond  k         mean  2.90
main    v1        base     uncond  k         std   0.11
```

and in general `branch, experdef, variant, <placeholders…>, <keys…>, <column>, value`, as a column
table (a NamedTuple of vectors). Text columns are `String`s and numeric keys come back as stored.
Rows are ordered by run, placeholder values, row of the file and column of the table.

## Selections

```julia
shape = QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)
query_results(RunPattern(experdef = "v1"), shape; sample = [:uncond, :boom], variable = "r_*", stat = :mean)
```

For TFI's IRF table layout, where rows are identified by shock, statistic and period:

```julia
irfshape = QueryShape("irf/{start}/stats";
                     keys = (:__shock, :__stat, :__period), column = :variable)
query_results(RunPattern(experdef = "v1"), irfshape;
              start = :ss, __shock = :shock_5, __stat = :mean, __period = [2, 3], variable = :C)
```

The first argument is a [`RunPattern`](@ref) or a collection of [`RunHandle`](@ref)s. Each keyword
selects on an output column: a placeholder picks files, a key picks rows, and `column` picks the
table's columns. A selection is a value or a vector of values. A `String` with `*`, `?` or `[` is a
glob; any other value, and every `Symbol`, matches exactly. Globs apply to text; numeric keys take
exact values. A keyword that is not a placeholder, a key or the shape's `column` is an error that lists
the allowed names.

A run or a placeholder value without a matching file contributes no rows, and so does a cell that is
`missing`. Tables of different runs are combined by column name: a statistic that a run's table lacks
gives no rows for that run. A stored `NaN` stays `NaN`. A selected cell that cannot be cast to
`valuetype` is an error that names its column; select the columns that can be cast, or query with
`valuetype = String`.

## What is read

The runs and the placeholder selections are matched against folder and file names, so only the files
of the selected runs and placeholder values are opened, and in a synced folder (Dropbox) only those
are downloaded. Selections on keys and on `column` need those files to be read in full. Only files of
the configured table format are read; `.jld2` files are not queryable.

## SQL for other languages

`sql/outputvault.sql` ([`OutputVault.sql_path`](@ref)) holds DuckDB macros that read a list of table
files, for any language with DuckDB; [`vault_connection`](@ref) returns a Julia connection with them
loaded:

| Macro | Returns |
|:--|:--|
| `vault_table_parquet(files)` | the tables of a list of Parquet files, with `__file` and `__row` |
| `vault_metadata_parquet(files)` | their file-level metadata: `file, key, value` |
| `vault_split_variant(variant, regex, names)` | the variant split into named parts by a regex |

The caller finds the files by the layout of [Runs and Storage](@ref). In Python, the statistics of
all runs of experiment `v1`:

```python
import duckdb, pathlib
root = pathlib.Path("/path/to/outputs")
files = [str(f) for f in root.glob("**/res-v1-*/stats/*.parquet")]
files = [f for f in files if not any(p.startswith(".") for p in pathlib.Path(f).relative_to(root).parts)]
con = duckdb.connect()
con.execute(pathlib.Path("/path/to/outputvault.sql").read_text())  # file at OutputVault.sql_path() in Julia
if files:
    rows = con.execute("SELECT * FROM vault_table_parquet(?)", [files]).fetchall()
```

These macros return the stored columns plus `__file` and `__row`; unlike Julia's `query_results`,
they do not add run labels or turn the cells into long form. The example skips hidden staging and
trash folders. Find the files before querying, so DuckDB opens only the selected ones.

The variant follows no naming convention of OutputVault's; `vault_split_variant` applies the
project's, e.g. `UNNEST(vault_split_variant(variant, '^([a-z]+)(\d*)$', ['scheme', 'level']))` splits
`capbail85` into `capbail` and `85`.
