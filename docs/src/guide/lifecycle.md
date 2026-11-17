# A Research Run, Start to Finish

This page follows one model through everything OutputVault is for: solve and save, come back in a
fresh Julia session, warm-start a nearby calibration, add a result computed later, and compare the
runs. The model is the neoclassical growth model of TransitionFunctionIteration's quick start, so every
step can be run as it is. Each block is one script, run in the process the text says.

## Before you start

!!! note "Load what you use"
    OutputVault's core knows nothing about particular model packages or file formats. Each is a package
    extension, which activates when its packages are loaded in the session:

    ```julia
    using OutputVault
    using TransitionFunctionIteration, StaticArrays, StructArrays   # TFI's solutions, simulations, moments, IRFs
    using Parquet2                                                  # Parquet tables
    using DuckDB, Tables                                            # assemble_moments, if you use it
    ```

    (StaticArrays and StructArrays are already loaded by TFI. If an extension is missing, the symptom is a
    method that does not exist or a message that names the package; see [Troubleshooting](@ref).)

!!! warning "Two things that are easy to get wrong"
    **Saving a solution replaces the run's folder.** A save that includes `obj` or `stv` first deletes
    everything saved for that run: its simulation, statistics, IRFs, parameters and recursions are gone until
    you save them again. Re-running a solve to refresh the solution means re-saving the rest.

    **The branch and the git record come from the working directory.** `RunHandle`'s default branch and the
    commit and diffs in `solution/` are those of the git repository in the directory the process runs in, not
    of the output root or the model. Start Julia from the model's repository, or pass `branch = ...` to
    `RunHandle` explicitly; a reusable script should do both, and set its own `Config`.

## The model

Saved as `ngm.jl` and included by every script below, because a restored solution needs its model *type*
in the new process (the model's parameters are in the file, its code is not):

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

```julia
using OutputVault, Parquet2, TransitionFunctionIteration
include("ngm.jl")

root = "/path/to/outputs"
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
([Runs and the Layout](@ref)). Name runs deliberately: the `experdef` groups economies that belong together
(a calibration, a version of the model) and must not contain `-`; the `economy` names the variant.

## 2. Reload in a fresh process

Start a new Julia session (a new day, another machine with the output folder) and load the *portable* copy:

```julia
using OutputVault, Parquet2, TransitionFunctionIteration
include("ngm.jl")                                   # the model type must exist in this process

set_config!(Config(output_root = "/path/to/outputs",
                   table_format = OutputVault.Formats.ParquetFormat()))
rf = RunHandle("base"; experdef = "demo")

(; obj, stv) = load(rf, :solution; solution_format = :portable, model = NeoclassicalGrowthModel)

# the restored solution is the solution that was saved
saved = load(rf, :stats).stats.uncond
simseries, errs = simulate(obj, stv)
@assert saved == describe(simseries).moments.uncond
```

`model = NeoclassicalGrowthModel` rebuilds the model from the parameters in the file
(`NeoclassicalGrowthModel(; metadata...)`); pass an instance instead to have it compared with the stored one.
Treat the warning *"The supplied model's metadata differ from the stored model's"* as a question about
reproducibility: the code or parameters are not those that produced the file. A model with derived or non-plain
fields overloads `model_metadata` and `model_from_metadata` ([TransitionFunctionIteration Objects](@ref)). Do
this check once for every model type: a fresh process, a portable load, and a simulation that matches.

The native copy (`load(rf, :solution)`) is faster but needs code compatible with the code that saved it, so
use it only soon after the solve.

## 3. Warm-start a nearby calibration

```julia
mdl2 = update_model(obj.model; ρ = 0.8)
obj2, stv2 = main_setup(mdl2, obj)                  # starts from the reloaded solution
main_execute!(obj2; maxiter = 1000, logging = COMPLETE)
simseries2, errs2 = simulate(obj2, stv2)

rf2 = RunHandle("lowrho"; experdef = "demo")
save_result(rf2, (; obj = obj2, stv = stv2, stats = describe(simseries2).moments,
                  simseries = simseries2, errs = errs2))
```

Each economy is its own run, so the second save does not touch the first.

## 4. Add a result computed later

```julia
irf = simulate_irf(obj, simseries)
save_result(rf, (; irf))
```

A save without `obj` or `stv` adds to the run: `irf/` appears next to the other components, and
`solution/` is not touched. The same is how recursions and other derived results are saved when they are
computed after the solution.

## 5. Compare and query

With the runs saved, compare them through TFI's moments (see its guide on moments):

```julia
using DuckDB, Tables, TransitionFunctionIteration
using TransitionFunctionIteration.Transformations: DiffPct, DiffLevel

moments = (std_K  = SimulationMoment(:K; stat = :std, compare_transformation = DiffPct()),
           mean_C = SimulationMoment(:C),
           irf_C  = ImpulseMoment(:C, :shock_5, 2; transformation = DiffLevel()))

runs = find_matching_results("*/res-demo-*")               # (base = RunHandle, lowrho = RunHandle)
compare_economies((; std_K = moments.std_K, mean_C = moments.mean_C), runs)   # each run's stats

table = assemble_moments(root, moments; experdef = "demo")  # one DuckDB query per kind of moment
compare_economies(moments, split_by_economy(table))
```

`assemble_moments` reads only the statistics the moments name, and only from runs that have them. The
`lowrho` run has no IRF, so it has no `impulse` rows in `table`, and the table has `simulation` rows for
both. Asking for the impulse moment in `lowrho` is a `KeyError` that names the missing entry, which is how
a result that was never computed shows up: as absent, never as zero. The same data are available to any
language with DuckDB ([Querying with DuckDB](@ref)).

## Troubleshooting

| What you see | Cause | Fix |
|:--|:--|:--|
| `No OutputVault config set. Call OutputVault.set_config!(cfg).` | no configuration in this process | `set_config!(Config(...))`, or pass the config as the first argument |
| `saving a ... needs a table format` | `Config` has no `table_format` | `Config(; table_format = OutputVault.Formats.ParquetFormat())` |
| `ParquetFormat needs its package: using Parquet2` | the Parquet extension is not loaded | `using Parquet2` before using the format |
| `No reader for kind TransitionFunctionIteration.…; load the package that stores it` | the file was written by a producer that is not loaded | `using TransitionFunctionIteration` (and the package of any other kind named) |
| `... is a portable file without the model: load with model = ...` | a portable solution needs a model to rebuild | `load(...; solution_format = :portable, model = MyModel)` |
| `The supplied model's metadata differ from the stored model's` | the model's parameters or code are not those that saved the file | find out what differs (the warning lists keys) before trusting the result |
| `no method matching assemble_moments(...)` | the DuckDB extension is not loaded | `using DuckDB, Tables, TransitionFunctionIteration` |
| `Economy folder ... does not exist` | a run that was never saved, or the wrong `branch` | check `RunHandle`'s branch: it defaults to the current git branch of the working directory |
| `experdef "..." contains '-'` | the folder `res-<experdef>-<economy>` splits at the first hyphen | no hyphens in `experdef` |
| `Repository is not clean. Saving git diffs to file.` | uncommitted changes in the working directory's repository | expected; the diffs are saved next to the solution. `dirty_repo_check = :ignore` silences it |
