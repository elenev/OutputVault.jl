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
save_result(rf, (; obj, stv, stats))               # without the simulation
save_result(rf, (; irf))                           # IRFs computed later: added to the folder
save_result(rf, (; claims))                        # a recursion computed later
```

A save with `obj` or `stv` replaces the run's folder ([Runs and the Layout](@ref)). The keyword
`dirty_repo_check` (`:warn`, the default; `:error`; or `:ignore`) controls what happens when the
repository has uncommitted changes.

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
is either a model instance, which is compared with the stored metadata (a warning lists what
differs), or a model type, which is rebuilt from the metadata with [`model_from_metadata`](@ref).
Single files can be read directly with `load_solution(path, model)` and `load_steadystate(path, model)`.
Moment tables saved by sample load as a `NamedTuple` with the samples in the order they were saved.

## Finding runs

```julia
get_results_folders(["base", "alt"]; experdef = "v1")   # (base = RunHandle, alt = RunHandle)
find_matching_results("main/res-v1-*")           # glob the output root, parse the folder names
```

[`find_matching_results`](@ref) returns a `NamedTuple` of `RunHandle`s keyed by the shortest
combination of names that is unique (`economy`, then `experdef_economy`, then
`branch_experdef_economy`), or by the `key_format` you pass. Folders whose names do not parse as
`res-<experdef>-<economy>` are ignored.

## Where things are

```julia
output_path()                       # <output_root>/<current branch>, created if absent
OutputVault.economy_folder(rf)      # <output_root>/<branch>/res-<experdef>-<economy>
```
