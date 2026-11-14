# OutputVault.jl

## Problem

Research model runs produce output across many git branches, experiment
definitions, and parameter configurations. It is easy to lose track of which
code version produced a given set of results, especially when runs are long and
the output directory accumulates results from many development cycles.

## Approach

OutputVault organizes outputs under a configurable root directory:
`branch/res-{experdef}-{economy}/{component}/{property}.{ext}`. Each component is a folder with
one file per property of the result object. The component designated for git (by default the
solution) also receives the commit ID (`git_commit.txt`) and, for a dirty repository, the staged
and unstaged diffs (`git_staged.diff`, `git_unstaged.diff`, including untracked files). The
diffs are computed without touching the repository's index.

Objects are stored by type. With TransitionFunctionIteration loaded, a `ModelSolution` goes to
an HDF5-compatible JLD2 file of plain arrays plus an exact copy of the model, a `SteadyState`
to plain data, and simulations, error panels, moment tables and IRFs to tables in a format the
project chooses (e.g. parquet), with their provenance in the file's metadata. Other objects are
stored with JLD2. Loading returns each object as its own type.

Project-specific behavior (output root, component definitions, table format) is injected
through a `Config` struct. For library authors who need more flexibility, the
`AbstractConfig` interface allows dispatch-based customization. The active
config is registered globally via `set_config!`, typically in the host
package's `__init__`, so downstream code calls `save_result` and `load`
without threading a config argument through the call stack.

## Installation

```julia
using Pkg
Pkg.add(url="git@github.com:elenev/OutputVault.jl.git")
```

## Saving results

Configure the vault in your package's `__init__` (or at the top of a script):

```julia
import OutputVault

function __init__()
    OutputVault.set_config!(OutputVault.Config(
        output_root     = "/path/to/outputs",
        git_component   = :solution,        # receives git metadata; default :solution
        skip_components = (:simulation,),   # skipped by default; default (:simulation,)
        components      = (
            solution   = (:obj, :stv),
            stats      = (:stats,),
            simulation = (:simseries, :errs),
        ),
        table_format    = TableFormat(ext = "parquet", read = Parquet2.Dataset,
            write = (path, table, meta) -> Parquet2.writefile(path, table; metadata = meta)),
    ))
end
```

Then save a result object whose fields match the declared component properties:

```julia
using OutputVault

rb = RunHandle("baseline")               # branch defaults to current git branch
save_result(rb, result)                     # skips :simulation by default
save_result(rb, result; skip=())            # save everything
```

Saving the git component (the solution) replaces the run's folder: everything saved
earlier for that run is deleted first, so the folder never mixes results of different
solutions. Saves that skip the solution (e.g. IRFs computed later) add to the folder.

`save_result` warns (or errors, if `dirty_repo_check=:error`) when the
repository has uncommitted changes, and stores the diffs alongside the commit
ID in the solution folder. Tables need a `table_format`; any Tables.jl writer and reader pair
works, but TFI's tables restore fully only from formats that keep table metadata (parquet).

## Loading results

```julia
rb = RunHandle("baseline")
sol  = load(rb, :solution)     # NamedTuple (obj = ModelSolution, stv = SteadyState)
stat = load(rb, :stats)        # returns NamedTuple{(:stats,), ...}
```

To load from a specific branch or experiment definition:

```julia
rb = RunHandle("baseline"; branch="feature-x", experdef="highrisk")
sol = load(rb, :solution)
```

Single files can be read directly: `load_solution(path)` (or with a model, or a model type, to
rebuild the model from the stored metadata) and `load_steadystate(path)`.

Components saved by OutputVault 0.1 (one `{component}.jld2` file per component) still load.

## Storing other packages' types

A package can have its types stored in formats of its own: define `OutputVault.storage_kind`
for them (a namespaced string), `OutputVault.write_object` methods that write through
`OutputVault.write_table` or `OutputVault.jld2_record` (which record the kind), and
`OutputVault.read_kind` methods that restore them. The TransitionFunctionIteration extension is
built this way.
