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
