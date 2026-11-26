# OutputVault.Formats.ParquetFormat: tables written and read with Parquet2, file metadata included.
# Symbol columns are written as strings and listed under SYMBOL_COLUMNS_KEY, so that they are read
# back as Symbols. Files are read from bytes, so no file stays memory-mapped.
module OutputVaultParquet2Ext

using OutputVault.Formats: Formats, ParquetFormat, StoredTable, PARQUET_TYPES
import OutputVault.Formats: write_table, read_table
using Parquet2, Tables

const SYMBOL_COLUMNS_KEY = "outputvault.symbol_columns"

function write_table(::ParquetFormat, path, table; metadata = Dict{String,String}())
    meta = Formats.table_metadata(table, metadata)
    cols = Formats.plain_columns(table, PARQUET_TYPES)
    symbols = [string(k) for (k, v) in pairs(cols) if nonmissingtype(eltype(v)) === Symbol]
    if !isempty(symbols)
        meta[SYMBOL_COLUMNS_KEY] = join(symbols, '\n')
    end
    cols = map(v -> nonmissingtype(eltype(v)) === Symbol ? map(x -> ismissing(x) ? x : String(x), v) : v, cols)
    Formats.atomic_write(path) do tmp
        Parquet2.writefile(tmp, cols; metadata = meta)
    end
end

function read_table(::ParquetFormat, path)
    ds = Parquet2.Dataset(read(path))
    meta = Dict{String,String}(string(k) => string(v) for (k, v) in Parquet2.metadata(ds))
    symbols = Set(Symbol.(split(pop!(meta, SYMBOL_COLUMNS_KEY, ""), '\n'; keepempty = false)))
    cols = Tables.columntable(ds)
    cols = NamedTuple{keys(cols)}(map(keys(cols)) do k
        v = collect(cols[k])
        k in symbols ? map(x -> ismissing(x) ? x : Symbol(x), v) : v
    end)
    return StoredTable(cols, meta)
end

end # module
