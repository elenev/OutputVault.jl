# Saving and Loading

## Configuration

Every OutputVault function uses the active configuration, set once with [`set_config!`](@ref) (a
project package typically calls it in its `__init__`) or for a block of code with
[`with_config`](@ref):

```julia
set_config!(Config(output_root = "/path/to/outputs",
                   table_format = OutputVault.Formats.ParquetFormat(),   # needed only to write tables
                   native = true))                                       # also write native.jld2
```

`staging_root` (default `<output_root>/.staging`) is where a solution's run is written before it is
renamed into place; it must be on the same file system as the runs. A project that computes its
settings (the root from the machine, say) defines a subtype of [`AbstractConfig`](@ref) instead.

## Solutions

```julia
save_solution(rf, (; obj, stv))                     # solution/obj.jld2, solution/stv.jld2, native.jld2
save_solution(rf, (; obj, stv); dirty_repo_check = :error)
```

[`save_solution`](@ref) writes the new run to a folder under the staging root, renames the old run to
a temporary name, renames the new one into place and deletes the old one. A failure at any point
leaves either the old run or the new one in place; if only the final delete fails, a warning names the
folder to delete.

The native copy, `native.jld2`, holds each member of the solution NamedTuple under its name:

```julia
load_result_item(rf, "solution"; native = true)     # (; obj, stv) as Julia objects, read with JLD2
load_result_item(rf, "solution")                    # the portable files: a NamedTuple of Dicts
load_result_item(rf, "solution/obj", T; context)    # one part restored as a T
```

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

A file that is open, or memory-mapped, cannot be renamed or deleted on Windows. OutputVault reads
tables into memory and closes its files, but a file opened by other code, or a shell or Julia session
whose working directory is inside the run, can make replacing a run fail. The error then leaves the old
run in place.
