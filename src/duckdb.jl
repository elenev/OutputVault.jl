# The DuckDB interface (sql/outputvault.sql): table macros over an output root, for analysis in
# any language with DuckDB. OutputVault does not depend on DuckDB; it ships the SQL.

"""
    duckdb_sql_path() -> String

Path of `outputvault.sql`, the DuckDB table macros over an output root (`vault_runs`,
`vault_stats`, `vault_errstats`, `vault_params`, `vault_irf`, `vault_simulation`). Load it into a
DuckDB connection, from any language, and query, e.g. `SELECT * FROM vault_stats('<output_root>')`.
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

Select from the saved runs under the output root `root` the numbers that `moments` (a NamedTuple of
TransitionFunctionIteration moments) need, with DuckDB (`vault_stats`, `vault_irf` and `vault_params`).
Returns a column table with one row per (run, number): `branch`, `experdef`, `economy`, `kind`
(`simulation`, `impulse` or `parameter`), `group`, `variable`, `stat`, `period` and `value`, all names
Strings. This is the form for any language to read; [`split_by_economy`](@ref) turns it into what TFI's
`getmoment` and `compare_economies` read.

`branch` and `experdef` are glob patterns that select the runs (by default all branches and
experdefs); `economies` is an optional list of economy names to keep. DuckDB opens the files of the
components it reads in every selected run, which downloads online-only files in a synced folder, so
select only the runs you need. A run without the component of a kind of number (statistics, IRFs or
parameters) has no rows of that kind; the table is empty if no run has any.

`parameters` selects the saved model parameters (the `params` component) that are added as rows
(`kind = "parameter"`, `group = "parameters"`, `stat = "value"`, `period = 0`): `true` (the default) for all,
`false` for none, or a collection of names. Parameters that a `ParameterMoment` among `moments` names are
always included. Needs DuckDB, Tables and TransitionFunctionIteration loaded (it is implemented in a
package extension).
"""
function assemble_moments end

"""
    split_by_economy(table; key = (:branch, :experdef, :economy), order = nothing) -> NamedTuple

The long table of [`assemble_moments`](@ref) as one `Dict` per run, in a NamedTuple. Each Dict maps a
row `(kind, group, variable, stat, period)`, with Symbols, to its value, and is a source that TFI's
`getmoment` reads for any moment; the NamedTuple is the `economies` argument of
`getmoment(economies, moment, economy, base)` and `compare_economies`.

Runs are named by `key`: the run's `branch`, `experdef` and `economy` joined with `__` by default
(`main__v1__base`), or only the fields you pass (`key = :economy` gives `base`). Characters other than
letters, digits and `_` become `_`. Distinct runs that get the same name are an `ArgumentError` that
lists them: select fewer runs in `assemble_moments` or use a longer key.

`order` lists the names to keep, in that order; the first is the base of a comparison. A name not in
the table is an error. Without `order`, runs come in the order of the table. Duplicate rows within a
run are an error.
"""
function split_by_economy end

"""
    momentrows(moment)

The rows of the long table of [`assemble_moments`](@ref) that a TFI moment needs, as NamedTuples
`(kind, group, variable, stat, period)` of Symbols and an Int: the first is the moment's value and a second,
for an impulse moment whose transformation requires it, the path named by its `basis` (`:uncond`
by default). Level moments need only the first row. A calculated moment
needs the rows of its inputs.
"""
function momentrows end
