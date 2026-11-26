# OutputVault.jl

Storage for the results of research model runs. Each run is a folder
`<output_root>/<branch>/res-<experdef>-<variant>/`: a solution, saved with the git provenance of the
active project's repository, and result items saved after it at paths chosen by the caller. Queries
across runs go through DuckDB. OutputVault knows no model package: a frontend (such as
TransitionFunctionIteration, through its own extension) defines the storage hooks for its types.

## Commands

```sh
julia --project -e 'using Pkg; Pkg.test()'    # tests
julia --project=docs docs/make.jl             # documentation, including the executed quick start
```

## Where things are

| Topic | Location |
|---|---|
| Table formats (self-contained submodule) | `src/Formats.jl`, `ext/OutputVaultParquet2Ext.jl` |
| Configuration | `src/config.jl` |
| Run identity, path grammar, globs | `src/runs.jl` |
| Git provenance, current branch | `src/git.jl` |
| Storage hooks and rules | `src/storage.jl` |
| save_solution, items, list_run, object files | `src/items.jl` |
| find_runs | `src/discovery.jl` |
| Queries | `src/query.jl`, `sql/outputvault.sql` |
| Design | `docs/src/guide/concepts.md`, `docs/src/guide/frontends.md` |

## Invariants

Saved results

- OutputVault fixes only the path grammar and the reserved top-level names `solution` and
  `native`; the provenance is in `.provenance/`. Every other name comes from the caller.
- `save_solution` replaces the whole run through a staging folder on the same file system; a failure
  must never lose or partly delete results. Result items are written to a temporary sibling and
  renamed into place.
- Names that start with `.` (staging, temporary and replaced folders) are never runs or items.
- `experdef` cannot contain `-`: the run folder splits at the first hyphen after `res-`.
- Provenance comes from the repository of the active project. Never write that repository's index.

Reading

- Reading never lets file contents choose code: a type comes only from the caller. `from_storage` has
  no generic method.
- `Formats` uses nothing else from OutputVault, so that it can become its own package.
- Queries open only the files of the selected runs and placeholder values (synced folders download
  what is opened).

Compatibility

- Runs saved with OutputVault 0.3 must keep loading (provenance and `res.jld2` in `solution/`).

Windows

- Open or memory-mapped files block renames and deletes. Parquet2 keeps files it has read mapped until
  garbage collection. Tests use `with_tempdir`, which collects garbage before removing the folder.

## Code style

- Short, modular functions with brief section comments. Keep diffs to existing code minimal.
- Early `return`, `continue` and `break` go in explicit `if` blocks, never `cond || return`.
- Fix a bug where it arises rather than adding optional arguments or helpers around it.

## Testing

- Run the tests before finishing a change.
- A failing test may point to a bug: diagnose it before changing the test.
- Use a temporary output root and a throwaway git repository made the active project
  (`with_vault` in `test/runtests.jl`), never a real one.
- The tests include a frontend that is not TFI (`test/test_frontend.jl`); OutputVault's tests do not
  load TransitionFunctionIteration.
- The `@example` blocks of the quick start also run in a fresh Julia process (`test/test_docs.jl`),
  so the script needs its own `using` lines.

## Documentation and releases

- Update docstrings and `docs/src` with any change in behavior. Write them for users, in terms of
  observable behavior.
- Do not change the version in `Project.toml` unless asked.
