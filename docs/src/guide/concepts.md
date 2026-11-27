# Runs and Storage

## Runs

A run is the saved results of one configuration of a model, in one folder:

```
<output_root>/<branch>/res-<experdef>-<variant>/
├── native.jld2       the solution as Julia objects (optional)
├── .provenance/      git_commit.txt  [git_staged.diff  git_unstaged.diff]
├── solution/ …       the solution, by the storage rules
└── <result items> …  saved at paths chosen by the caller
```

| Part | Meaning |
|:--|:--|
| output root | the top folder of a project's runs (`Config(; output_root)`) |
| branch | the git branch the run belongs to; may contain `/`, which gives nested folders |
| experdef | the experiment definition: a set of runs designed together |
| variant | one configuration within an experdef |

A [`RunHandle`](@ref) names a run. Its names are checked when it is made: the variant uses only
`A–Z`, `a–z`, `0–9` and `_ . + = -`, which is safe on every operating system and in shell commands;
the experdef uses the same characters without `-`, so the folder name splits at its first hyphen; no
level of the branch starts with `res-` or `.`. The branch defaults to the git branch of the active
project's repository ([`current_branch`](@ref)).

The branch and the git record ([Provenance](@ref)) come from the repository of the active project,
not from the working directory, so they belong to the code that ran even when Julia was started
elsewhere. (OutputVault 0.3 used the working directory.) When the active project is not in a git
repository, or on a detached HEAD, `RunHandle` needs `branch`: for example with the global
environment active, or under `Pkg.test`, whose active project is a temporary environment. Tests either pass `branch` or create a
throwaway repository and activate its project.

A handle only identifies a run; it creates no files. Changing the active configuration changes
which output root that same handle refers to. Passing `branch` chooses a folder and does not switch
git branches or change the source of provenance.

A run starts with its solution. [`save_solution`](@ref) replaces the whole run, so a run never mixes
results computed from two solutions. Result items are then saved with
[`save_result_item`](@ref), at any time and in any order, at paths chosen when the code runs.
OutputVault fixes no layout of possible outputs: it fixes only the grammar above and the reserved
top-level names `solution` and `native` (`.provenance` cannot be an item path, since names have no `.`).

## Paths

An item's path is relative to the run folder, with levels separated by `/` (`"stats"`,
`"irf/ss/stats"`). Each level is a nonempty file name without `/`, `\` or `.`. The file extension is
added by the storage rules.

## Storage rules

OutputVault writes a value `v` at path `p` as follows.

1. It computes `s = to_storage(v)` ([`to_storage`](@ref); `v` itself unless a package says
   otherwise).
2. If `s` is a table, it writes one table file `p.<ext>` with the configured table format and the
   table's own file-level metadata (`DataAPI.metadata`). A NamedTuple of equal-length vectors is a
   table; a NamedTuple of vectors of unequal lengths is an error naming the path. Writing a table
   without a table format in the configuration is an error.
3. Else, if `s` is a NamedTuple, it writes a folder `p/`, with each member `m` at `p/m` by these same
   rules, `to_storage` included.
4. Otherwise it writes `p.jld2` with [`write_portable_jld2`](@ref): the Julia object, unless the type's
   package defines its own layout.

Saving at a path replaces what is there, in every form (`p.<ext>`, `p.jld2`, `p/`), so saving
`stats` replaces the whole folder, including samples saved separately as `stats/boom`; to add one
sample, save `stats/boom`. Saving below an item that is a file (`irf/tfp` when `irf.jld2` exists) is an
error. Each item is written to a temporary name next to it and then renamed into place, so readers
never see half an item.

## Reading returns data

OutputVault returns the following data when no type is supplied:

- a table file is a [`StoredTable`](@ref OutputVault.Formats.StoredTable), its columns with the
  file's metadata;
- a folder is a NamedTuple of its items, in alphabetical order;
- a `.jld2` file is a Dict of its contents.

The type used for a frontend conversion always comes from the caller. JLD2 itself can reconstruct
Julia objects stored in a file; an ordinary `.jld2` item is therefore not automatically portable
across languages or code versions. A frontend can define a plain-data layout for it.

Turning data into a package's types is driven by the type the caller passes:
`load_result_item(rf, path, T)` calls `from_storage(T, data)` for a table or a folder and
`read_portable_jld2(T, io)` for a `.jld2` file ([Frontends](@ref)). `from_storage` sees only the item's own data,
so values that are only meaningful together belong in one item.

## Provenance

`save_solution` records the git state of the repository of the active project
(`Base.active_project()`), whatever the working directory, in `.provenance/`:

- `git_commit.txt`: the commit, and one line `submodule <path> <commit>` per submodule;
- if the repository is dirty, `git_staged.diff` and `git_unstaged.diff`. The unstaged diff includes
  untracked text files, up to 1 MB in total (one line in the diff says when the rest was left out);
  binary files are skipped. Submodules contribute their commits, not their diffs.

`dirty_repo_check` (`:warn`, `:error` or `:ignore`) says what to do when the repository is dirty or
when there is no repository (then `git_commit.txt` says so). The repository's index is never written.
Result items record no provenance: they belong to the solution of their run.

OutputVault does not lock runs. Coordinate writers to the same run yourself; separate runs can be
written independently. Commit the project's `Manifest.toml` when the recorded commit should also
identify the package versions used.

## Runs saved with OutputVault 0.3

Runs saved with OutputVault 0.3 load without changes. Their provenance is in `solution/` and their
native copy is `solution/res.jld2`: `load_result_item(rf, "solution"; native = true)` reads it there,
and reading `solution` skips it. Their other items are at the same paths as before. Runs saved with
OutputVault 0.1 are not supported.
