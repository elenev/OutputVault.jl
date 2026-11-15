# TFI fixtures: the neoclassical growth model from TFI's examples/ngm.jl (solved and simulated
# on include: ngm, obj, stv, simseries, errs, stats, errstats), and a variant with a forecasting
# function (Ffct), copied from TFI's test/test_forecasts.jl.
using TransitionFunctionIteration, StaticArrays
include(joinpath(pkgdir(TransitionFunctionIteration), "examples", "ngm.jl"))

import TransitionFunctionIteration: Exogenv, calc_eqm, define_endog_grids, steadystate,
    compute_next_period_values, vals_from_policy, bounds, forecasts_from_policy

struct ForecastNGM <: AbstractModel
    base::NeoclassicalGrowthModel
end

forecasts_from_policy(state, policy, ::ForecastNGM) = (Cnow = policy.C,)
vals_from_policy(_, policy, ::ForecastNGM) = (C = policy.C,)
Exogenv(m::ForecastNGM) = Exogenv(m.base)
define_endog_grids(m::ForecastNGM, stv::AbstractSteadyState) = define_endog_grids(m.base, stv)
function steadystate(m::ForecastNGM, mode::AnalyticalSteadyStateMode)
    s, ok = steadystate(m.base, mode)
    SteadyState(; model = m, exog = s.exog, endog = s.endog, values = s.values, guess = s.guess), ok
end
bounds(::SteadyState{ForecastNGM}) = ((C = TransitionFunctionIteration.PositiveBounded(),),
                                      (K = TransitionFunctionIteration.PositiveBounded(),))

function compute_next_period_values(next, m::ForecastNGM, ::EvaluationMode)
    (; A, K, C, Cnow) = next
    (; α, β, δ, γ) = m.base
    Kpayoff = A * TransitionFunctionIteration.cobb_douglas_prime(K, 1.0, α, 1) + 1 - δ
    return NextPeriod(; expectations = (; euler_kernel = β * (C / Cnow)^(-γ) * Kpayoff,),
                        continuations = (; Kpayoff, Cnow))
end

function calc_eqm(state, policy, m::ForecastNGM, np::NextPeriod, mode::EvaluationMode = SolveMode())
    (; A, K) = state
    (; C) = policy
    (; α, δ) = m.base
    Y = A * TransitionFunctionIteration.cobb_douglas(K, 1.0, α)
    Cnow = np.continuations.Cnow[1]          # the same in every next-period state
    fx = SVector(1 - np.expectations.euler_kernel * (Cnow / C)^(-m.base.γ),)
    mode isa SolveMode && return fx
    trans = (K = (1 - δ) * K + Y - C,)
    mode isa IterateMode && return (; fx, trans, vals = (; C))
    return (; fx, trans, simvars = (; Y, C))
end
