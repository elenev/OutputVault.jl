# A Research Run, Start to Finish

This page follows one model through everything OutputVault is for: solve and save, come back in a
fresh Julia session, warm-start a nearby calibration, add results computed later, and compare the
runs. The model is the neoclassical growth model of TransitionFunctionIteration's quick start.

The code runs in two Julia processes. Section 1 is one script. Sections 2 to 5 are a second script,
run in a new process, each section continuing where the previous one stopped. Both scripts are run
from the same folder, which holds `ngm.jl` (below) and is inside a git repository. The output under
each block is what the code printed when these docs were built.

## Before you start

!!! note "Load what you use"
    OutputVault's support for particular packages and file formats activates when those packages are
    loaded in the session:

    ```julia
    using OutputVault
    using TransitionFunctionIteration    # TFI's solutions, simulations, moments, IRFs
    using Parquet2                       # tables as Parquet files
    using DuckDB, Tables                 # assemble_moments and queries over saved runs
    ```

    If one is missing, the symptom is a method that does not exist or an error that names the package
    to load; see [Troubleshooting](@ref).

!!! warning "Two things that are easy to get wrong"
    **Saving a solution replaces the run.** A save that includes `obj` or `stv` (or both) produces a
    new run folder that holds only what that save contains. Once the new folder is in place, the old
    one is deleted with everything in it: simulation, statistics, IRFs, parameters, recursions, and an
    `obj` if you saved only `stv`. Re-running a solve to refresh the solution means saving the rest
    again. A property set to `nothing` counts as absent, so `(; obj = nothing, irf)` does not replace
    the run.

    **The git record always comes from the folder Julia runs in.** The commit and diffs saved with a
    solution are those of the git repository containing the current working directory, whatever the
    output root or the run's name. `RunHandle`'s `branch` defaults to that repository's branch;
    passing `branch = "..."` changes only the folder the run is saved in, not which repository is
    recorded. Run scripts from the model's repository.

## The model

Save this as `ngm.jl`. Both scripts include it, because a restored solution needs its model *type* in
the new process: the model's parameters are in the file, its code is not.

```julia
using TransitionFunctionIteration, StaticArrays
import TransitionFunctionIteration: Exogenv, calc_eqm, define_endog_grids, steadystate,
                                     compute_next_period_values, bounds, PositiveBounded

@kwdef struct NeoclassicalGrowthModel <: AbstractModel
    α::Float64 = 0.33   # capital share
    β::Float64 = 0.96   # discount factor
    δ::Float64 = 0.10   # depreciation
    γ::Float64 = 2.0    # CRRA risk aversion
    σ::Float64 = 0.02   # shock volatility
    ρ::Float64 = 0.9    # shock persistence
    N_A::Int   = 5      # exogenous grid points
end

Exogenv(mdl::NeoclassicalGrowthModel) =
    ExogenvAR1(ρ = mdl.ρ, σ = mdl.σ, n = mdl.N_A, transform = exp, jensen = true, shock_name = :A)

function steadystate(model::NeoclassicalGrowthModel, ::AnalyticalSteadyStateMode)
    (; α, β, δ) = model
    K = (α * β / (1 - β * (1 - δ)))^(1 / (1 - α))
    C = K^α - δ * K
    return SteadyState(; model, exog = (; A = 1.0), endog = (; K), values = (; C), guess = (; C)), true
end

define_endog_grids(model::NeoclassicalGrowthModel, stv::AbstractSteadyState) = (; K = range(0.8, 1.2, length = 20) * stv.endog.K)

bounds(::SteadyState{NeoclassicalGrowthModel}) = (C = PositiveBounded(),), (K = PositiveBounded(),)

function compute_next_period_values(next, mdl::NeoclassicalGrowthModel, ::EvaluationMode)
    (; A, K, C) = next
    (; α, β, δ, γ) = mdl
    Kpayoff = α * A * K^(α - 1) + (1 - δ)
    return NextPeriod(; expectations = (; Ek = β * C^(-γ) * Kpayoff), continuations = (; Kpayoff))
end

function calc_eqm(state, policy, mdl::NeoclassicalGrowthModel, np::NextPeriod, mode::EvaluationMode)
    (; A, K) = state;  (; C) = policy;  (; α, δ, γ) = mdl
    Y = A * K^α
    fx = SVector(1 - np.expectations.Ek / C^(-γ))
    mode isa SolveMode    && return fx
    mode isa IterateMode  && return (; fx, trans = (; K = (1 - δ) * K + Y - C), vals = (; C))
    return (; fx, trans = (; K = (1 - δ) * K + Y - C), simvars = (; Y, C))
end
```

## 1. Solve and save

The first script:

```@example lifecycle1
using OutputVault, Parquet2, TransitionFunctionIteration
include("ngm.jl")

root = abspath("../outputs")       # your output folder
set_config!(Config(
    output_root  = root,
    table_format = OutputVault.Formats.ParquetFormat(),
))

mdl = NeoclassicalGrowthModel()
obj, stv = main_setup(mdl)
main_execute!(obj; maxiter = 1000, logging = COMPLETE)
simseries, errs = simulate(obj, stv)
stats    = describe(simseries).moments
errstats = calc_error_stats(errs)

rf = RunHandle("base"; experdef = "demo")              # branch: the current git branch
save_result(rf, (; obj, stv, stats, errstats, simseries, errs, params = collect_parameters(obj)))
```

The run is `<root>/<branch>/res-demo-base/`, with a folder per component
([Runs and the Layout](@ref)). `save_result` returns that folder. If it could not put the new results
there, it warns and returns the folder that holds them instead ([Replacing a run](@ref)).

Name runs deliberately. The `experdef` groups economies that belong together (a calibration, a version
of the model) and must not contain `-`. The `economy` names the variant.

## 2. Reload in a fresh process

Start a new Julia session (a new day, or another machine with the output folder) and load the
*portable* copy of the solution. This starts the second script:

```@example lifecycle2
using OutputVault, Parquet2, TransitionFunctionIteration
include("ngm.jl")                                   # the model type must exist in this process

root = abspath("../outputs")       # your output folder
set_config!(Config(output_root  = root,
                   table_format = OutputVault.Formats.ParquetFormat()))
rf = RunHandle("base"; experdef = "demo")

(; obj, stv) = load(rf, :solution; solution_format = :portable, model = NeoclassicalGrowthModel)

# the restored solution reproduces the saved statistics
saved = load(rf, :stats).stats.uncond
simseries, errs = simulate(obj, stv)
@assert saved == describe(simseries).moments.uncond
```

`model = NeoclassicalGrowthModel` rebuilds the model from the parameters saved in the file
(`NeoclassicalGrowthModel(; parameters...)`). Pass an instance instead, `model = NeoclassicalGrowthModel()`,
to use it as it is. OutputVault then compares the parameters saved in the file with those of the
instance and warns *"The supplied model's metadata differ from the stored model's"*, listing the
fields that differ.

That check compares parameters only. It cannot see the model's code: if you changed an equation but
no parameter, loading gives no warning. What records the code is the solution folder's git commit and
diffs ([Provenance](@ref)). The strongest check is the one above: simulate the restored solution and
compare with the saved statistics. Do it once for every model type. A model whose fields are not all
numbers, strings or small arrays needs its own `model_metadata` and `model_from_metadata`
([TransitionFunctionIteration Objects](@ref)).

The native copy (`load(rf, :solution)`, without `solution_format`) loads faster, but it is the Julia
objects as they were saved and needs code compatible with the code that saved them. Use it only soon
after the solve.

## 3. Warm-start a nearby calibration

```@example lifecycle2
mdl2 = update_model(obj.model; ρ = 0.8)
obj2, stv2 = main_setup(mdl2, obj)                  # starts from the reloaded solution
main_execute!(obj2; maxiter = 1000, logging = COMPLETE)
simseries2, errs2 = simulate(obj2, stv2)

rf2 = RunHandle("lowrho"; experdef = "demo")
save_result(rf2, (; obj = obj2, stv = stv2, stats = describe(simseries2).moments,
                  simseries = simseries2, errs = errs2))
```

Each economy is its own run, so saving `lowrho` does not touch `base`. This run saves no parameters,
which comes up again in [A result that was never saved](@ref).

## 4. Add results computed later

```@example lifecycle2
save_result(rf,  (; irf = simulate_irf(obj, simseries)))
save_result(rf2, (; irf = simulate_irf(obj2, simseries2)))
```

A save without `obj` or `stv` adds to an existing run: `irf/` appears next to the other components,
and `solution/` is not touched. Recursions and other results computed after the solution are added the
same way. Such a save needs the run to exist already; for a run that was never saved it is an error.

## 5. Compare and query

Compare the runs through TFI's moments (see its guide on moments). First directly from the run folders:

```@example lifecycle2
using DuckDB, Tables
using TransitionFunctionIteration.Transformations: DiffPct, DiffLevel

moments = (std_K  = SimulationMoment(:K; stat = :std, compare_transformation = DiffPct()),
           mean_C = SimulationMoment(:C),
           irf_C  = ImpulseMoment(:C, :shock_5, 2; transformation = DiffLevel()))

runs = find_matching_results("$(rf.branch)/res-demo-*"; key = :economy)   # (base = RunHandle, lowrho = RunHandle)
compare_economies(moments, runs)
```

[`find_matching_results`](@ref) returns the runs whose folders match the pattern. The pattern names
this script's branch, so runs saved from other branches are not included. `key = :economy` names each
run by its economy alone. Without it, runs are named `<branch>__<experdef>__<economy>`, which never
clashes. A shorter name that two runs would share is an error, so `key = :economy` is safe to try. The
first run is the base of the comparison: here `base`, because the runs come in the order of their
folder names.

The same comparison through DuckDB, which reads only the files of the runs you name:

```@example lifecycle2
table = assemble_moments(root, moments; branch = rf.branch, experdef = "demo")
economies = split_by_economy(table; key = :economy, order = [:base, :lowrho])
compare_economies(moments, economies)
```

`table` is a plain long table, one row per number, that any language can read. The `branch` and
`experdef` arguments limit it to the runs of this tutorial. [`split_by_economy`](@ref) turns it into one
entry per run; `order` sets the order and so the base. [Querying with DuckDB](@ref) has the details and
the same queries from Python.

## A result that was never saved

The `lowrho` run saved no parameters. Asking for one is an error that names the entry, never a zero:

```@repl lifecycle2
getmoment(economies.lowrho, ParameterMoment(:β))
```

The same holds for a statistic, an IRF or a whole run that is missing: it shows up as absent.

## Troubleshooting

| What you see | Cause | Fix |
|:--|:--|:--|
| `No OutputVault config set. Call OutputVault.set_config!(cfg).` | no configuration in this process | `set_config!(Config(...))`, or pass the config as the first argument |
| `saving a ... needs a table format` | `Config` has no `table_format` | `Config(; table_format = OutputVault.Formats.ParquetFormat())` |
| `ParquetFormat needs its package: using Parquet2` | Parquet2 is not loaded | `using Parquet2` before saving or loading |
| `No reader for kind TransitionFunctionIteration.…; load the package that stores it` | the file was written by a package that is not loaded | `using TransitionFunctionIteration` (or the package named) |
| `... is a portable file without the model: load with model = ...` | a portable solution needs a model to rebuild | `load(...; solution_format = :portable, model = MyModel)` |
| `The supplied model's metadata differ from the stored model's` | the model you passed has different parameters from the saved one | check the fields the warning lists. The check does not see code changes; see [2. Reload in a fresh process](@ref) |
| `no method matching assemble_moments(...)` | DuckDB, Tables or TransitionFunctionIteration is not loaded | `using DuckDB, Tables, TransitionFunctionIteration` |
| `key = :economy gives the same name to different runs` | two runs with the same economy name, in different branches or experdefs | narrow `branch` and `experdef`, or use a longer `key` |
| `Economy folder ... does not exist` | adding results to a run that was never saved, or the wrong `branch` | save a solution first; check `RunHandle`'s branch, which defaults to the branch of the working directory |
| `experdef "..." contains '-'` | folder names `res-<experdef>-<economy>` are split at the first hyphen | no hyphens in `experdef` |
| `Repository is not clean. Saving git diffs to file.` | uncommitted changes in the working directory's repository | expected: the diffs are saved with the solution. `dirty_repo_check = :ignore` silences it |
