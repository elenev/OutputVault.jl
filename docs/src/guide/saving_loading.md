# Saving and Loading

## Configuration

A [`Config`](@ref) holds a project's settings:

```julia
using OutputVault, Parquet2

cfg = Config(
    output_root     = "/path/to/outputs",
    table_format    = OutputVault.Formats.ParquetFormat(),
    solution_format = (:portable, :native),     # the default; or :portable, or :native
)
```

- `output_root`: where all runs are saved.
- `table_format`: how tables (simulations, moments, IRFs) are stored; see [Table Formats](@ref).
  Without one, saving a table is an error that says so.
- `solution_format`: which copies of the solution to save ([Runs and the Layout](@ref)).
- `staging_root`: where a replacing solution is written before it is moved into place (default: a
  folder in the system temp directory); see [Replacing a run](@ref).

Every function that needs a configuration takes one as its first argument, and has a form
without it that uses the active configuration. A package or script sets it once:

```julia
set_config!(cfg)                      # e.g. in a package's __init__
with_config(cfg2) do                  # scoped: the previous one is restored, even on an error
    save_result(rf, result)
end
```

For libraries that need more than the data in `Config`, a subtype of `OutputVault.AbstractConfig`
implements `output_root`, and optionally `table_format` and `solution_format`.

## Saving

```julia
rf = RunHandle("base"; experdef = "v1")
save_result(rf, (; obj, stv, stats, errstats, simseries, errs, irf, params))   # returns the run's folder
```

[`save_result`](@ref) saves the properties of the result that [`LAYOUT`](@ref) names. A property that
the result lacks, or that is `nothing`, is not saved, and properties outside the layout are ignored,
so one call can be as large or as small as you like:

```julia
save_result(rf, (; obj, stv, stats))               # a new run, without the simulation
save_result(rf, (; irf))                           # IRFs computed later: added to the run
save_result(rf, (; claims))                        # a recursion computed later
```

The first save of a run must include `obj` or `stv`. A save without them adds to an existing run,
replacing objects of the same name, and is an error (`Economy folder ... does not exist`) if the run
was never saved. A save with `obj` or `stv` replaces the whole run (below).

Each object is written by the package that supports its type: TFI's tables through the table format,
TFI's solutions in their plain-data layout ([TransitionFunctionIteration Objects](@ref)). Any other
value, including a Tables.jl table whose type no package supports, is saved with JLD2 as a Julia object.

The keyword `dirty_repo_check` (`:warn`, the default; `:error`; or `:ignore`) controls what a save with
a solution does when the repository has uncommitted changes. The repository is the one containing
Julia's working directory; `RunHandle`'s `branch` names the run's folder and does not change it.

### Replacing a run

A save with `obj` or `stv` puts a new run folder in place of the old one, in four steps:

1. it writes the new results to a folder in `staging_root`, `<staging_root>/<branch>/res-<experdef>-<economy>-<time>`;
2. it renames the existing run folder, if there is one, to `.replaced-res-<experdef>-<economy>-<time>`
   next to it;
3. it moves the staged folder to the run's path;
4. it deletes the renamed old folder.

`save_result` returns the folder holding the new results: the run's path when all goes well. On
Windows, an open file blocks renaming and deleting its folder, and Parquet2 keeps files it has read
open until Julia's garbage collector runs, so a load followed closely by a save can make a step fail.
Then a warning beginning `RESULTS NOT AT THE RUN'S PATH` gives the paths, or, for the last step, a
warning names the folder that could not be deleted:

| Step that failed | New results | Old results | Run's path |
|:--|:--|:--|:--|
| renaming the old folder (2) | staging folder (returned) | at the run's path, unchanged | the old results |
| moving the staged folder (3); the old folder renamed back | staging folder (returned) | at the run's path, unchanged | the old results |
| moving the staged folder (3); renaming back failed too | staging folder (returned) | the `.replaced-*` folder | empty |
| deleting the old folder (4) | at the run's path (returned) | the `.replaced-*` folder, to delete by hand | the new results |

So check the returned path, or watch for the warning, before relying on the run's path. To finish a
failed replacement, release whatever holds the files (close open files, leave the folder as a working
directory, run `GC.gc()`), then move the staging folder to the run's path. If a folder is at the run's
path, move it aside first; do not copy over it, which would mix the two runs. Folders whose names start
with `.replaced-` are ignored by `find_matching_results` and the DuckDB macros.

Saves without a solution write directly into the run folder, with none of these steps.

## Loading

```julia
load(rf, :stats)           # (stats = ...,)       the properties that were saved, in layout order
load(rf, :solution)        # (obj = ..., stv = ...)  the native copy
load(rf, :recursions)      # (claims = ..., welfare = ...) whichever exist
```

`load` returns a `NamedTuple` of the saved properties of a component, each restored as its own type.
It is `FileIO.load` extended; OutputVault re-exports it. For the solution:

```julia
load(rf, :solution; solution_format = :portable, model = MyModel)    # the portable copy
```

A portable solution stores the model's parameters as plain data. To rebuild the Julia object, `model`
is either a model instance, whose parameters are compared with the stored ones (a warning lists what
differs; changes to the model's code are not detected), or a model type, which is rebuilt from the metadata with [`model_from_metadata`](@ref).
Single files can be read directly, with the same choice of `model`: `load_solution(path, model)` and
`load_steadystate(path, model)`.
Moment tables saved by sample load as a `NamedTuple` with the samples in the order they were saved.

## Finding runs

```julia
get_results_folders(["base", "alt"]; experdef = "v1")       # (base = RunHandle, alt = RunHandle)
find_matching_results("main/res-v1-*")                      # (main__v1__alt = RunHandle, main__v1__base = RunHandle)
find_matching_results("main/res-v1-*"; key = :economy)      # (alt = RunHandle, base = RunHandle)
```

[`get_results_folders`](@ref) builds handles for economies you name, in one branch and experdef.
[`find_matching_results`](@ref) globs the output root and returns the runs whose folders match, in the
order of their paths. Folders whose names do not parse as `res-<experdef>-<economy>` are skipped.

Each run is named `<branch>__<experdef>__<economy>` (characters other than letters, digits and `_`
become `_`, so `feature/x` is `feature_x`). `key` picks fewer names: `key = :economy`,
`key = (:experdef, :economy)` or any other combination of `:branch`, `:experdef` and `:economy`. If two
runs would get the same name, for example `base` in two branches with `key = :economy`, it is an error
that lists them: narrow the pattern or use a longer key. [`split_by_economy`](@ref) names runs the same
way.

## Where things are

```julia
output_path()                       # <output_root>/<current branch> (create=true creates it)
OutputVault.economy_folder(rf)      # <output_root>/<branch>/res-<experdef>-<economy>
```
