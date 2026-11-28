# Table Formats

Set `table_format` in [`Config`](@ref) to choose how tables are saved. Each table becomes one file,
with its column names and file metadata. You can also read and write individual table files
directly through `OutputVault.Formats`, without configuring a run:

```@example tables
using OutputVault, OutputVault.Formats, Parquet2
write_table(ParquetFormat(), "t.parquet", (x = [1.0, 2.0], name = [:a, :b]); metadata = Dict("source" => "model"))
t = read_table(ParquetFormat(), "t.parquet")
t.x, t.name, metadata(t, "source")
```

## Loaded tables

[`read_table`](@ref OutputVault.Formats.read_table) and [`load_result_item`](@ref) return a table
file as a [`StoredTable`](@ref OutputVault.Formats.StoredTable), its columns with the file's
metadata. For a loaded table `t`:

| Expression | Value |
|:--|:--|
| `t.x` or `t[:x]` | the column `x` |
| `t[1]` | the first column |
| `keys(t)` | the column names |
| `metadata(t, "source")` | the metadata entry `source` |
| `metadata(t)` | all metadata, as a `Dict` |

A `StoredTable` is a Tables.jl table, so packages that accept such tables take it directly. To save
a table with metadata, make one from a NamedTuple of vectors and a `Dict{String,String}`, then pass
it to [`save_result_item`](@ref) or `write_table`:

```@example tables
table = StoredTable((x = [3.0],), Dict("source" => "survey"))
write_table(ParquetFormat(), "survey.parquet", table)
metadata(read_table(ParquetFormat(), "survey.parquet"))
```

## What every format keeps

- File-level string metadata: the table's own (`metadata`) merged with the `metadata`
  argument. Keys starting with `outputvault.` are reserved for the format's own entries: writing
  them is an error, and reading removes them, so the metadata read back is the metadata written.
  Column metadata is not kept.
- Column types: whatever the format's I/O package stores. A type it cannot store is an error from
  that package.
- Atomic writes: the file is written to a temporary name and then moved into place.

## Parquet

[`ParquetFormat`](@ref OutputVault.Formats.ParquetFormat) needs `using Parquet2`, which loads the
extension that reads and writes it. It keeps metadata in the Parquet file. Symbol columns are
stored as strings and restored as Symbols by the Julia reader. DuckDB, Python, R and MATLAB can
read the files directly.

Without Parquet2 loaded, writing or reading a Parquet table is a `MethodError` with a hint to load
`Parquet2`. The metadata restoration of Symbol columns applies to the Julia reader; queries return
text as strings.

To save tables in another file format, see [Adding a Table Format](@ref).
