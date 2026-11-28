"""
    OutputVault.Formats

Read and write Tables.jl tables with their file-level metadata, one file per table. These functions
can be used without configuring a run. Load the format's I/O package before calling `write_table`
or `read_table` (`using Parquet2` for [`ParquetFormat`](@ref)).

A format is a type `F <: AbstractTableFormat` with the methods [`extension`](@ref),
[`format_from_extension`](@ref), [`write_table`](@ref), [`read_table`](@ref) and, optionally,
[`iswritable`](@ref).
"""
module Formats

using Tables: Tables
using DataAPI: DataAPI, metadata, metadatakeys
using Random: randstring

export AbstractTableFormat, ParquetFormat, StoredTable
export extension, format_from_extension, write_table, read_table
export metadata, metadatakeys

"""
    AbstractTableFormat

Supertype of table file formats. See [`OutputVault.Formats`](@ref) for the methods a format defines.
"""
abstract type AbstractTableFormat end

"""
    extension(fmt) -> String

The file extension of the format's files, without the dot (`"parquet"`).
"""
function extension end

"""
    format_from_extension(::Val{ext}) -> Union{AbstractTableFormat, Nothing}

The format whose files have the extension `ext` (a Symbol, without the dot), or `nothing` if the
file is not a table file. A format's package defines the method for its own extension.
"""
format_from_extension(::Val) = nothing

"""
    write_table(fmt, path, table; metadata = Dict{String,String}())

Write a Tables.jl `table` to `path` with its own file-level metadata (`DataAPI.metadata`) merged
with `metadata`. The file is written to a temporary name and then moved into place, so readers see
either the old file or the new one. Column types the format cannot preserve are an error.
"""
function write_table end

"""
    read_table(fmt, path) -> StoredTable

Read the table at `path`, with its file-level metadata.
"""
function read_table end

"""
    iswritable(fmt) -> Bool

Whether tables can be written in the format (`false` for read-only formats). Default `true`. A
method of `Base.iswritable`.
"""
Base.iswritable(::AbstractTableFormat) = true

## Built-in formats

"""
    ParquetFormat()

Parquet files, written and read with Parquet2 (needs `using Parquet2`). File metadata are kept in
Parquet's key-value metadata. Symbol columns, which Parquet stores as strings, are listed in an
entry of that metadata and come back as Symbols. Other columns are passed to Parquet2 as they are;
a type it cannot store is an error from Parquet2.
"""
struct ParquetFormat <: AbstractTableFormat end
extension(::ParquetFormat) = "parquet"
format_from_extension(::Val{:parquet}) = ParquetFormat()

# the package whose extension implements a built-in format, for the hint below
format_package(::Type) = nothing
format_package(::Type{ParquetFormat}) = "Parquet2"

function missing_format_hint(io, exc, argtypes, kwargs)
    if !(exc.f in (write_table, read_table)) || isempty(argtypes)
        return
    end
    pkg = format_package(argtypes[1])
    if isnothing(pkg)
        return
    end
    print(io, "\n$(nameof(argtypes[1])) needs its package: `using $pkg`.")
end

## Tables with metadata

"""
    StoredTable(columns, metadata)

A table with file-level metadata: its columns (a NamedTuple of vectors) and a
`Dict{String,String}`. Reading a table file returns one, and saving one writes its metadata to the
file.

It is a Tables.jl column table (a `Tables.AbstractColumns`): `t.name` or `t[:name]` is the column
`name`, `t[i]` is the `i`th column and `keys(t)` lists the column names. `metadata(t, key)` reads
one metadata entry, `metadata(t)` all of them, and `metadatakeys(t)` lists their keys.
"""
struct StoredTable{C <: NamedTuple} <: Tables.AbstractColumns
    columns::C
    metadata::Dict{String,String}
end

# Tables.jl derives property access, indexing, iteration and display from these methods
Tables.columnnames(t::StoredTable) = keys(getfield(t, :columns))
Tables.getcolumn(t::StoredTable, i::Int) = getfield(t, :columns)[i]
Tables.getcolumn(t::StoredTable, name::Symbol) = getfield(t, :columns)[name]
Tables.schema(t::StoredTable) = Tables.schema(getfield(t, :columns))
Base.:(==)(a::StoredTable, b::StoredTable) =
    getfield(a, :columns) == getfield(b, :columns) && getfield(a, :metadata) == getfield(b, :metadata)

DataAPI.metadatasupport(::Type{<:StoredTable}) = (read = true, write = false)
DataAPI.metadatakeys(t::StoredTable) = keys(getfield(t, :metadata))
function DataAPI.metadata(t::StoredTable, key::AbstractString; style::Bool = false)
    v = getfield(t, :metadata)[key]
    return style ? (v, :default) : v
end
function DataAPI.metadata(t::StoredTable, key::AbstractString, default; style::Bool = false)
    v = get(getfield(t, :metadata), key, default)
    return style ? (v, :default) : v
end

## Helpers for format implementations

"""
    RESERVED_PREFIX

Metadata keys that start with `"outputvault."` belong to the formats. A table's own metadata may not
use them, and reading removes them, so the metadata read back is exactly the metadata written.
"""
const RESERVED_PREFIX = "outputvault."

"""
    table_metadata(table, metadata) -> Dict{String,String}

The table's own file-level metadata (`DataAPI.metadata`, values as strings) merged with `metadata`.
A key that starts with [`RESERVED_PREFIX`](@ref) is an `ArgumentError`.
"""
function table_metadata(table, metadata)
    out = Dict{String,String}()
    if DataAPI.metadatasupport(typeof(table)).read
        for k in DataAPI.metadatakeys(table)
            out[string(k)] = string(DataAPI.metadata(table, k))
        end
    end
    merge!(out, Dict{String,String}(string(k) => string(v) for (k, v) in metadata))
    for k in keys(out)
        if startswith(k, RESERVED_PREFIX)
            throw(ArgumentError("metadata key $k: keys starting with $RESERVED_PREFIX are reserved for OutputVault"))
        end
    end
    return out
end

"""
    atomic_write(f, path)

Call `f(tmp)` to write a temporary file next to `path`, then move it to `path`.
"""
function atomic_write(f, path)
    tmp = path * ".tmp-" * randstring(8)
    try
        f(tmp)
        Base.rename(tmp, path)
    finally
        rm(tmp; force = true)
    end
    return path
end

__init__() = Base.Experimental.register_error_hint(missing_format_hint, MethodError)

end # module Formats
