# Runs and Storage

## Runs

A run is the saved results of one configuration of a model, in one folder:

```
<output_root>/<branch>/res-<experdef>-<variant>/
├── native.jld2       the solution as Julia objects (optional)
├── provenance/       git_commit.txt  [git_staged.diff  git_unstaged.diff]
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

A run starts with its solution. [`save_solution`](@ref) replaces the whole run, so a run never mixes
results computed from two solutions. Result items are then saved with
[`save_result_item`](@ref), at any time and in any order, at paths chosen when the code runs.
OutputVault fixes no layout of possible outputs: it fixes only the grammar above and the reserved
top-level names `solution`, `provenance` and `native`.

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
4. Otherwise it writes `p.jld2` with [`write_jld2`](@ref): the Julia object, unless the type's
   package defines its own layout.

Saving at a path first removes what is there, in every form (`p.<ext>`, `p.jld2`, `p/`), so saving
`stats` replaces the whole folder, including samples saved separately as `stats/boom`; to add one
sample, save `stats/boom`. Saving below an item that is a file (`irf/tfp` when `irf.jld2` exists) is an
error. Each item is written to a temporary name next to it and then renamed into place, so readers
never see half an item.

## Reading returns data

OutputVault reads data and never lets a file choose the code that reads it:

- a table file is read into memory as a [`StoredTable`](@ref OutputVault.Formats.StoredTable), its
  columns with the file's metadata; no file handle stays open;
- a folder is a NamedTuple of its items, in alphabetical order;
- a `.jld2` file is a Dict of its contents.

Turning data into a package's types is driven by the type the caller passes:
`load_result_item(rf, path, T)` calls `from_storage(T, data)` for a table or a folder and
`read_jld2(T, io)` for a `.jld2` file ([Frontends](@ref)). `from_storage` sees only the item's own data,
so values that are only meaningful together belong in one item.

## Provenance

`save_solution` records the git state of the repository of the active project
(`Base.active_project()`), whatever the working directory, in `provenance/`:

- `git_commit.txt`: the commit, and one line `submodule <path> <commit>` per submodule;
- if the repository is dirty, `git_staged.diff` and `git_unstaged.diff`. The unstaged diff includes
  untracked text files, up to 1 MB in total (one line in the diff says when the rest was left out);
  binary files are skipped. Submodules contribute their commits, not their diffs.

`dirty_repo_check` (`:warn`, `:error` or `:ignore`) says what to do when the repository is dirty or
when there is no repository (then `git_commit.txt` says so). The repository's index is never written.
Result items record no provenance: they belong to the solution of their run.

## Runs saved with OutputVault 0.3

Runs saved with OutputVault 0.3 load without changes. Their provenance is in `solution/` and their
native copy is `solution/res.jld2`: `load_result_item(rf, "solution"; native = true)` reads it there,
and reading `solution` skips it. Their other items are at the same paths as before. Runs saved with
OutputVault 0.1 are not supported.
