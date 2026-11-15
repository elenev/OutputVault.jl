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
    assemble_moments(root, moments; branch = "**", experdef = "*", economies = nothing) -> NamedTuple

Read the statistics that `moments` (a NamedTuple of TransitionFunctionIteration moments) need from
the saved runs under the output root `root`, in one DuckDB query for the simulation moments
(`vault_stats`) and one for the impulse moments (`vault_irf`). Returns a column table with one row
per (economy, statistic): `branch`, `experdef`, `economy`, `kind`, `group`, `variable`, `stat`,
`period`, `value`, the long form that TFI's `MomentTable` and `compare_economies(moments, names,
table)` read.

`branch` and `experdef` are glob patterns that narrow the files read (only matching runs are
opened); `economies` is an optional list of economy names to keep. Only runs that have the
component are read: an economy without saved statistics (or IRFs, for impulse moments) is simply
absent from the result, and the table is empty if there are none. Needs DuckDB and
TransitionFunctionIteration loaded (it is implemented in a package extension).
"""
function assemble_moments end

