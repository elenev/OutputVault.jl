# OutputVault.Formats.ParquetFormat: tables written and read with Parquet2, file metadata included.
# Parquet has no Symbol type: Symbol columns are written as strings and listed under
# SYMBOL_COLUMNS_KEY, so that they are read back as Symbols.
module OutputVaultParquet2Ext

using OutputVault.Formats: Formats, ParquetFormat, StoredTable, RESERVED_PREFIX
import OutputVault.Formats: write_table, read_table
using Parquet2, Tables

const SYMBOL_COLUMNS_KEY = RESERVED_PREFIX * "symbol_columns"

issymbolcol(v) = nonmissingtype(eltype(v)) === Symbol

function write_table(::ParquetFormat, path, table; metadata = Dict{String,String}())
    meta = Formats.table_metadata(table, metadata)
    cols = Tables.columntable(table)
    symbols = [string(k) for k in keys(cols) if issymbolcol(cols[k])]
    if !isempty(symbols)
        meta[SYMBOL_COLUMNS_KEY] = join(symbols, '\n')
    end
    cols = map(v -> issymbolcol(v) ? map(x -> ismissing(x) ? x : String(x), v) : v, cols)
    Formats.atomic_write(path) do tmp
        Parquet2.writefile(tmp, cols; metadata = meta)
    end
end

function read_table(::ParquetFormat, path)
    ds = Parquet2.Dataset(path)
    meta = Dict{String,String}(string(k) => string(v) for (k, v) in Parquet2.metadata(ds))
    symbols = Set(Symbol.(split(get(meta, SYMBOL_COLUMNS_KEY, ""), '\n'; keepempty = false)))
    filter!(kv -> !startswith(first(kv), RESERVED_PREFIX), meta)
    cols = Tables.columntable(ds)
    cols = NamedTuple{keys(cols)}(map(k -> k in symbols ? map(x -> ismissing(x) ? x : Symbol(x), cols[k]) : cols[k], keys(cols)))
    return StoredTable(cols, meta)
end

end # module
