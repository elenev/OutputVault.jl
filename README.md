# OutputVault.jl

## Problem

Research model runs produce output across many git branches, experiment
definitions, and parameter configurations. It is easy to lose track of which
code version produced a given set of results, especially when runs are long and
the output directory accumulates results from many development cycles.

## Approach

OutputVault organizes outputs under a configurable root directory in a
three-level hierarchy: `branch/res-{experdef}-{economy}/component.jld2`. Each
component is a `.jld2` file containing named fields extracted from the result
object. The file designated as the "solution" component also stores the git
commit ID and staged/unstaged diffs at the time of the save.

Project-specific behavior (output root, component definitions) is injected
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
        )
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

`save_result` warns (or errors, if `dirty_repo_check=:error`) when the
repository has uncommitted changes, and stores the diff alongside the commit
ID in the solution file.

## Loading results

```julia
rb = RunHandle("baseline")
sol  = load(rb, :solution)     # returns NamedTuple{(:obj, :stv), ...}
stat = load(rb, :stats)        # returns NamedTuple{(:stats,), ...}
```

To load from a specific branch or experiment definition:

```julia
rb = RunHandle("baseline"; branch="feature-x", experdef="highrisk")
sol = load(rb, :solution)
```
