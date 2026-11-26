"""
    OutputVault.Formats

Table file formats: how a Tables.jl table and its file-level metadata are written to one file and
read back. Self-contained (it uses nothing else from OutputVault). Each built-in format needs its
I/O package loaded (`using Parquet2` for [`ParquetFormat`](@ref)), which loads the package
extension with its `write_table` and `read_table` methods.

A format is a type `F <: AbstractTableFormat` with the methods [`extension`](@ref),
[`format_from_extension`](@ref), [`write_table`](@ref), [`read_table`](@ref) and, optionally,
[`iswritable`](@ref).
"""
module Formats

using Tables: Tables
using DataAPI: DataAPI
using Dates: Date, DateTime
using Random: randstring

export AbstractTableFormat, ParquetFormat, StoredTable
export extension, format_from_extension, write_table, read_table

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

Read the table at `path` into memory, with its file-level metadata. No file handle stays open.
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
entry of that metadata and come back as Symbols. Column types: `Float64`, `Float32`, `Int64`,
`Int32`, `Bool`, `String`, `Symbol`, `Date`, `DateTime`, each optionally with `missing`.
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

## Tables read into memory

"""
    StoredTable

A table read from a file: its columns (a NamedTuple of vectors) and its file-level metadata (a
`Dict{String,String}`). It is a Tables.jl column table, and `DataAPI.metadata` reads the metadata.
"""
struct StoredTable{C <: NamedTuple}
    columns::C
    metadata::Dict{String,String}
end

Tables.istable(::Type{<:StoredTable}) = true
Tables.columnaccess(::Type{<:StoredTable}) = true
Tables.columns(t::StoredTable) = getfield(t, :columns)
Tables.getcolumn(t::StoredTable, i::Int) = getfield(t, :columns)[i]
Tables.getcolumn(t::StoredTable, nm::Symbol) = getfield(t, :columns)[nm]
Tables.columnnames(t::StoredTable) = keys(getfield(t, :columns))
Tables.schema(t::StoredTable) = Tables.schema(getfield(t, :columns))
Base.propertynames(t::StoredTable) = keys(getfield(t, :columns))
Base.getproperty(t::StoredTable, nm::Symbol) = getfield(t, :columns)[nm]
Base.length(t::StoredTable) = Tables.rowcount(getfield(t, :columns))
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

function Base.show(io::IO, t::StoredTable)
    cols = getfield(t, :columns)
    print(io, "StoredTable: ", Tables.rowcount(cols), " rows, columns ", join(keys(cols), ", "))
end

## Helpers for format implementations

"""
    table_metadata(table, metadata) -> Dict{String,String}

The table's own file-level metadata (`DataAPI.metadata`, values as strings) merged with `metadata`.
"""
function table_metadata(table, metadata)
    out = Dict{String,String}()
    if DataAPI.metadatasupport(typeof(table)).read
        for k in DataAPI.metadatakeys(table)
            out[string(k)] = string(DataAPI.metadata(table, k))
        end
    end
    return merge(out, Dict{String,String}(string(k) => string(v) for (k, v) in metadata))
end

"""
    plain_columns(table, allowed) -> NamedTuple

The table's columns as `Vector`s. Pooled and categorical columns become vectors of their values
(`DataAPI.unwrap`). A column whose element type (without `Missing`) is not in `allowed` is an
`ArgumentError` naming the column.
"""
function plain_columns(table, allowed)
    cols = Tables.columntable(table)
    return NamedTuple{keys(cols)}(map(keys(cols)) do name
        col = cols[name]
        v = collect(col)
        if !allowed_eltype(eltype(v), allowed)
            v = map(DataAPI.unwrap, v)
        end
        if !allowed_eltype(eltype(v), allowed)
            throw(ArgumentError("column $name has element type $(eltype(col)), which the format cannot store; supported: $(join(allowed, ", ")) (each optionally with missing)"))
        end
        v
    end)
end

allowed_eltype(T, allowed) = any(A -> nonmissingtype(T) <: A, allowed) && nonmissingtype(T) !== Union{}

"""
    atomic_write(f, path)

Call `f(tmp)` to write a temporary file next to `path`, then move it to `path`.
"""
function atomic_write(f, path)
    tmp = path * ".tmp-" * randstring(8)
    try
        f(tmp)
        mv(tmp, path; force = true)
    finally
        rm(tmp; force = true)
    end
    return path
end

const PARQUET_TYPES = (Float64, Float32, Int64, Int32, Bool, String, Symbol, Date, DateTime)

__init__() = Base.Experimental.register_error_hint(missing_format_hint, MethodError)

end # module Formats
