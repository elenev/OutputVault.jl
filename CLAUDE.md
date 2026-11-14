# OutputVault.jl -- Technical Notes for Claude

## Package purpose

OutputVault organizes model output files by git branch, experiment definition,
and economy name, stores objects by type (TFI types in plain, portable formats),
and records git provenance (commit ID + diffs) with the solution. It is a
library: consuming packages supply project-specific configuration, typically in
their `__init__`. All file I/O for TransitionFunctionIteration lives here
(decided 2026-11-13/14): TFI only provides in-memory objects, their Tables.jl
interfaces and DataAPI metadata (as strings, ready for any writer).

## Source layout

```julia
src/
  OutputVault.jl   -- module shell: usings, exports, includes (in dependency order)
  git.jl           -- git utilities (LibGit2 + shell commands)
  types.jl         -- RunHandle, AbstractConfig, TableFormat, Config, accessor methods
  global_config.jl -- module-level config ref, set_config!, with_config
  filesystem.jl    -- output_path, economy_folder
  save_load.jl     -- FileIO.load, save_result, producer interface (storage_kind,
                      write_object, write_table, jld2_record, recorded_kind,
                      read_kind), stubs for
                      save_solution, load_solution, save_steadystate,
                      load_steadystate, model_metadata, model_from_metadata
  discovery.jl     -- find_matching_results, get_results_folders, key helpers
ext/
  OutputVaultTFIExt.jl -- extension (triggers: TFI, StaticArrays, StructArrays,
                          all loaded with TFI): writers/readers for TFI types,
                          solution and steady-state file layouts, model_metadata
                          for TFI models, compare_economies over RunHandles
```

## Key types

`RunHandle` (types.jl) -- identifies one saved run:

- fields: `branch::String`, `experdef::String`, `economy::String`
- constructor `RunHandle(economy; branch, experdef)` -- branch defaults to
  `current_branch()` (live git query)

`AbstractConfig` (types.jl) -- interface for project-specific configuration.
Required methods (all error if called on a bare AbstractConfig subtype):

- `output_root(cfg) -> String` -- filesystem root for all outputs
- `components(cfg) -> NamedTuple` -- maps component Symbol to tuple of property
  Symbols, e.g. `(solution=(:obj,:stv), stats=(:stats,))`
- `git_component(cfg) -> Symbol` -- which component receives git metadata
- `skip_components(cfg) -> Tuple{Vararg{Symbol}}` -- components omitted by
  default in save_result
- optional `table_format(cfg)` -- a `TableFormat` or `nothing` (default; tables
  cannot be saved)

`TableFormat(; ext, write, read)` (types.jl) -- user-supplied table I/O:
`write(path, table, meta)` (table plus file-level string metadata `meta`),
`read(path)` returning a Tables.jl source with metadata.
OutputVault does not depend on any table format package (no Parquet2). CSV
support is postponed: loading assumes files carry their own metadata.

Defaults for `git_component` (`:solution`) and `skip_components` (`(:simulation,)`)
are provided via `Config` keyword argument defaults, not on `AbstractConfig`.

`Config{C<:NamedTuple, N} <: AbstractConfig` (types.jl) -- concrete, data-driven
implementation. Stores all five values as fields; accessor methods simply return
the fields. Constructed via keyword constructor:
`Config(; output_root, components, git_component=:solution, skip_components=(:simulation,), table_format=nothing)`

## Global config (global_config.jl)

`_GLOBAL_CONFIG::Ref{Union{AbstractConfig,Nothing}}` -- module-level ref,
initially nothing.

`set_config!(cfg)` -- stores cfg; called in consuming package's `__init__`.

`with_config(f, cfg)` -- scoped override; restores previous config in a
finally block. Useful for tests and multi-project REPL sessions.

`global_config()` -- returns current config or throws if unset. Called by all
no-config variants of public functions.

## Filesystem (filesystem.jl)

`output_path(cfg, branch)` -- returns `output_root(cfg)/branch`, creating it
if absent.

`economy_folder(cfg, rf; create)` -- returns
`output_root(cfg)/branch/res-{experdef}-{economy}`. Errors if folder is absent
and `create=false`. Creates with `mkpath` if `create=true`.

Both have no-config wrappers that call `global_config()`.

## Git utilities (git.jl)

`current_branch()` -- LibGit2 query on repo at `.`.

`is_repo_clean()` -- true iff `GitStatus` is empty.

`get_commit_id(check_clean)` -- returns `(commit_id::String, diffs::NamedTuple)`.
If dirty: staged diff from the real index (read only); unstaged diff computed
against a temporary copy of the index (`GIT_INDEX_FILE`) in which untracked
files are intent-added (`git add -N .`), deleted afterwards. The repository's
index is never modified. `check_clean` can be `:warn`, `:error`, or `:ignore`.
Internal only; called by `save_result`.

`_get_git_diff(staged)` -- runs `git diff` or `git diff --staged`, returns
empty string if diff exceeds 1 MB.

## I/O (save_load.jl)

Layout: `economy_folder/{component}/{property}.{ext}`. The git component folder
also gets `git_commit.txt` and, if dirty, `git_staged.diff` / `git_unstaged.diff`.

`save_result(cfg, rf, result; skip, dirty_repo_check)`: calls `get_commit_id`
once; if the git component is not skipped, deletes the economy folder (one
folder = results of one solution; decided 2026-11-14, stale diffs and old
simulations next to a new solution were the reason); for each component not skipped, makes its folder, writes the git files
(git component only, whose objects get `provenance = Dict("git_commit_id" => id)`),
then `write_object(cfg, dir, string(p), getproperty(result, p); provenance)` for
each property.

Producer interface (decided 2026-11-14; the core never names a producer's keys,
producers never name the core's):

- `storage_kind(x)` -- producers define it for their types, namespaced by
  package ("TransitionFunctionIteration.ModelSolution"); default `nothing`.
- `write_object(cfg, dir, name, x; provenance)` -- producers add methods built on
  `write_table(cfg, stem, table)` (passes `Dict("outputvault.kind" => kind)` as
  the format's `meta`) or `jld2_record(f, path, x)` (writes `"outputvault/kind"`
  then calls `f(io)`). Core method: JLD2 `name.jld2` with key `"value"`, no kind.
- `read_kind(Val(kind), path)` / `read_kind(Val(kind), source, path, fmt)` --
  producers' readers. `recorded_kind(path)` reads a JLD2 file's kind.
- Not exported; producers extend them as `OutputVault.storage_kind` etc.

`FileIO.load(cfg, rf, component)`: an old `{component}.jld2` file (OutputVault
0.1 layout) is read as before; otherwise each property is read by `read_object`:
`name.jld2` -> `read_jld2` (dispatches on `"outputvault/kind"`, else returns
`"value"`); `name.{table ext}` -> `read_table` (dispatches on the
`"outputvault.kind"` table metadata, read through DataAPI). TFI's own
`"tfi.kind"` stays in TFI's table metadata for TFI's constructors; the core
never reads it. Steady states take their model from the one ModelSolution file
in the same folder.

The TFI extension's file layouts (schema version 1) are documented at the top
of `ext/OutputVaultTFIExt.jl`. Model metadata (`model_metadata`,
`model_from_metadata`) are owned by OutputVault; the extension defines them for
`TFI.AbstractModel`, and model packages overload them for their own types.

## Discovery (discovery.jl)

`get_results_folders(cfg, economies; experdef, branch)` -- constructs a
NamedTuple of `RunHandle`s keyed by economy name.

`find_matching_results(cfg, wildcard; key_format)` -- globs the output root,
parses folder names matching `res-{experdef}-{economy}`, returns a NamedTuple
of `RunHandle`s. `key_format` can be `:auto`, `:economy`,
`:experdef_economy`, or `:branch_experdef_economy`. Auto-selects the shortest
format that yields unique keys.

`_rf_key(rf, format)` and `_auto_key_format(rfs)` -- internal helpers.

## Exports (public API)

```julia
RunHandle, Config, TableFormat   # types
set_config!, with_config      # config management
output_path                   # path utility
save_result                   # saving
save_solution, load_solution, save_steadystate, load_steadystate  # single files
model_metadata, model_from_metadata                               # model hooks
load                          # FileIO.load re-export (extended by save_load.jl)
find_matching_results, get_results_folders  # discovery
```

Not exported (accessed via `OutputVault.` prefix):

- `AbstractConfig` and all accessor methods (`output_root`, `components`,
  `git_component`, `skip_components`) -- for custom config implementors
- `global_config`, `economy_folder`, `output_root`, `current_branch`,
  `is_repo_clean`, `get_commit_id` -- internal

## How SimpleAusterityThreshold uses this package

- `Project.toml`: depends on OutputVault.
- `SimpleAusterityThreshold.jl`: `import OutputVault`; defines `__init__`
  calling `OutputVault.set_config!(OutputVault.Config(...))` with SAT's output
  root, components, and defaults.
- `io.jl`: `using OutputVault` (brings exported names into SAT namespace);
  defines a convenience `save_result(result, economy_name; ...)` wrapper that
  maps a `save_simulation` flag to OutputVault's `skip` keyword.
- `analysis.jl`: defines a `compare_economies(economies::NamedTuple{...NTuple{N,RunHandle}...})`
  overload that injects SAT-specific moments before delegating to TFI.
- Pending (postponed by the user, 2026-11-14): SAT's Config has no `table_format`, so with the
  typed-formats layout its stats, errstats, simulation and irf components raise until it adds
  one (and a Parquet2 dependency).

## Unit test surface (what to test)

- `types.jl`: Config constructor correctly captures all fields; accessor
  methods return the right values; `AbstractConfig` required methods throw.
- `filesystem.jl`: `economy_folder` path construction from branch/experdef/economy
  fields; `create=true` creates missing directories; `create=false` errors.
- `git.jl`: `is_repo_clean`, `current_branch` on a test repo; `get_commit_id`
  returns a 40-char hex string; diff capture on a dirty repo.
- `save_load.jl`: round-trip save/load produces the correct NamedTuple; `skip`
  keyword omits components; git files appear in the solution folder only;
  untracked files appear in the unstaged diff; 0.1-layout components load;
  dirty-repo check behavior.
- `git.jl`: staged changes stay staged after `get_commit_id`.
- TFI (`test/test_tfi.jl`, fixtures in `test/tfi_fixtures.jl` from TFI's NGM
  example and forecasting test): solution and steady-state files, every TFI type
  through save_result/load with parquet, both kind keys in the parquet file,
  refusal without a table format, and allocations when restoring a MomentArray
  from parquet (moved from TFI, whose own tests use an in-memory metadata table). The producer interface itself is tested in
  `test_save_load.jl` with a test-only kinded type.
- `global_config.jl`: `set_config!` stores and `global_config()` retrieves;
  `with_config` restores the prior config even if `f()` throws; unset config
  throws.
- `discovery.jl`: `_rf_key` for each format; `_auto_key_format` selects
  shortest unique format; `find_matching_results` on a known folder tree;
  `get_results_folders` key/value structure.
