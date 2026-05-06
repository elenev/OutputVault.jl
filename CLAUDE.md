# OutputVault.jl -- Technical Notes for Claude

## Package purpose

OutputVault organizes model output files by git branch, experiment definition,
and economy name. It records git provenance (commit ID + diffs) with saved
results. It is a library: consuming packages supply project-specific
configuration, typically in their `__init__`.

## Source layout

```julia
src/
  OutputVault.jl   -- module shell: usings, exports, includes (in dependency order)
  git.jl           -- git utilities (LibGit2 + shell commands)
  types.jl         -- RunHandle, AbstractConfig, Config, accessor methods
  global_config.jl -- module-level config ref, set_config!, with_config
  filesystem.jl    -- output_path, economy_folder
  save_load.jl     -- FileIO.load extensions, save_result
  discovery.jl     -- find_matching_results, get_results_folders, key helpers
ext/
  OutputVaultTFIExt.jl -- weak-dep extension: compare_economies overload for
                          NamedTuple{K, NTuple{N, RunHandle}}
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

Defaults for `git_component` (`:solution`) and `skip_components` (`(:simulation,)`)
are provided via `Config` keyword argument defaults, not on `AbstractConfig`.

`Config{C<:NamedTuple, N} <: AbstractConfig` (types.jl) -- concrete, data-driven
implementation. Stores all four values as fields; accessor methods simply return
the fields. Constructed via keyword constructor:
`Config(; output_root, components, git_component=:solution, skip_components=(:simulation,))`

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
If dirty: temporarily intent-stages untracked files (`git add -N`), captures
staged and unstaged diffs, then resets. `check_clean` can be `:warn`, `:error`,
or `:ignore`. Internal only; called by `save_result`.

`_get_git_diff(staged)` -- runs `git diff` or `git diff --staged`, returns
empty string if diff exceeds 1 MB.

## I/O (save_load.jl)

`FileIO.load(cfg, rf, component)` -- extended FileIO dispatch:

1. Resolves path via `economy_folder`.
2. Loads the `.jld2` file with FileIO's own `load(path)`.
3. Looks up `props = components(cfg)[component]`.
4. Returns `NamedTuple{props}(...)` keyed by those property names.

`FileIO.load(rf, component)` -- no-config wrapper.

`save_result(cfg, rf, result; skip, dirty_repo_check)`:

- Calls `get_commit_id` once.
- Iterates `pairs(components(cfg))`; skips any component in `skip`.
- For each component, builds a `Dict{String,Any}` from `getproperty(result, p)`
  for each `p` in the component's property tuple.
- For the `git_component`, injects `"git_commit_id"` and `"git_diffs"`.
- Saves with `jldsave(path; data...)`.
- Returns the economy folder path.

`save_result(rf, result; kwargs...)` -- no-config wrapper.

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
RunHandle, Config          # types
set_config!, with_config      # config management
output_path                   # path utility
save_result                   # saving
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

## Unit test surface (what to test)

- `types.jl`: Config constructor correctly captures all fields; accessor
  methods return the right values; `AbstractConfig` required methods throw.
- `filesystem.jl`: `economy_folder` path construction from branch/experdef/economy
  fields; `create=true` creates missing directories; `create=false` errors.
- `git.jl`: `is_repo_clean`, `current_branch` on a test repo; `get_commit_id`
  returns a 40-char hex string; diff capture on a dirty repo.
- `save_load.jl`: round-trip save/load produces the correct NamedTuple; `skip`
  keyword omits components; git metadata keys appear in the solution `.jld2`
  and not in other components; dirty-repo check behavior.
- `global_config.jl`: `set_config!` stores and `global_config()` retrieves;
  `with_config` restores the prior config even if `f()` throws; unset config
  throws.
- `discovery.jl`: `_rf_key` for each format; `_auto_key_format` selects
  shortest unique format; `find_matching_results` on a known folder tree;
  `get_results_folders` key/value structure.
