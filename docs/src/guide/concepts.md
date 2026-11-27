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

A [`RunHandle`](@ref) names a run. The variant may contain ASCII letters, digits and `_ . + = -`;
the experiment name may contain the same characters except `-`. A branch may contain `/`, but
none of its levels may start with `res-` or `.`.

The branch defaults to the active Julia project's git branch ([`current_branch`](@ref)). The
recorded commit and diffs also come from that project's repository, even if you start Julia in
another folder. Pass `branch` explicitly when the project is outside a repository or on a
detached HEAD.

A handle only identifies a run; it creates no files. Changing the active configuration changes
which output root that same handle refers to. Passing `branch` chooses a folder and does not switch
git branches or change the source of provenance.

A run starts with its solution. [`save_solution`](@ref) replaces the whole run, so a run never mixes
results computed from two solutions. Result items are then saved with
[`save_result_item`](@ref), at any time and in any order, at paths chosen when the code runs. The top-level names `solution` and `native` are reserved;
the git record is kept separately in `.provenance/`.

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
never see half an item. The old item is renamed aside first and deleted last, so a save that fails
leaves it as it was. On Windows, an old copy holding a file that is still open cannot be deleted: it
stays beside the new item under a hidden name, and a warning names it.

## Reading returns data

OutputVault returns the following data when no type is supplied:

- a table file is a [`StoredTable`](@ref OutputVault.Formats.StoredTable), its columns with the
  file's metadata;
- a folder is a NamedTuple of its items, in alphabetical order;
- a `.jld2` file is a Dict of its contents.

To restore an object of your own type, use `load_result_item(rf, path, T)`. Define
`from_storage(T, data)` for a table or folder, or `read_portable_jld2(T, io)` for a `.jld2` file;
see [Storing Your Own Types](@ref).

JLD2 reconstructs the Julia objects stored in its files, so reading them may require the original
types and compatible code. For files that must also be read by other languages or later code,
define a layout of ordinary arrays, numbers and strings.

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

## Reading older runs

Runs saved with OutputVault 0.3 load without changes. Their provenance is in `solution/` and their
native copy is `solution/res.jld2`. Use `load_result_item(rf, "solution"; native = true)` to read
that copy. Runs saved with OutputVault 0.1 are not supported.
