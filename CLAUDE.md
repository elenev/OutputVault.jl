# OutputVault.jl -- Technical Notes for Claude

User-facing documentation is in `README.md` and `docs/` (Documenter; build with
`julia --project=docs docs/make.jl`). These notes are for maintainers: design decisions and where
things are.

## Package purpose

OutputVault organizes model output files by git branch, experiment definition, and economy name,
stores objects by type (TFI types in plain, portable formats), and records git provenance (commit ID
+ diffs) with the solution. It is a library: consuming packages supply project-specific
configuration, typically in their `__init__`. All file I/O for TransitionFunctionIteration lives
here (decided 2026-11-13/14): TFI only provides in-memory objects, their Tables.jl interfaces and
DataAPI metadata (as strings, ready for any writer).

## Source layout

```julia
src/
  OutputVault.jl   -- module shell: usings, exports, includes (in dependency order)
  git.jl           -- git utilities (LibGit2 + shell commands)
  types.jl         -- RunHandle, LAYOUT, table formats (Formats), AbstractConfig, Config
  global_config.jl -- module-level config ref, set_config!, with_config
  filesystem.jl    -- output_path, economy_folder
  save_load.jl     -- FileIO.load, save_result, producer interface (storage_kind,
                      write_object, write_table, write_table_parts, jld2_record,
                      recorded_kind, read_kind), stubs for save_solution, load_solution,
                      save_steadystate, load_steadystate, model_metadata, model_from_metadata,
                      collect_parameters
  discovery.jl     -- find_matching_results, get_results_folders, key helpers
  duckdb.jl        -- duckdb_sql_path, duckdb_statements, assemble_moments (stub; the SQL is
                      sql/outputvault.sql)
sql/
  outputvault.sql  -- DuckDB table macros over an output root (vault_stats, vault_errstats,
                      vault_params, vault_irf, vault_simulation, vault_runs); run identity parsed
                      from folder names
ext/
  OutputVaultParquet2Ext.jl -- Formats.ParquetFormat (Parquet2)
  OutputVaultTFIExt.jl      -- (TFI, StaticArrays, StructArrays) writers/readers for TFI types,
                               solution and steady-state file layouts (schema version 2),
                               Interpolant storage, model_metadata for TFI models,
                               collect_parameters default, compare_economies over RunHandles
  OutputVaultDuckDBExt.jl   -- (DuckDB, Tables, TFI) assemble_moments, compare_economies over a root
docs/
  make.jl, Project.toml, src/ -- Documenter site (index, guide/*, api)
test/                -- one file per source file, plus test_tfi.jl, test_duckdb.jl, fixtures
```

## Key types

`RunHandle` (types.jl) -- identifies one saved run: `branch`, `experdef`, `economy`
(all `String`). `RunHandle(economy; branch, experdef)`; branch defaults to `current_branch()`
(live git query), experdef to `"default"`. `experdef` must not contain `-` (the folder
`res-<experdef>-<economy>` is split at the first hyphen by readers).

`LAYOUT` (types.jl) -- fixed for every project (decided 2026-11-14): components and their
properties: `solution (obj, stv)`, `stats (stats)`, `errstats (errstats)`, `simulation (simseries,
errs)`, `irf (irf)`, `params (params)`, `recursions (claims, welfare)`. Extensions do not register
components; a producer's types go in existing properties. `SOLUTION_COMPONENT = :solution`: saving
`obj` or `stv` deletes the run folder first.

`AbstractConfig` (types.jl) -- interface: `output_root(cfg)` (required), `table_format(cfg)`
(default `nothing`), `solution_format(cfg)` (default `(:portable, :native)`).

`Config(; output_root, table_format = nothing, solution_format = (:portable, :native))` -- the
concrete implementation. Three tiers (decided 2026-11-14): fixed for everyone = the layout, run path,
file layouts, git provenance; project = `Config`; call = which objects `save_result` is given,
`dirty_repo_check`, `load`'s `solution_format` and `model`.

`AbstractTableFormat` (types.jl) -- `table_extension(fmt)`, `write_table_file(fmt, path, table,
meta)`, `read_table_file(fmt, path)` (a Tables.jl source with file metadata via DataAPI),
`required_package(fmt)`. `Formats.ParquetFormat` (implemented in the Parquet2 extension);
`TableFormat(; ext, write, read)` takes functions. OutputVault stays format-agnostic; no CSV yet
(loading assumes files carry metadata).

## Global config, filesystem, git

`set_config!`, `global_config()`, `with_config(f, cfg)` (restores in a `finally`).
`output_path(cfg, branch)` = `output_root/branch` (created); `economy_folder(cfg, rf; create)` =
`output_root/branch/res-<experdef>-<economy>`, an error if absent and `create = false`.

`current_branch()`, `is_repo_clean()`, `get_commit_id(check_clean)` -> `(commit_id, diffs)`: if dirty,
the staged diff from the real index (read only), the unstaged diff against a temporary copy of the
index (`GIT_INDEX_FILE`) in which untracked files are intent-added (`git add -N :/`), deleted
afterwards. The repository's index is never modified. A diff over 1 MB is dropped with a warning.

## I/O (save_load.jl)

`save_result(cfg, rf, result; dirty_repo_check = :warn)`: keeps the properties of `result` that
`LAYOUT` names and that are not `nothing`; if any of them is in `solution`, writes everything to a
staging folder (`staging_root(cfg)`, default `tempdir()/OutputVault`) and swaps it in
(`_replace_folder`: rename the old folder to `.replaced-<name>-<ts>`, move the staged one in, delete
the old one; decided 2026-11-15). On Windows open or memory-mapped files block renames/deletes; a
failure never loses or half-deletes results: the run's path holds the intact old results and the new
ones stay in staging, with one `_stranded` warning listing all paths, and `save_result` returns the
staging path. A leftover `.replaced-*` folder only warns (no cleanup on later saves; discovery and
DuckDB match `res-*` and ignore it). Otherwise (no solution objects) it writes in place. Per component:
makes the folder, for `solution` writes the git files and passes
`provenance = Dict("git_commit_id" => id)` to `write_object`, and for each property calls
`write_object(cfg, dir, string(p), getproperty(result, p); provenance)`. `solution` also gets
`res.jld2` (all its objects, `jldsave`) if `:native` is in `solution_format`; other components are
always portable. Recursions and other later saves add to the folder without touching `solution`.

Producer interface (decided 2026-11-14; the core never names a producer's keys, producers never name
the core's), not exported, extended as `OutputVault.storage_kind` etc.:

- `storage_kind(x)` -- namespaced kind (`"TransitionFunctionIteration.ModelSolution"`); default
  `nothing` (stored with JLD2 as `name.jld2`, key `"value"`).
- `write_object(cfg, dir, name, x; provenance)` -- built on `write_table(cfg, stem, table; meta)`
  (records `"outputvault.kind"` in the file metadata) or `jld2_record(f, path, x)` (records
  `"outputvault/kind"`, then calls `f(io)`). `write_table_parts` writes a NamedTuple of tables, one
  file per part with `"outputvault.part_of"` and `"outputvault.part_index"`.
- `read_kind(Val(kind), path; model)` / `read_kind(Val(kind), source, path, fmt)`; `recorded_kind(path)`.

`FileIO.load(cfg, rf, component; solution_format = :native, model = nothing)`: an old
`{component}.jld2` file (OutputVault 0.1 layout) is read as before; otherwise each property is read
by `read_object`: `name.jld2` -> `read_jld2` (dispatches on `"outputvault/kind"`, else `"value"`),
`name.{table ext}` -> `read_table` (dispatches on the `"outputvault.kind"` table metadata through
DataAPI). TFI's own `"tfi.kind"` stays in TFI's metadata for TFI's constructors; the core never
reads it. Steady states take their model from the one ModelSolution file in the same folder.

## TFI extension (OutputVaultTFIExt.jl)

File layouts (schema version 2) are documented at the top of the file and in `docs/src/guide/tfi.md`.
The schema version is an integer bumped only on breaking changes; no backward-compatible readers.
Storage kinds: ModelSolution, SteadyState, MomentArray, SimulationPanel, SimulationErrorPanel,
IRFResult (two tables: statistics and `_paths`), Interpolant (grid and one array per variable,
`recursions/<name>.jld2`), `SamplesTuple` (one table per sample). A `MomentArray` is written as it
is: its row key (a type parameter in TFI) names the column of row names.
Model metadata (`model_metadata`, `model_from_metadata`) are owned by OutputVault; the extension
defines them for `TFI.AbstractModel` (fields kept recursively: reals, strings, symbols, numeric
arrays/tuples up to 1000 elements, depth 4), and model packages overload them for their own types.
`collect_parameters(obj_or_model)` -> one-column MomentArray (`parameter` rows) of every scalar real
field; `TFI.compare_economies(moments, NamedTuple of RunHandle)` loads each run's stats (and IRFs for
`ImpulseMoment`s).

## DuckDB (sql/outputvault.sql, OutputVaultDuckDBExt.jl)

Macros are long-form and take the root, `branch_glob`, `experdef_glob` and (per-economy
components) an `economies` list as named arguments; the economy-split forms take all five
positional arguments (named defaults make shorter positional forms ambiguous in DuckDB). The
column of row names differs per file (`variable`, `equation`, `parameter`: the TFI row key), so
there is one long-form macro each. `assemble_moments(root, moments; branch, experdef, economies)`
queries only runs that have the component (`vault_runs` lists runs from their solution folders
without opening data files; a pattern that matches no file is an error in DuckDB), one query per
kind of moment, returning the long table TFI's `MomentTable` reads.

## Discovery (discovery.jl)

`get_results_folders(cfg, economies; experdef, branch)` -> NamedTuple of RunHandles.
`find_matching_results(cfg, wildcard; key_format)` -> globs the output root, parses
`res-{experdef}-{economy}`, keys by the shortest unique combination (`:auto`) or `key_format`.

## Exports

```julia
RunHandle, Config, TableFormat, LAYOUT
set_config!, with_config, output_path
save_result, load
save_solution, load_solution, save_steadystate, load_steadystate
model_metadata, model_from_metadata, collect_parameters
find_matching_results, get_results_folders
duckdb_sql_path, duckdb_statements, assemble_moments
```

Not exported (`OutputVault.` prefix): `AbstractConfig` and accessors, `AbstractTableFormat`,
`Formats`, the producer interface, `global_config`, `economy_folder`, `current_branch`,
`is_repo_clean`, `get_commit_id`.

## Who uses it

A downstream model project configures it with a `Config` using `ParquetFormat`, saves runs through it
and reads them with `assemble_moments`. An older project is pinned to OutputVault 0.1.0 and has no
table format (upgrading is a separate task after 0.2.0 is released).

## Tests

One file per source file (`test_types.jl`, `test_filesystem.jl`, `test_git.jl`, `test_save_load.jl`,
`test_global_config.jl`, `test_discovery.jl`), plus `test_tfi.jl` (every TFI type through
`save_result`/`load` with Parquet, both kind keys in the file, refusal without a table format,
allocations when restoring a MomentArray from Parquet; fixtures in `tfi_fixtures.jl` from TFI's NGM
example) and `test_duckdb.jl` (macros over a temporary root, filters, economy split, Windows
separators, `assemble_moments`), and `test_lifecycle.jl` (the docs' run lifecycle across processes: save,
portable reload in a fresh Julia process with the model type only, simulate, late IRF save, solution
folder untouched), and `test_quickstart.jl` (the model-free quick start: a tiny producer type, adding a
result later, replacement on saving a solution, a DuckDB query). The producer interface is tested in `test_save_load.jl` with a test-only kinded
type.
