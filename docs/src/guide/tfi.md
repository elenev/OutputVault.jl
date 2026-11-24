# TransitionFunctionIteration Objects

`OutputVaultTFIExt` stores the types of
[TransitionFunctionIteration.jl](https://github.com/elenev/TransitionFunctionIteration.jl). It loads
when TransitionFunctionIteration is loaded. TFI's tables (simulations, moments, IRFs) are written with
the project's [table format](@ref "Table Formats"), so a `Config` that saves them needs one, such as
Parquet.

## What is stored where

| TFI type | Object | File | Format |
|:--|:--|:--|:--|
| `ModelSolution` | `solution/obj` | `obj.jld2` (and `res.jld2`) | plain arrays and metadata (JLD2) |
| `SteadyState` | `solution/stv` | `stv.jld2` | plain arrays and metadata (JLD2) |
| `describe(...).moments` | `stats/stats` | `<sample>.<ext>`, one per sample | table |
| `MomentArray` (error statistics) | `errstats/errstats` | `errstats.<ext>` | table |
| `SimulationPanel`, `SimulationErrorPanel` | `simulation/simseries`, `simulation/errs` | `simseries.<ext>`, `errs.<ext>` | table |
| `IRFResult` | `irf/irf` | `irf.<ext>` and `irf_paths.<ext>` | two tables |
| `MomentArray` (parameters) | `params/params` | `params.<ext>` | table |
| `Interpolant` | `recursions/claims`, `recursions/welfare` | `<name>.jld2` | plain arrays (JLD2) |

Every object records its storage kind (for example
`TransitionFunctionIteration.SimulationPanel`) in its file, and `load` restores the object as that
type.

## Solutions and steady states

The portable solution file holds plain HDF5-compatible arrays and metadata, with no Julia objects, so it
reads without the code that wrote it, in Python with h5py for example. Files are written
uncompressed because h5py cannot read JLD2's compressed datasets. Layout, schema version 2:

```
outputvault/kind                         storage kind
meta/{schema_version, tfi_version, created, solution_id, model_type, singletons}
meta/model/...                           the model's metadata (model_metadata)
meta/provenance/<key>                    strings from the caller (the git commit id)
grid/<axis>, grid/__axes                 grid vectors (a singleton axis has length 1) and their order
exogenv/points/<var>, .../__names        the exogenous states' values and their order
exogenv/mtrans, exogenv/ssidx            transition matrix and steady-state index
Pfct/<var>, Vfct/<var>, Ffct/<var>       arrays over the grid axes (Pfct in unconstrained space)
Tfct/<var>                               arrays over the grid axes and next period's exogenous state
<fct>/__vars                             variable order
Pfct/__bounds/<var>, Tfct/__bounds/<var> [lower, upper], plus __names
```

A steady-state file has `meta/...`, the model's metadata under `meta/model/`, and `guess/`, `endog/`,
`exog/`, `values/` (one entry per name plus `__names`). Like a solution, it loads with a model you
supply, either an instance that is compared with the saved metadata or a type that is rebuilt from it:

```julia
load(rf, :solution; solution_format = :portable, model = MyModel)    # (obj = ..., stv = ...)
load_steadystate(joinpath(OutputVault.economy_folder(rf), "solution", "stv.jld2"), MyModel)
```

The schema version is an integer that changes only when a change breaks readers of earlier files.
OutputVault reads only files of the current version; added entries do not change it.

### Rebuilding the model

A portable solution stores the model's *metadata*, the model's fields as plain data:
`model_metadata(mdl)` keeps reals, strings, symbols and numeric arrays and tuples with at most 1000
elements, recursively through structs and named tuples to depth 4, and drops everything else
(functions, interpolants, large arrays). Loading needs a way back to a model:

```julia
load(rf, :solution; solution_format = :portable, model = mdl)         # an instance: checked against the metadata
load(rf, :solution; solution_format = :portable, model = MyModel)     # a type: rebuilt from the metadata
```

The default rebuild is `MyModel(; metadata...)`. A model package whose models need more (derived
objects that were dropped, nested parameter structs) overloads [`model_metadata`](@ref) and
[`model_from_metadata`](@ref) for its type.

Passing an instance compares only this metadata: a change to the model's code that leaves its
parameters alone gives no warning. The record of the code is the git commit and diffs in the solution
folder ([Provenance](@ref)).

The solution id (`solution_id` in TFI), a hash of the grid and the values of the functions, is stored
and checked on load, and a mismatch warns that the file may be corrupted. It checks the numbers in the
file, not the model's equations.

## Tables

TFI's tables carry their own metadata (`tfi.kind`, `tfi.rowkey`, `tfi.endog`, `tfi.provenance`), and
OutputVault adds its storage kind (`outputvault.kind`); both are in the file's metadata, so TFI's
constructors restore the right type. TFI's tables restore as their own types only from table
formats that keep file-level metadata (Parquet does).

A `MomentArray` is written with the row names in the column named by its row key: `variable` for
moments, `equation` for error statistics, `parameter` for parameters. Moments by sample
(`describe(...).moments`) are one file per sample, in the order they were saved, which is recorded in
each file's metadata so that `load` returns them in order.

## Parameters and recursions

```julia
using TransitionFunctionIteration
save_result(rf, (; params = collect_parameters(obj)))
```

TFI's `collect_parameters` turns the model's scalar parameters (every real or Boolean field,
a Boolean as 0 or 1) into a one-column `MomentArray` with row key `parameter`, which is what the
`params` component holds and what a DuckDB query returns as `vault_params`. A model package can
define its own method to choose differently.

The `recursions` component holds interpolants over the solution's grid, one file each, for
quantities computed at the solution's policies after the solve. The file holds its own grid, so
it loads without the solution, and saving one never touches the `solution` folder.

## Comparing saved runs

```julia
using TransitionFunctionIteration
compare_economies(moments, (base = RunHandle("base"), alt = RunHandle("alt")))
```

compares moments (see TFI's guide on moments) across runs read with the active configuration. The
names of the NamedTuple are the names of the economies in the comparison, and the first is the base.
Only the components the moments need are loaded from each run: `stats` for simulation moments, `irf`
for impulse moments, `params` for parameter moments, and for a calculated moment those of its inputs,
however deeply nested. A run without a component that is needed is an error. So
`@CalculatedMoment cor_r(:C) * sd(:C) / sd(:r)` needs only `stats`, and a ratio of a `ParameterMoment`
to a `SimulationMoment` needs `params` as well:

```julia
using TransitionFunctionIteration
runs = (base = RunHandle("base"), alt = RunHandle("alt"))
save_result(runs.base, (; params = collect_parameters(obj_base)))    # saved with the model, see above
save_result(runs.alt,  (; params = collect_parameters(obj_alt)))

moments = (std_K = SimulationMoment(:K; stat = :std),
           beta  = ParameterMoment(:β),
           std_K_per_beta = CalculatedMoment(nt -> nt.std_K / nt.beta,
                                             (std_K = SimulationMoment(:K; stat = :std),
                                              beta = ParameterMoment(:β))))
compare_economies(moments, runs)
```

For many runs, or runs in a synced folder, `assemble_moments` selects the numbers the moments need
with DuckDB ([Querying with DuckDB](@ref)).
