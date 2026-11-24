# OutputVault with DuckDB and TFI: the moments that TFI moment specifications name, read from
# saved runs with the macros of sql/outputvault.sql.
#
# Maintainer notes
# - `momentrows(moment)` lists the rows of the long table that a moment needs, and is the only place
#   where TFI's moment types meet the layout of saved results: `assemble_moments` fetches those rows,
#   and `momentvalues` for a per-economy Dict (below) reads them. The first row is the value and a
#   second, for an impulse moment, the basis of its transformation.
# - One query per kind of row: the requested rows go in as a VALUES list that is joined to vault_stats
#   (simulation rows) or vault_irf (impulse rows), so DuckDB reads only the files of the matching runs
#   and returns only the numbers asked for. Parameter rows come from vault_params.
# - The rows are literals in the SQL text (quotes doubled); the root and the globs are literals too,
#   because the macros build file patterns from them.
# - Only the runs that have the component are queried (vault_runs lists the runs from their solution
#   folders, without opening data files), because a file pattern that matches nothing is an error in
#   DuckDB; economies without the component are simply absent from the result.
# - The result of assemble_moments is a plain column table of Strings (for any language to read).
#   `split_by_economy` turns it into one Dict per economy keyed by the row, with Symbols, which is
#   what `TFI.getmoment` reads; the reading itself is TFI's, so a calculated moment, the base
#   economy and `compare_economies` all work unchanged.
module OutputVaultDuckDBExt

using OutputVault, DuckDB, Tables
import TransitionFunctionIteration as TFI

## The rows of a moment

const LeafMoment = Union{TFI.SimulationMoment, TFI.ImpulseMoment, TFI.ParameterMoment}

OutputVault.momentrows(m::TFI.SimulationMoment) = (
    (kind = :simulation, group = m.sample, variable = m.var, stat = m.stat, period = 0),
)
OutputVault.momentrows(m::TFI.ImpulseMoment) = (
    (kind = :impulse, group = m.shock,  variable = m.var, stat = m.stat, period = m.period),
    (kind = :impulse, group = :uncond, variable = m.var, stat = m.stat, period = m.period),
)
OutputVault.momentrows(m::TFI.ParameterMoment) = (
    (kind = :parameter, group = :parameters, variable = m.name, stat = :value, period = 0),
)
OutputVault.momentrows(m::TFI.CalculatedMoment) =
    unique(reduce(vcat, [collect(OutputVault.momentrows(c)) for c in values(m.inputs)]))

# the distinct rows of all moments, by kind
function requested_rows(moments)
    rows = unique(reduce(vcat, [collect(OutputVault.momentrows(m)) for m in values(moments)]; init = NamedTuple[]))
    return (; (kind => filter(r -> r.kind === kind, rows) for kind in (:simulation, :impulse, :parameter))...)
end

## Querying

# a SQL string literal
sqlstring(x) = "'" * replace(string(x), "'" => "''") * "'"

values_list(rows) = join(("($(sqlstring(r.group)), $(sqlstring(r.variable)), $(sqlstring(r.stat)), $(r.period))"
                          for r in rows), ", ")

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

function query_simulation(con, root, branch, experdef, rows, wanted)
    isempty(rows) && return nothing
    have = economies_with(con, root, branch, experdef, wanted, "stats", nothing)
    isempty(have) && return nothing
    sql = """
        WITH wanted(grp, variable, stat, period) AS (VALUES $(values_list(rows)))
        SELECT s.branch, s.experdef, s.economy, 'simulation' AS kind, s.sample AS "group", s.variable, s.stat,
               w.period, s.value
        FROM vault_stats($(sqlstring(root)), branch_glob := $(sqlstring(branch)), experdef_glob := $(sqlstring(experdef)),
                         economies := $(sqllist(have))) s
        JOIN wanted w ON s.sample = w.grp AND s.variable = w.variable AND s.stat = w.stat"""
    return Tables.columntable(DBInterface.execute(con, sql))
end

function query_impulse(con, root, branch, experdef, rows, wanted)
    isempty(rows) && return nothing
    have = economies_with(con, root, branch, experdef, wanted, "irf", "irf.parquet")
    isempty(have) && return nothing
    sql = """
        WITH wanted(grp, variable, stat, period) AS (VALUES $(values_list(rows)))
        SELECT i.branch, i.experdef, i.economy, 'impulse' AS kind, i.shock AS "group", i.variable, i.stat,
               i.period, i.value
        FROM vault_irf($(sqlstring(root)), branch_glob := $(sqlstring(branch)), experdef_glob := $(sqlstring(experdef)),
                         economies := $(sqllist(have))) i
        JOIN wanted w ON i.shock = w.grp AND i.variable = w.variable AND i.stat = w.stat AND i.period = w.period"""
    return Tables.columntable(DBInterface.execute(con, sql))
end

# the saved parameters: all of them (`parameters == true`), the named ones, or none, plus those that a
# ParameterMoment among the moments names
function query_parameters(con, root, branch, experdef, rows, parameters, wanted)
    required = String[String(r.variable) for r in rows]
    names = parameters === true ? nothing :
            parameters === false ? required : unique(vcat(String.(collect(parameters)), required))
    isnothing(names) || isempty(names) && return nothing
    have = economies_with(con, root, branch, experdef, wanted, "params", "params.parquet")
    isempty(have) && return nothing
    where_ = isnothing(names) ? "" : "WHERE p.parameter IN ($(join(sqlstring.(names), ", ")))"
    sql = """
        SELECT p.branch, p.experdef, p.economy, 'parameter' AS kind, 'parameters' AS "group", p.parameter AS variable,
               'value' AS stat, 0 AS period, p.value
        FROM vault_params($(sqlstring(root)), branch_glob := $(sqlstring(branch)), experdef_glob := $(sqlstring(experdef)),
                          economies := $(sqllist(have))) p $where_"""
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
                                      economies = nothing, parameters = true)
    root = String(root)
    rows = requested_rows(moments)
    con = DBInterface.connect(DuckDB.DB)
    try
        foreach(s -> DBInterface.execute(con, s), OutputVault.duckdb_statements())
        wanted = isnothing(economies) ? nothing : String.(economies)
        return vcat_columns((query_simulation(con, root, branch, experdef, rows.simulation, wanted),
                             query_impulse(con, root, branch, experdef, rows.impulse, wanted),
                             query_parameters(con, root, branch, experdef, rows.parameter, parameters, wanted)))
    finally
        DBInterface.close!(con)
    end
end

## Reading: one Dict per economy

const RowKey = NamedTuple{(:kind, :group, :variable, :stat, :period), Tuple{Symbol, Symbol, Symbol, Symbol, Int}}

function OutputVault.split_by_economy(table; key = OutputVault.RUN_FIELDS, order = nothing)
    cols = Tables.columntable(table)
    runs = unique([(branch = String(b), experdef = String(x), economy = String(e))
                   for (b, x, e) in zip(cols.branch, cols.experdef, cols.economy)])
    names = OutputVault.run_keys(runs, key)
    fields = OutputVault._key_fields(key)
    dicts = Dict(n => Dict{RowKey, Float64}() for n in names)
    for j in eachindex(cols.value)
        run = (branch = cols.branch[j], experdef = cols.experdef[j], economy = cols.economy[j])
        d = dicts[OutputVault._run_key(run, fields)]
        row = (kind = Symbol(cols.kind[j]), group = Symbol(cols.group[j]), variable = Symbol(cols.variable[j]),
               stat = Symbol(cols.stat[j]), period = Int(cols.period[j]))
        haskey(d, row) && throw(ArgumentError("moment table has duplicate rows for $(run.branch)/res-$(run.experdef)-$(run.economy): $row"))
        d[row] = cols.value[j]
    end
    if !isnothing(order)
        wanted = OutputVault._key_name.(collect(order))
        missing_ = setdiff(wanted, names)
        isempty(missing_) || throw(ArgumentError("order names $missing_, which are not in the table; its names (key = $(repr(key))) are $names"))
        names = wanted
    end
    return NamedTuple{Tuple(names)}(Tuple(dicts[n] for n in names))
end

function TFI.momentvalues(d::AbstractDict, m::LeafMoment)
    values = map(OutputVault.momentrows(m)) do r
        haskey(d, r) || throw(KeyError("saved results have no entry $r"))
        d[r]
    end
    return first(values), length(values) == 2 ? values[2] : nothing
end

## compare_economies over a saved output root: assemble the rows, then read them as economies

function TFI.compare_economies(moments::NamedTuple, economy_names::Union{Tuple, AbstractVector}, root::AbstractString;
                               branch::AbstractString = "**", experdef::AbstractString = "*", base = 1)
    moments = map(v -> v isa TFI.AbstractMoment ? v : TFI.SimulationMoment(v), moments)
    table = OutputVault.assemble_moments(root, moments; branch, experdef, economies = economy_names)
    absent = [e for e in String.(economy_names) if e ∉ table.economy]
    isempty(absent) || throw(KeyError("saved results have no statistics for economies $absent (branch $branch, experdef $experdef)"))
    economies = OutputVault.split_by_economy(table; key = :economy, order = economy_names)
    return TFI.compare_economies(moments, economies; base)
end

end # module
