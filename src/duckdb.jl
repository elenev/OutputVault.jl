# The DuckDB interface (sql/outputvault.sql): table macros over an output root, for analysis in
# any language with DuckDB. OutputVault does not depend on DuckDB; it ships the SQL.

"""
    duckdb_sql_path() -> String

Path of `outputvault.sql`, the DuckDB table macros over an output root (`vault_stats`,
`vault_errstats`, `vault_simulation`, `vault_runs`). Load it into a DuckDB connection and query,
e.g. `SELECT * FROM vault_stats('<output_root>')`.
"""
duckdb_sql_path() = joinpath(pkgdir(@__MODULE__), "sql", "outputvault.sql")

"""
    duckdb_statements() -> Vector{String}

The statements of `outputvault.sql`, comments removed, for clients that run one statement per
call. With DuckDB.jl: `foreach(s -> DBInterface.execute(con, s), duckdb_statements())`.
"""
function duckdb_statements()
    code = join((l for l in eachline(duckdb_sql_path()) if !startswith(lstrip(l), "--")), "\n")
    filter!(!isempty, strip.(split(code, r";\s*$"m)))
end

"""
    assemble_moments(root, moments; branch = "**", experdef = "*", economies = nothing, parameters = true) -> NamedTuple

Read the numbers that `moments` (a NamedTuple of TransitionFunctionIteration moments) need from the
saved runs under the output root `root`: one DuckDB query for the simulation moments (`vault_stats`),
one for the impulse moments (`vault_irf`) and one for parameters (`vault_params`). Returns a column
table with one row per (economy, number): `branch`, `experdef`, `economy`, `kind` (`simulation`,
`impulse` or `parameter`), `group`, `variable`, `stat`, `period` and `value`, all names Strings. This is
the form for any language to read; [`split_by_economy`](@ref) turns it into what TFI's `getmoment` and
`compare_economies` read.

`branch` and `experdef` are glob patterns that narrow the files read (only matching runs are
opened); `economies` is an optional list of economy names to keep (without it, every run matching the
globs is opened, which downloads online-only files in a synced folder). Only runs that have the
component are read: an economy without saved statistics (or IRFs, for impulse moments, or parameters)
is simply absent from the result, and the table is empty if there are none.

`parameters` selects the saved model parameters (the `params` component) that are added as rows
(`kind = "parameter"`, `group = "parameters"`, `stat = "value"`, `period = 0`): `true` (the default) for all,
`false` for none, or a collection of names. Parameters that a `ParameterMoment` among `moments` names are
always included. Needs DuckDB, Tables and TransitionFunctionIteration loaded (it is implemented in a
package extension).
"""
function assemble_moments end

"""
    split_by_economy(table; economies = nothing) -> NamedTuple

The long table of [`assemble_moments`](@ref) as one `Dict` per economy, in a NamedTuple keyed by the
economy name. Each Dict maps a row `(kind, group, variable, stat, period)`, with Symbols, to its value, and
is a source that TFI's `getmoment` reads for any moment; the NamedTuple is the `economies` argument of
`getmoment(economies, moment, economy, base)` and `compare_economies`. With `economies`, only those, in
that order (an economy absent from the table is left out). Duplicate rows for an economy are an error.
"""
function split_by_economy end

"""
    momentrows(moment)

The rows of the long table of [`assemble_moments`](@ref) that a TFI moment needs, as NamedTuples
`(kind, group, variable, stat, period)` of Symbols and an Int: the first is the moment's value and a second,
for an impulse moment, the baseline that its transformation uses as the basis. A calculated moment
needs the rows of its inputs.
"""
function momentrows end
