# Saving and Loading

## Configuration

Choose an output folder and a table format with [`set_config!`](@ref). Subsequent saves, loads and
queries use these settings:

```julia
using OutputVault, Parquet2

set_config!(Config(output_root = "/path/to/outputs",
                   table_format = OutputVault.Formats.ParquetFormat(),   # needed only to write tables
                   native = false))                                      # skip native.jld2
```

Use [`with_config`](@ref) to save to a different folder for a block of code:

```julia
with_config(Config(output_root = mktempdir())) do
    trial = RunHandle("trial"; branch = "scratch")
    save_solution(trial, (; policy = [1.0, 1.1]))   # no tables, so no table format needed
end
```

The override applies within the block and to tasks it starts. Other tasks keep their settings.
Object files outside runs need no configuration.

For project-wide defaults, call `set_config!` when your project initializes. If you need to compute
settings dynamically, such as choosing a folder for the current machine, define a subtype of
[`OutputVault.AbstractConfig`](@ref).

`staging_root` defaults to `<output_root>/.staging`. Keep it on the same file system as the output
folder so completed runs can be renamed into place.

## Solutions

```julia
save_solution(rf, (; obj, stv))                     # solution/obj.jld2, solution/stv.jld2, native.jld2
save_solution(rf, (; obj, stv); dirty_repo_check = :error)
```

[`save_solution`](@ref) replaces the whole run, including previously saved result items, and returns
the new run's folder. Choose a different variant name when you want to keep the previous solution.

The new run is written in a staging folder before replacing the old one. If it cannot be moved
into place, `save_solution` returns its staging path and warns where both copies are. Follow the
warning's instructions before adding more results; see
[Files held open on Windows](#Files-held-open-on-Windows).

The native copy, `native.jld2`, holds each member of the solution NamedTuple under its name:

```julia
load_result_item(rf, "solution"; native = true)     # (; obj, stv) as Julia objects, read with JLD2
load_result_item(rf, "solution")                    # stored data; here a NamedTuple of Dicts
load_result_item(rf, "solution/obj", T; context)    # one part restored as a T
```

`native = true` bypasses storage hooks and needs the Julia types and compatible code that wrote the
file. Without it, `.jld2` items still contain Julia objects unless their package defines a portable
layout. For a solution that is not a NamedTuple, the native loader returns `(solution = value,)`.

## Result items

```julia
save_result_item(rf, "stats/uncond", table)         # a table file
save_result_item(rf, "irf/ss", (; stats, paths))    # a folder of two tables
load_result_item(rf, "irf/ss")                      # (; paths = StoredTable, stats = StoredTable)
load_result_item(rf, "irf/ss", MyIRF; context)      # from_storage(MyIRF, data; context)
move_result_item(rf, "irf/irf", "irf/ss/stats")     # moved unchanged
delete_result_item(rf, "irf/old")
```

The run must exist, so its solution must have been saved. Moving onto an existing item, or moving or
deleting the solution or a reserved name, is an error. [`list_run`](@ref) shows what a run holds:

```julia
c = list_run(rf)
c.provenance        # (commit = "…", dirty = false)
c.items             # a column table: path, kind (:table, :jld2, :folder), format
```

## Finding runs

[`find_runs`](@ref) lists runs from folder names alone, so no file is opened or downloaded:

```julia
find_runs()                                              # the runs of top-level branches
find_runs(RunPattern(branch = "**", experdef = "v1"))    # nested branches too
find_runs(RunPattern(variant = "frm*"); root = "/other/root")
```

A [`RunPattern`](@ref) has one glob per part of a run's name: `*` matches within one level, `?` one
character, `[...]` one character of a set, and `**` any number of levels.

## Objects outside a run

[`write_object_file`](@ref) and [`read_object_file`](@ref) save and restore one object in a `.jld2`
file anywhere, through the same JLD2 hooks as items:

```julia
write_object_file("obj.jld2", obj)
read_object_file("obj.jld2", T; context)
```

## Files held open on Windows

A file that is open, or memory-mapped, cannot be renamed or deleted on Windows. Parquet2 keeps the
files of tables it has read mapped until Julia's garbage collector frees them (`GC.gc()`); a file
opened by other code, or a shell or Julia session whose working directory is inside the run, also
holds it. When such a file blocks replacing a run, no run is lost or partly deleted:

- if the old run cannot be renamed aside, it stays where it is, the new run stays in the staging
  folder, and `save_solution` returns the staging folder with a warning that says where both are;
- if only the delete of the old run fails, the new run is in place and a warning names the old
  folder (`.trash-…` next to the run) to delete by hand.
