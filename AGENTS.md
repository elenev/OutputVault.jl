# OutputVault.jl

Storage for the results of research model runs. Each run is a folder
`<output_root>/<branch>/res-<experdef>-<economy>`; its solution is saved with the git commit and
diffs of the code that produced it. All file I/O for TransitionFunctionIteration (TFI) types lives
here: TFI supplies in-memory objects, their Tables.jl interfaces and DataAPI.jl metadata.

## Commands

```sh
julia --project -e 'using Pkg; Pkg.test()'    # tests
julia --project=docs docs/make.jl             # documentation, including the executed examples
```

The test and docs environments load TFI from the sibling folder `../TransitionFunctionIteration`,
so both run against whatever is checked out there.

## Where things are

| Topic | Location |
|---|---|
| Layout, run identity, configuration, table formats | `src/types.jl` |
| Save, load, folder replacement, producer interface | `src/save_load.jl` |
| Git provenance | `src/git.jl` |
| Finding runs | `src/discovery.jl` |
| TFI types and their file layouts (documented at the top) | `ext/OutputVaultTFIExt.jl` |
| Parquet table format | `ext/OutputVaultParquet2Ext.jl` |
| DuckDB queries and moments | `sql/outputvault.sql`, `src/duckdb.jl`, `ext/OutputVaultDuckDBExt.jl` |
| Design concepts and extension guide | `docs/src/guide/concepts.md`, `docs/src/guide/extending.md` |

## Invariants

Saved results

- `LAYOUT` is the same for every project. Extensions do not add components or objects.
- Saving `obj` or `stv` replaces the whole run folder through a staging folder. A failure must never
  lose or partly delete results. Other saves add to an existing run.
- `experdef` cannot contain `-`: readers split the folder name at the first hyphen after `res-`.
- Git provenance comes from the working directory's repository. Never modify that repository's index.

Extensions

- The core depends on no model package or table format; these are package extensions.
- The core does not use producers' metadata keys. Producers record storage kinds through
  `write_table` or `jld2_record`.

File formats

- Portable solution files hold plain arrays and metadata, uncompressed, so that h5py can read them.
- Bump the TFI schema version only for changes that break readers of earlier files. Readers accept
  only the current version. Components saved by OutputVault 0.1 must still load.
- A layout change must stay consistent across the writers and readers, `sql/outputvault.sql`,
  `momentrows` and the guides.

Windows

- Open or memory-mapped files block renames and deletes. Tests use `with_tempdir`, which collects
  garbage before removing the folder.

## Code style

- Short, modular functions with brief section comments. Keep diffs to existing code minimal.
- Early `return`, `continue` and `break` go in explicit `if` blocks, never `cond || return`.
- Fix a bug where it arises rather than adding optional arguments or helpers around it.

## Testing

- Run the tests before finishing a change.
- A failing test may point to a bug: diagnose it before changing the test.
- Use a temporary output root and a throwaway git repository, never a real one.
- Include order in `test/runtests.jl` matters: later files use fixtures from `tfi_fixtures.jl` and
  `test_tfi.jl`.
- The `@example` and `@repl` blocks of the quick start and lifecycle guides also run in fresh Julia
  processes (`test/test_docs.jl`), so each script needs its own `using` lines. A `@repl` block must
  throw.

## Documentation and releases

- Update docstrings and `docs/src` with any change in behavior. Write them for users, in terms of
  observable behavior.
- Set the TFI compat bound to the earliest release that has the API this package uses.
- Do not change the version in `Project.toml` unless asked.
