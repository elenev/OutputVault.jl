# Table Formats

Tables are written in the format of the configuration (`Config(; table_format)`), one file per table.
Formats live in `OutputVault.Formats`, a submodule that uses nothing else from OutputVault, so it can
be used on its own:

```julia
using OutputVault.Formats, Parquet2
write_table(ParquetFormat(), "t.parquet", (x = [1.0, 2.0], name = [:a, :b]); metadata = Dict("source" => "model"))
t = read_table(ParquetFormat(), "t.parquet")     # a StoredTable: Tables.columns(t).x, DataAPI.metadata(t, "source")
```

## What every format keeps

- File-level string metadata: the table's own (`DataAPI.metadata`) merged with the `metadata`
  argument. Keys starting with `outputvault.` are reserved for the format's own entries: writing
  them is an error, and reading removes them, so the metadata read back is the metadata written.
  Column metadata is not kept.
- Column types: whatever the format's I/O package stores. A type it cannot store is an error from
  that package.
- Atomic writes: the file is written to a temporary name and then moved into place.

Reading returns a [`StoredTable`](@ref OutputVault.Formats.StoredTable), its columns with the
file's metadata.

## Parquet

[`ParquetFormat`](@ref OutputVault.Formats.ParquetFormat) needs `using Parquet2`, which loads the
extension that reads and writes it. It keeps the metadata in Parquet's key-value metadata. Parquet stores Symbols as strings; the format lists Symbol
columns in an entry of the metadata, and they come back as Symbols. DuckDB, Python, R and MATLAB read
the files directly.

Without Parquet2 loaded, writing or reading a Parquet table is a `MethodError` whose message says
`using Parquet2`.

## Adding a format

A format is a type with five methods:

```julia
using OutputVault.Formats
import OutputVault.Formats: extension, format_from_extension, write_table, read_table

struct MyFormat <: AbstractTableFormat end
extension(::MyFormat) = "myext"
format_from_extension(::Val{:myext}) = MyFormat()      # files *.myext are tables of this format

function write_table(::MyFormat, path, table; metadata = Dict{String,String}())
    meta = Formats.table_metadata(table, metadata)       # the table's metadata merged with the argument
    Formats.atomic_write(path) do tmp
        MyIOPackage.write(tmp, table; metadata = meta)
    end
end
read_table(::MyFormat, path) = Formats.StoredTable(MyIOPackage.columns(path), MyIOPackage.metadata(path))
```

`Base.iswritable(::MyFormat)` may return `false` for a format that is only read. `format_from_extension`
is what makes a file a table file when a run is read: define it only in the package that defines the
format. Queries ([Queries](@ref)) support the built-in formats.
