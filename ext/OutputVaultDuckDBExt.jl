# OutputVault with DuckDB and TFI: the moments that TFI moment specifications name, read from
# saved runs with the macros of sql/outputvault.sql.
#
# Maintainer notes
# - One query per kind of moment: the requested entries (TFI.moment_keys of every moment) go in as a
#   VALUES list that is joined to vault_stats (simulation moments) or vault_irf (impulse moments),
#   so DuckDB reads only the files of the matching runs and returns only the numbers asked for.
# - The entries are literals in the SQL text (quotes doubled); the root and the globs are literals
#   too, because the macros build file patterns from them.
# - Only the runs that have the component are queried (vault_runs lists the runs from their solution
#   folders, without opening data files), because a file pattern that matches nothing is an error in
#   DuckDB; economies without the component are simply absent from the result.
# - The result columns are those of TFI.MomentTable.
module OutputVaultDuckDBExt

using OutputVault, DuckDB, Tables
import TransitionFunctionIteration as TFI

# a SQL string literal
sqlstring(x) = "'" * replace(string(x), "'" => "''") * "'"

# the distinct entries, as `kind` (:simulation or :impulse) => rows (group, variable, stat, period)
function requested_entries(moments)
    keys_ = unique(Iterators.flatten(map(TFI.moment_keys, values(moments))))
    return (simulation = filter(k -> k.kind === :simulation, keys_), impulse = filter(k -> k.kind === :impulse, keys_))
end

values_list(entries) = join(("($(sqlstring(k.group)), $(sqlstring(k.variable)), $(sqlstring(k.stat)), $(k.period))"
                             for k in entries), ", ")

# the economies among `wanted` (all if nothing) that have `component` saved, as a SQL list literal;
# `file` is the file below the component's folder (nothing: the folder suffices)
function economies_with(con, root, branch, experdef, wanted, component, file)
    runs = Tables.columntable(DBInterface.execute(con,
        "SELECT * FROM vault_runs($(sqlstring(root)), branch_glob := $(sqlstring(branch)), experdef_glob := $(sqlstring(experdef)))"))
    have = String[]
    for (b, x, e) in zip(runs.branch, runs.experdef, runs.economy)
        (isnothing(wanted) || e in wanted) || continue
        folder = joinpath(root, b, "res-$x-$e", component)
        (isnothing(file) ? isdir(folder) : isfile(joinpath(folder, file))) && push!(have, e)
    end
    return unique(have)
end
sqllist(xs) = "[" * join(sqlstring.(xs), ", ") * "]"

function query_simulation(con, root, branch, experdef, entries, wanted)
    isempty(entries) && return nothing
    have = economies_with(con, root, branch, experdef, wanted, "stats", nothing)
    isempty(have) && return nothing
    sql = """
        WITH wanted(grp, variable, stat, period) AS (VALUES $(values_list(entries)))
        SELECT s.branch, s.experdef, s.economy, 'simulation' AS kind, s.sample AS "group", s.variable, s.stat,
               w.period, s.value
        FROM vault_stats($(sqlstring(root)), branch_glob := $(sqlstring(branch)), experdef_glob := $(sqlstring(experdef)),
                         economies := $(sqllist(have))) s
        JOIN wanted w ON s.sample = w.grp AND s.variable = w.variable AND s.stat = w.stat"""
    return Tables.columntable(DBInterface.execute(con, sql))
end

function query_impulse(con, root, branch, experdef, entries, wanted)
    isempty(entries) && return nothing
    have = economies_with(con, root, branch, experdef, wanted, "irf", "irf.parquet")
    isempty(have) && return nothing
    sql = """
        WITH wanted(grp, variable, stat, period) AS (VALUES $(values_list(entries)))
        SELECT i.branch, i.experdef, i.economy, 'impulse' AS kind, i.shock AS "group", i.variable, i.stat,
               i.period, i.value
        FROM vault_irf($(sqlstring(root)), branch_glob := $(sqlstring(branch)), experdef_glob := $(sqlstring(experdef)),
                         economies := $(sqllist(have))) i
        JOIN wanted w ON i.shock = w.grp AND i.variable = w.variable AND i.stat = w.stat AND i.period = w.period"""
    return Tables.columntable(DBInterface.execute(con, sql))
end

# concatenation of column tables with the same columns
const EMPTY_TABLE = (branch = String[], experdef = String[], economy = String[], kind = String[], group = String[],
                     variable = String[], stat = String[], period = Int[], value = Float64[])
function vcat_columns(tables)
    tables = collect(filter(!isnothing, tables))
    isempty(tables) && return EMPTY_TABLE
    return NamedTuple{keys(first(tables))}(Tuple(reduce(vcat, [getproperty(t, k) for t in tables]) for k in keys(first(tables))))
end

function OutputVault.assemble_moments(root::AbstractString, moments::NamedTuple;
                                      branch::AbstractString = "**", experdef::AbstractString = "*",
                                      economies = nothing)
    root = String(root)
    entries = requested_entries(moments)
    con = DBInterface.connect(DuckDB.DB)
    try
        foreach(s -> DBInterface.execute(con, s), OutputVault.duckdb_statements())
        wanted = isnothing(economies) ? nothing : String.(economies)
        return vcat_columns((query_simulation(con, root, branch, experdef, entries.simulation, wanted),
                             query_impulse(con, root, branch, experdef, entries.impulse, wanted)))
    finally
        DBInterface.close!(con)
    end
end

# compare_economies over a saved output root: assemble the statistics, then read them as a table
TFI.compare_economies(moments::NamedTuple, economy_names::Union{Tuple, AbstractVector}, root::AbstractString;
                      branch::AbstractString = "**", experdef::AbstractString = "*", base = 1) =
    TFI.compare_economies(moments, economy_names,
                          OutputVault.assemble_moments(root, moments; branch, experdef, economies = economy_names); base)

end # module
