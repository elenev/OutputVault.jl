# Queries across runs with DuckDB. OutputVault writes all SQL; callers describe a family of table
# items with a QueryShape and select with keyword arguments.
#
# How a query runs: the runs (find_runs for a RunPattern) and the shape's path pattern, with the
# placeholder selections, are expanded to a list of files by listing folders, so only matching files
# are opened. DuckDB reads them with vault_table_parquet (sql/outputvault.sql), combined by column
# name; selections on keys become WHERE conditions, the table's other columns are cast to the
# value type and turned to long form with UNPIVOT, which drops NULL cells.

const DBI = DuckDB.DBInterface
const RUN_COLUMNS = (:branch, :experdef, :variant)
const RUN_COLUMN_NAMES = ["branch", "experdef", "variant"]

"""
    sql_path() -> String

The path of `outputvault.sql`, DuckDB macros that read lists of table files, for use from any language.
"""
sql_path() = joinpath(pkgdir(@__MODULE__), "sql", "outputvault.sql")

"""
    sql_statements() -> Vector{String}

The statements of `outputvault.sql`, comments removed, for clients that run one statement per call.
"""
function sql_statements()
    code = join((l for l in eachline(sql_path()) if !startswith(lstrip(l), "--")), "\n")
    return filter!(!isempty, String.(strip.(split(code, r";\s*$"m))))
end

"""
    vault_connection() -> DuckDB connection

An in-memory DuckDB connection with OutputVault's macros loaded
(`vault_table_parquet`, `vault_metadata_parquet`, `vault_split_variant`; see `sql/outputvault.sql`),
for querying in SQL. Close it with `DBInterface.close!`.
"""
function vault_connection()
    con = DBI.connect(DuckDB.DB)
    foreach(s -> DBI.execute(con, s), sql_statements())
    return con
end

## Shapes

"""
    QueryShape(path_pattern; keys = (), column = :column, valuetype = Float64)

A family of table items and the columns of a query over them.

- `path_pattern`: an item path in which a level `{name}` is a placeholder; its value in each
  matching file becomes the output column `name`. `"stats/{sample}"` matches `stats/uncond` and
  `stats/boom`.
- `keys`: the table columns that identify a row, copied to the output.
- `column`: the output column that holds the names of the table's other columns once the table is
  in long form.
- `valuetype`: the type of the output column `value` (`Float64`, `Float32`, `Int64`, `Int32`, `Bool`
  or `String`); every selected cell is cast to it.

[`query_results`](@ref) returns `branch, experdef, variant, <placeholders…>, <keys…>, <column>, value`.
"""
struct QueryShape
    levels::Vector{String}
    placeholders::Vector{Symbol}
    keys::Vector{Symbol}
    column::Symbol
    valuetype::Type
end

function QueryShape(path_pattern::AbstractString; keys = (), column::Symbol = :column, valuetype::Type = Float64)
    levels = String.(split(path_pattern, '/'))
    placeholders = Symbol[]
    for l in levels
        m = match(r"^\{([A-Za-z_][A-Za-z0-9_]*)\}$", l)
        if isnothing(m)
            path_levels(l)
        else
            push!(placeholders, Symbol(m[1]))
        end
    end
    keys = Symbol[Symbol(k) for k in keys]
    names = vcat(collect(RUN_COLUMNS), placeholders, keys, [column, :value])
    if !allunique(names)
        throw(ArgumentError("QueryShape(\"$path_pattern\"): the output columns $(join(names, ", ")) must be distinct"))
    end
    sqltype(valuetype)
    return QueryShape(levels, placeholders, keys, column, valuetype)
end

sqltype(::Type{Float64}) = "DOUBLE"
sqltype(::Type{Float32}) = "FLOAT"
sqltype(::Type{Int64}) = "BIGINT"
sqltype(::Type{Int32}) = "INTEGER"
sqltype(::Type{Bool}) = "BOOLEAN"
sqltype(::Type{String}) = "VARCHAR"
sqltype(T::Type) = throw(ArgumentError("valuetype $T is not supported; use Float64, Float32, Int64, Int32, Bool or String"))

placeholder_of(level) = startswith(level, "{") ? Symbol(level[2:end-1]) : nothing

## Selections

# a selection as a vector of values
selection_values(v::Union{AbstractVector, Tuple}) = collect(v)
selection_values(v) = [v]

# a selection value as a glob that matches a file or folder name: globs as given, other values exactly
name_glob(v::AbstractString) = isglob(v) ? String(v) : escape_glob(v)
name_glob(v) = escape_glob(string(v))

# whether a name matches any of the selection's values
selected(name, values) = any(v -> glob_match(name_glob(v), name), values)

function check_selections(shape, selections)
    allowed = vcat(shape.placeholders, shape.keys, [shape.column])
    for k in keys(selections)
        if !(k in allowed)
            throw(ArgumentError("$k is not a selection of this shape; the selections are $(join(allowed, ", "))"))
        end
    end
end

## Files

# the files of the shape's items in run `rf`, with their placeholder values: (file, values)
function shape_files(root, rf, shape, selections, ext)
    out = Tuple{String, Vector{String}}[]
    dir = run_path(root, rf)
    if isdir(dir)
        walk_levels!(out, dir, shape, 1, String[], selections, ext)
    end
    return out
end

function walk_levels!(out, dir, shape, i, values, selections, ext)
    level = shape.levels[i]
    last = i == length(shape.levels)
    ph = placeholder_of(level)
    for f in readdir(dir)
        p = joinpath(dir, f)
        if startswith(f, ".")
            continue
        end
        if last
            if !(isfile(p) && endswith(f, "." * ext))
                continue
            end
            name = f[1:end-length(ext)-1]
        else
            if !isdir(p)
                continue
            end
            name = f
        end
        if occursin('.', name)
            continue
        end
        if isnothing(ph)
            if name != level
                continue
            end
            vals = values
        else
            if haskey(selections, ph) && !selected(name, selection_values(selections[ph]))
                continue
            end
            vals = vcat(values, name)
        end
        if last
            push!(out, (p, vals))
        else
            walk_levels!(out, p, shape, i + 1, vals, selections, ext)
        end
    end
end

run_list(runs::RunPattern, root) = find_runs(runs; root)
run_list(runs, root) = collect(RunHandle, runs)

## SQL

sqlstring(x) = "'" * replace(string(x), "'" => "''") * "'"
sqlident(x) = "\"" * replace(string(x), "\"" => "\"\"") * "\""
sqllist(xs) = "[" * join(sqlstring.(xs), ", ") * "]"

# the WHERE condition of a key selection: exact values with IN, globs with GLOB
function key_condition(key, values)
    exact = [v for v in values if !(v isa AbstractString && isglob(v))]
    globs = [v for v in values if v isa AbstractString && isglob(v)]
    parts = String[]
    if !isempty(exact)
        push!(parts, sqlident(key) * " IN (" * join((v isa Number ? string(v) : sqlstring(v) for v in exact), ", ") * ")")
    end
    for g in globs
        push!(parts, sqlident(key) * " GLOB " * sqlstring(g))
    end
    return "(" * join(parts, " OR ") * ")"
end

"""
    query_results(runs, shape::QueryShape; selections...) -> NamedTuple of vectors

The cells of the table items of `shape` in `runs`, in long form: one row per selected cell, with the
columns `branch, experdef, variant, <placeholders…>, <keys…>, <column>, value`. `runs` is a
[`RunPattern`](@ref) or a collection of [`RunHandle`](@ref)s.

Selections are keyword arguments named after a placeholder (which picks files), a key (rows) or
the shape's `column` (the table's columns). Each takes a value or a vector of values; a `String`
with `*`, `?` or `[` is a glob, any other value (a `Symbol` always) matches exactly. Globs apply to
text only; numeric keys take exact values. Without a selection a column keeps everything.

Only files of the configured table format are read, and only those of the selected runs and
placeholder values. Tables of different runs are combined by column name: a column that a file
lacks gives no rows for it, and so does a missing cell. Text columns come back as `String`, numeric
keys as stored, and `value` as the shape's `valuetype`; a cell that cannot be cast is an error
naming its column. Rows are ordered by run, placeholders, row of the file and column of the table.
"""
function query_results(runs, shape::QueryShape; selections...)
    selections = NamedTuple(selections)
    check_selections(shape, selections)
    cfg = global_config()
    fmt = table_format(cfg)
    if isnothing(fmt)
        throw(ArgumentError("query_results needs a table format in the configuration"))
    end
    root = output_root(cfg)
    files = Tuple{String, RunHandle, Vector{String}}[]
    for rf in run_list(runs, root)
        for (f, vals) in shape_files(root, rf, shape, selections, Formats.extension(fmt))
            push!(files, (f, rf, vals))
        end
    end
    if isempty(files)
        return empty_result(shape)
    end
    con = vault_connection()
    try
        return run_query(con, shape, selections, files, fmt)
    finally
        DBI.close!(con)
    end
end

function empty_result(shape)
    cols = vcat([c => String[] for c in RUN_COLUMNS], [p => String[] for p in shape.placeholders],
                [k => Any[] for k in shape.keys], [shape.column => String[], :value => shape.valuetype[]])
    return NamedTuple(cols)
end

reader(::Formats.ParquetFormat) = "vault_table_parquet"
reader(fmt) = throw(ArgumentError("queries do not support the table format $(typeof(fmt))"))

function run_query(con, shape, selections, files, fmt)
    q(sql) = Tables.columntable(DBI.execute(con, sql))
    # the files and their keys, as a table to join on
    fcols = vcat(["__file"], RUN_COLUMN_NAMES, string.(shape.placeholders))
    rows = ["(" * join(sqlstring.(vcat(f, rf.branch, rf.experdef, rf.variant, vals)), ", ") * ")" for (f, rf, vals) in files]
    DBI.execute(con, "CREATE TEMP TABLE __files(" * join(sqlident.(fcols) .* " VARCHAR", ", ") * ")")
    DBI.execute(con, "INSERT INTO __files VALUES " * join(rows, ", "))
    src = "$(reader(fmt))($(sqllist(first.(files))))"
    DBI.execute(con, "CREATE TEMP VIEW __src AS SELECT * FROM $src")

    columns = String.(q("SELECT column_name FROM (DESCRIBE SELECT * FROM __src)").column_name)
    for k in shape.keys
        if !(string(k) in columns)
            throw(ArgumentError("key $k is not a column of the selected files; their columns are $(join(setdiff(columns, ["__file", "__row"]), ", "))"))
        end
    end
    vcols = [c for c in columns if !(c in ("__file", "__row")) && !(Symbol(c) in shape.keys)]
    if haskey(selections, shape.column)
        vcols = [c for c in vcols if selected(c, selection_values(selections[shape.column]))]
    end
    if isempty(vcols)
        return empty_result(shape)
    end

    T = sqltype(shape.valuetype)
    conds = [key_condition(k, selection_values(selections[k])) for k in shape.keys if haskey(selections, k)]
    where_ = isempty(conds) ? "" : "WHERE " * join(conds, " AND ")
    out = vcat(RUN_COLUMN_NAMES, string.(shape.placeholders), string.(shape.keys))
    order = join((sqlident(c) for c in vcat(RUN_COLUMN_NAMES, string.(shape.placeholders))), ", ")
    colidx = "CASE " * sqlident(shape.column) * " " *
             join(("WHEN $(sqlstring(c)) THEN $i" for (i, c) in enumerate(vcols)), " ") * " END"
    selected_columns = vcat(["f." * sqlident(c) for c in vcat(RUN_COLUMN_NAMES, string.(shape.placeholders))],
                            ["s." * sqlident(k) for k in shape.keys], ["s.__row"],
                            ["CAST(s.$(sqlident(c)) AS $T) AS $(sqlident(c))" for c in vcols])
    sql = """
        WITH cast_ AS (
            SELECT $(join(selected_columns, ", "))
            FROM __src s JOIN __files f ON s.__file = f.__file
            $where_
        )
        SELECT $(join(sqlident.(out), ", ")), $(sqlident(shape.column)), value
        FROM (UNPIVOT cast_ ON $(join(sqlident.(vcols), ", ")) INTO NAME $(sqlident(shape.column)) VALUE value)
        ORDER BY $order, __row, $colidx"""
    result = try
        q(sql)
    catch err
        failing = cast_failure(con, vcols, T, conds)
        if isnothing(failing)
            rethrow()
        end
        throw(ArgumentError("column $failing of the selected files has cells that cannot be cast to $(shape.valuetype)"))
    end
    return tidy(result, shape)
end

# the first value column with a cell (among the rows that `conds` select) that cannot be cast to
# T, or nothing
function cast_failure(con, vcols, T, conds)
    for c in vcols
        cond = join(vcat(conds, ["$(sqlident(c)) IS NOT NULL", "TRY_CAST($(sqlident(c)) AS $T) IS NULL"]), " AND ")
        n = only(Tables.columntable(DBI.execute(con, "SELECT count(*) AS n FROM __src WHERE $cond")).n)
        if n > 0
            return c
        end
    end
    return nothing
end

# columns without Missing where there is none, value as the value type
function tidy(result, shape)
    names = keys(result)
    return NamedTuple{names}(map(names) do k
        v = result[k]
        if k === :value
            return convert(Vector{shape.valuetype}, v)
        end
        return any(ismissing, v) ? collect(v) : collect(nonmissingtype(eltype(v)), v)
    end)
end
