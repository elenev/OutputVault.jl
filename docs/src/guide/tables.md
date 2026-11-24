# Table Formats

Tables (TFI's simulations, moment tables and IRFs, or a type of your own whose writer calls
`write_table`) are stored through the configuration's *table format*, so that the choice of file format
belongs to the project and not to the code that produces a table. A table is written together with its
*metadata*: string key-value pairs that say what the table is and where it came from. Objects restore as
their own types from the metadata, so a format must keep file-level metadata for them. Values that are
not written as tables (see [Writing an Extension](@ref)) are saved with JLD2 whatever the table format.

## Parquet

```julia
using OutputVault, Parquet2
Config(; output_root = "...", table_format = OutputVault.Formats.ParquetFormat())
```

[`ParquetFormat`](@ref OutputVault.Formats.ParquetFormat) writes and reads Parquet files with Parquet2 (`.parquet`). Loading
Parquet2 loads the extension that implements it; without it, using the format fails with a message
that names the package to load. Parquet stores the metadata as file-level key-value pairs, and
DuckDB, pandas and Arrow read the files directly.

The keys in a file written by OutputVault:

| Key | Meaning |
|:--|:--|
| `outputvault.kind` | the storage kind, e.g. `TransitionFunctionIteration.MomentArray`, which selects the reader |
| `outputvault.part_of`, `outputvault.part_index` | for an object saved as several tables (moments by sample): the object and the position |
| `tfi.*` | the producer's own (TFI's kind, row key, endogenous states, provenance) |

## Another format

A format implements three functions for its type:

```julia
using OutputVault
import OutputVault: AbstractTableFormat, table_extension, write_table_file, read_table_file, required_package

struct MyFormat <: AbstractTableFormat end

table_extension(::MyFormat) = "myext"
required_package(::MyFormat) = "MyIOPackage"            # named in the error if its methods are missing

# write `table` (a Tables.jl source) to `path`, with its own metadata plus the entries of
# `meta::Dict{String,String}` as file-level metadata
write_table_file(::MyFormat, path, table, meta) = MyIOPackage.write(path, table; metadata = meta)

# a Tables.jl source whose file-level metadata DataAPI.metadata(source, key, default) reads
read_table_file(::MyFormat, path) = MyIOPackage.read(path)
```

Put the methods in a package extension of OutputVault triggered by the IO package, as
`OutputVaultParquet2Ext` is, and a user selects the format with `Config(; table_format = MyFormat())`
after loading the IO package. For a quick format without a package extension:

```julia
fmt = TableFormat(ext = "myext",
                  write = (path, table, meta) -> ...,
                  read  = path -> ...)
```

A format without file-level metadata (plain CSV) can store tables but cannot restore TFI's types
from them, because the kind is recorded in the metadata.
