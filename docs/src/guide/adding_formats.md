# Adding a Table Format

A package can save tables in another file format. Define the format in your own package, which
depends on OutputVault and on the package that reads and writes the files, and on Tables.jl if it
converts tables with its functions.

A format is a type with four methods:

```julia
using OutputVault, OutputVault.Formats
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
function read_table(::MyFormat, path)
    # leave out the entries reserved for formats
    meta = filter(kv -> !startswith(first(kv), Formats.RESERVED_PREFIX), MyIOPackage.metadata(path))
    return StoredTable(MyIOPackage.columns(path), meta)           # columns: a NamedTuple of vectors
end
```

`Base.iswritable(::MyFormat)` may return `false` for a format that is only read. `format_from_extension`
is what makes a file a table file when a run is read: define it only in the package that defines the
format. Adding file I/O does not add a DuckDB reader: queries currently support Parquet only.
