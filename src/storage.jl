# How values are written and read at a path: the storage hooks and the storage rules.
#
# A value at path p is, after to_storage: a table file p.<ext> (Tables.istable), a folder p/ (a
# NamedTuple, member m at p/m by the same rules) or p.jld2 (anything else, through write_portable_jld2).
# Each item is written to a temporary sibling, whose name starts with '.', and then renamed into
# place after the old item is removed. Readers skip names that start with '.'.

const SOLUTION = "solution"
const PROVENANCE = ".provenance"   # a dot name: never an item path
const NATIVE = "native"
const RESERVED = (SOLUTION, NATIVE)
const NATIVE_FILE = "native.jld2"
const LEGACY_NATIVE_FILE = "res.jld2"      # the native copy in runs saved with OutputVault 0.3

## Storage hooks

"""
    to_storage(x)

The value OutputVault writes for `x`: a Tables.jl table (one table file), a NamedTuple (a folder,
one item per member; a NamedTuple of equal-length vectors is a table) or anything else (a `.jld2` file written by [`write_portable_jld2`](@ref)). Default:
`x` itself. A package adds methods for its own types.
"""
to_storage(x) = x

"""
    from_storage(::Type{T}, data; context = nothing)

Rebuild a `T` from the data OutputVault read back: a [`StoredTable`](@ref Formats.StoredTable) for
a table file, a NamedTuple of the members' data for a folder. OutputVault calls it only with a
type the caller supplied. There is no generic method, so loading with a type that has none is a
`MethodError`. `context` is what the caller of `load_result_item` passed. A `.jld2` item uses
[`read_portable_jld2`](@ref) instead, without calling `from_storage`.
"""
function from_storage end

"""
    write_portable_jld2(io, x)

Write `x` into the open JLD2 file `io` that holds a `.jld2` item. A package defines methods for its
types to store a portable layout (plain arrays and strings that h5py, MATLAB or later Julia code can
read without the package). Without a method for its type, `x` is stored as the Julia object,
`io["value"] = x`.
"""
function write_portable_jld2(io, x)
    io["value"] = x
    return nothing
end

"""
    read_portable_jld2(::Type{T}, io; context = nothing)

Rebuild a `T` from the open JLD2 file `io`, as written by [`write_portable_jld2`](@ref).
`context` is what the caller of [`load_result_item`](@ref) passed, for what the file does not store
(TransitionFunctionIteration passes the model). Without a method for `T`: `io["value"]`.
"""
read_portable_jld2(::Type, io; context = nothing) = io["value"]

## Paths

# the levels of an item path; each a nonempty file name without '/', '\' or '.'
function path_levels(path)
    p = string(path)
    levels = split(p, '/')
    for l in levels
        if isempty(l) || occursin('\\', l) || occursin('.', l)
            throw(ArgumentError("invalid path \"$p\": levels are separated by '/' and are nonempty names without '\\' or '.'"))
        end
    end
    return String.(levels)
end

# levels of a path that may be written, moved or deleted: not under a reserved name
function writable_levels(path)
    levels = path_levels(path)
    if levels[1] in RESERVED
        throw(ArgumentError("\"$(levels[1])\" is reserved; choose another path than \"$path\""))
    end
    return levels
end

# levels of a path that may be read: not native
function readable_levels(path)
    levels = path_levels(path)
    if levels[1] == NATIVE
        throw(ArgumentError("\"native\" is not an item; use native = true for the native copy"))
    end
    return levels
end

## Finding items

# the format of a file name's extension (after the first '.'): a table format, :jld2 or nothing
function file_kind(name)
    i = findfirst('.', name)
    if isnothing(i) || i == 1
        return nothing
    end
    ext = name[i+1:end]
    if ext == "jld2"
        return :jld2
    end
    return Formats.format_from_extension(Val(Symbol(ext)))
end

# the item name of a file or folder name: before the first '.'
item_name(name) = String(first(split(name, '.'; limit = 2)))

# the extension of a file name: after the first '.' ("" if none)
file_extension(name) = occursin('.', name) ? String(last(split(name, '.'; limit = 2))) : ""

# the existing forms of the item at `stem` (an absolute path without extension): files
# stem.jld2 and stem.<table ext>, and the folder stem/
function item_forms(stem)
    dir, name = dirname(stem), basename(stem)
    forms = String[]
    if !isdir(dir)
        return forms
    end
    for f in readdir(dir)
        p = joinpath(dir, f)
        if f == name && isdir(p)
            push!(forms, p)
        elseif startswith(f, name * ".") && item_name(f) == name && isfile(p) && !isnothing(file_kind(f))
            push!(forms, p)
        end
    end
    return forms
end

# remove every form of the item at `stem`
function remove_item(stem)
    for p in item_forms(stem)
        rm(p; recursive = true, force = true)
    end
end

# an error if a parent of the item (levels[1:end-1] under `root`) is a file
function check_parents(root, levels, path)
    for i in 1:length(levels)-1
        stem = joinpath(root, levels[1:i]...)
        if any(isfile, item_forms(stem))
            throw(ArgumentError("cannot save \"$path\": \"$(join(levels[1:i], '/'))\" is a file; save the parent instead"))
        end
    end
end

## Writing

# a table value: a NamedTuple of vectors (a column table; their lengths must be equal) or another
# Tables.jl table. Any other NamedTuple is a folder, also one that Tables.jl would read as rows.
function is_table_value(s, path)
    if !(s isa NamedTuple)
        return Tables.istable(s)
    end
    if isempty(s) || !all(v -> v isa AbstractVector, values(s))
        return false
    end
    if length(unique(length.(values(s)))) > 1
        throw(ArgumentError("cannot save \"$path\": a NamedTuple of vectors with unequal lengths is not a table; make the members' lengths equal or nest the vectors"))
    end
    return true
end

# write value `v` as item `name` in the existing folder `dir`, replacing what is there;
# `path` names the item in errors
function write_item(dir, name, v, fmt, path)
    s = to_storage(v)
    tmpstem = joinpath(dir, "." * name * ".tmp-" * randstring(8))
    tmp, final = "", ""
    try
        if is_table_value(s, path)
            if isnothing(fmt)
                throw(ArgumentError("cannot save the table \"$path\": no table format is set (Config(; table_format = OutputVault.Formats.ParquetFormat()), for example)"))
            end
            ext = Formats.extension(fmt)
            tmp, final = tmpstem * "." * ext, joinpath(dir, name * "." * ext)
            Formats.write_table(fmt, tmp, s)
        elseif s isa NamedTuple
            tmp, final = mkdir(tmpstem), joinpath(dir, name)
            for (k, m) in pairs(s)
                member = string(k)
                path_levels(member)
                write_item(tmp, member, m, fmt, path * "/" * member)
            end
        else
            tmp, final = tmpstem * ".jld2", joinpath(dir, name * ".jld2")
            jldopen(io -> write_portable_jld2(io, s), tmp, "w")
        end
        remove_item(joinpath(dir, name))
        mv(tmp, final)
    catch
        rm(isempty(tmp) ? tmpstem : tmp; recursive = true, force = true)
        rethrow()
    end
    return final
end

# write `v` at the item path `levels` under the folder `root`
function write_at(root, levels, v, fmt, path)
    check_parents(root, levels, path)
    dir = mkpath(joinpath(root, levels[1:end-1]...))
    return write_item(dir, levels[end], v, fmt, path)
end

## Reading

# the single form of the item at `stem`, or an error naming `path`
function single_form(stem, path)
    forms = item_forms(stem)
    if isempty(forms)
        throw(ArgumentError("no item \"$path\" in the run"))
    end
    if length(forms) > 1
        throw(ArgumentError("item \"$path\" exists in several forms: $(join(basename.(forms), ", "))"))
    end
    return forms[1]
end

# the data of a file or folder: a StoredTable, a NamedTuple of the members' data, or a Dict; `skip`
# names files of the folder to leave out
function read_form(p::String; skip::Vector{String} = String[])
    if isdir(p)
        return read_folder(p; skip)
    end
    kind = file_kind(basename(p))
    if kind === :jld2
        return JLD2.load(p)
    end
    return Formats.read_table(kind, p)
end

# a folder as a NamedTuple of its items, in alphabetical order; other files are ignored. The
# members' data are collected untyped, which keeps inference of the recursion cheap.
function read_folder(dir::String; skip::Vector{String} = String[])
    names = String[]
    forms = String[]
    for f in sort(readdir(dir))
        p = joinpath(dir, f)
        if startswith(f, ".") || f in skip
            continue
        end
        if isdir(p) || !isnothing(file_kind(f))
            name = isdir(p) ? f : item_name(f)
            if name in names
                throw(ArgumentError("$dir holds item $name in several forms"))
            end
            push!(names, name)
            push!(forms, p)
        end
    end
    data = Any[]
    for p in forms
        push!(data, read_form(p))
    end
    return NamedTuple{Tuple(Symbol.(names))}(Tuple(data))
end

# the item at `stem` restored as a `T`: read_portable_jld2 for a .jld2 file, from_storage otherwise
function read_typed(stem, path, T, context; skip::Vector{String} = String[])
    p = single_form(stem, path)
    if !isdir(p) && file_kind(basename(p)) === :jld2
        return jldopen(io -> read_portable_jld2(T, io; context), p, "r")
    end
    return from_storage(T, read_form(p; skip); context)
end
