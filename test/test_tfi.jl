# OutputVault with TransitionFunctionIteration: solution and steady-state files, tables through
# OutputVault.Formats.ParquetFormat, save_result/load round trips, and allocations when restoring
# from parquet. Uses tfi_fixtures.jl.
using Parquet2, Tables, DataAPI, Statistics, StaticArrays
const PARQUET = OutputVault.Formats.ParquetFormat()

struct MetaTestModel <: AbstractModel
    a::Float64
    f::Function
    big::Vector{Float64}
    small::Vector{Float64}
    nt::NamedTuple
end

same_solution(a, b) = a.Pfct == b.Pfct && a.Vfct == b.Vfct && a.Tfct == b.Tfct &&
    a.ssg == b.ssg && isapprox(a.exogenv, b.exogenv) &&
    a.Pfct_bounds == b.Pfct_bounds && a.Tfct_bounds == b.Tfct_bounds &&
    (isnothing(a.Ffct) ? isnothing(b.Ffct) : a.Ffct == b.Ffct)

@testset "TFI: model_metadata" begin
    @test model_metadata(ngm) == (α = ngm.α, β = ngm.β, δ = ngm.δ, γ = ngm.γ, σ = ngm.σ, ρ = ngm.ρ, N_A = ngm.N_A)
    @test model_from_metadata(NeoclassicalGrowthModel, model_metadata(ngm)) == ngm
    fm = ForecastNGM(NeoclassicalGrowthModel())
    @test model_metadata(fm) == (base = model_metadata(fm.base),)
    # derived objects are left out
    m = MetaTestModel(1.0, sin, zeros(10_000), [1.0, 2.0], (x = :s, g = cos))
    @test model_metadata(m) == (a = 1.0, small = [1.0, 2.0], nt = (x = :s,))
end

@testset "TFI: solution files" begin
    path = joinpath(mktempdir(), "sol.jld2")
    @test save_solution(path, obj; provenance = Dict("git_commit_id" => "abc123")) == path

    o1 = load_solution(path, NeoclassicalGrowthModel)         # model_from_metadata
    @test same_solution(o1, obj) && o1.model == ngm
    @test solution_id(o1) == solution_id(obj)                    # the id survives the file
    o2 = @test_logs load_solution(path, ngm)                  # supplied model, matching metadata
    @test same_solution(o2, obj)
    @test_logs (:warn, r"metadata differ") match_mode = :any load_solution(path, NeoclassicalGrowthModel(β = 0.95))

    # the restored solution evaluates and simulates like the original
    pt = (exst = 2, K = 3.0)
    @test o1.Pfct(pt) == obj.Pfct(pt)
    @test simulate(o1, stv; sz = 100 => 2)[1].data == simulate(obj, stv; sz = 100 => 2)[1].data

    # forecasting functions and a one-state exogenous environment
    fm = ForecastNGM(NeoclassicalGrowthModel(N_A = 1))
    objf, _ = main_setup(fm)
    main_execute!(objf; maxiter = 300, tol = -7, logging = COMPLETE)
    pathf = save_solution(joinpath(mktempdir(), "solf.jld2"), objf)
    of = load_solution(pathf, fm)
    @test same_solution(of, objf) && varnames(of.Ffct) == (:Cnow,)
    @test solution_id(of) == solution_id(objf) != solution_id(obj)

    # stored layout: plain arrays over the grid axes, Tfct with a next-state axis
    jldopen(path, "r") do io
        @test io["outputvault/kind"] == "TransitionFunctionIteration.ModelSolution"
        @test io["meta/schema_version"] == 2
        @test !haskey(io, "exact")                                    # plain data only
        @test io["Pfct/__bounds/__names"] == ["C"] && io["Pfct/__bounds/C"] == [0.0, Inf]
        @test io["grid/__axes"] == ["exst", "K"]
        @test size(io["Pfct/C"]) == (ngm.N_A, 20)
        @test size(io["Tfct/K"]) == (ngm.N_A, 20, ngm.N_A)
        @test io["meta/model/β"] == ngm.β
        @test io["meta/solution_id"] == solution_id(obj)
        @test io["meta/provenance/git_commit_id"] == "abc123"
    end
end

@testset "TFI: steady-state files" begin
    dir = mktempdir()
    save_solution(joinpath(dir, "obj.jld2"), obj)
    path = save_steadystate(joinpath(dir, "stv.jld2"), stv)
    @test load_steadystate(path, ngm) == stv
    @test load_steadystate(path, NeoclassicalGrowthModel) == stv
    jldopen(path, "r") do io
        @test io["outputvault/kind"] == "TransitionFunctionIteration.SteadyState"
        @test !haskey(io, "exact")                                    # no copy of the model
    end
end

@testset "TFI: bounds as intervals" begin
    ext = Base.get_extension(OutputVault, :OutputVaultTFIExt)
    for b in (TransitionFunctionIteration.Unbounded(), TransitionFunctionIteration.LowerBounded(-1.0),
              TransitionFunctionIteration.UpperBounded(2.0), TransitionFunctionIteration.IntervalBounded(0.0, 3.0))
        @test ext.interval_bound(ext.bound_interval(b)) == b
    end
end

@testset "TFI: save_result and load" begin
    git_dir = make_git_repo()
    irf = simulate_irf(obj, simseries; shocks = (pos = 2,), path_vars = (:K,), T = 5, N = 20)
    result = (; obj, stv, stats, errstats, simseries, errs, irf, params = collect_parameters(obj))

    with_tempdir() do root
        cfg = Config(; output_root = root, table_format = PARQUET)
        rf = RunHandle("ngm"; branch = "testbranch", experdef = "base")
        cd(git_dir) do
            epath = save_result(cfg, rf, result; dirty_repo_check = :ignore)
            for f in ("solution/res.jld2", "solution/obj.jld2", "solution/stv.jld2", "solution/git_commit.txt",
                      "stats/stats.parquet", "errstats/errstats.parquet",
                      "simulation/simseries.parquet", "simulation/errs.parquet",
                      "irf/irf.parquet", "irf/irf_paths.parquet", "params/params.parquet")
                @test isfile(joinpath(epath, f))
            end
            # OutputVault records the storage kind next to TFI's own table metadata
            ds = Parquet2.Dataset(joinpath(epath, "simulation", "simseries.parquet"))
            @test DataAPI.metadata(ds, "outputvault.kind") == "TransitionFunctionIteration.SimulationPanel"
            @test DataAPI.metadata(ds, "tfi.kind") == "SimulationPanel"
            commit = strip(read(joinpath(epath, "solution", "git_commit.txt"), String))
            @test jldopen(io -> io["meta/provenance/git_commit_id"], joinpath(epath, "solution", "obj.jld2")) == commit

            # every object comes back as its own type, from either copy of the solution
            sol = load(cfg, rf, :solution)
            @test same_solution(sol.obj, obj) && sol.obj.model == ngm && solution_id(sol.obj) == solution_id(obj)
            @test sol.stv == stv
            for model in (NeoclassicalGrowthModel, ngm)
                solp = load(cfg, rf, :solution; solution_format = :portable, model)
                @test same_solution(solp.obj, obj) && solp.obj.model == ngm && solp.stv == stv
            end
            @test_throws ArgumentError load(cfg, rf, :solution; solution_format = :portable)
            @test load(cfg, rf, :stats).stats == stats
            @test load(cfg, rf, :errstats).errstats == errstats
            # moments are written with their row names in a column `variable`, and read back from it
            st_ds = Parquet2.Dataset(joinpath(epath, "stats", "stats.parquet"))
            @test first(Tables.columnnames(st_ds)) == row_key(stats) && DataAPI.metadata(st_ds, "tfi.rowkey") == string(row_key(stats))
            @test first(Tables.columnnames(Parquet2.Dataset(joinpath(epath, "errstats", "errstats.parquet")))) == :equation
            @test first(Tables.columnnames(Parquet2.Dataset(joinpath(epath, "params", "params.parquet")))) == :parameter
            # the default params: every scalar real field of the model, one column `value`
            pars = load(cfg, rf, :params).params
            expected = [f for f in fieldnames(typeof(ngm)) if getfield(ngm, f) isa Real]
            @test pars == collect_parameters(obj) == collect_parameters(ngm)
            @test collect(row_names(pars)) == expected && col_names(pars) == (:value,)
            @test vec(pars.data) == Float64[getfield(ngm, f) for f in expected]
            sim = load(cfg, rf, :simulation)
            @test sim.simseries.data == simseries.data && sim.simseries.provenance == simseries.provenance
            @test endog_states(sim.simseries) == endog_states(simseries)
            @test sim.errs.data == errs.data && sim.errs.provenance == errs.provenance
            r = load(cfg, rf, :irf).irf
            @test r.means == irf.means && r.stdevs == irf.stdevs && r.paths.pos == irf.paths.pos
            @test r.provenance == irf.provenance

            # recursions: interpolants saved into their own component, one file each, later than the
            # solution and without touching it (here the solution's own Vfct stands in for a recursion)
            res_before = read(joinpath(epath, "solution", "res.jld2"))
            obj_before = read(joinpath(epath, "solution", "obj.jld2"))
            save_result(cfg, rf, (; claims = obj.Vfct); dirty_repo_check = :ignore)
            @test isfile(joinpath(epath, "recursions", "claims.jld2")) && !isfile(joinpath(epath, "recursions", "welfare.jld2"))
            @test read(joinpath(epath, "solution", "res.jld2")) == res_before && read(joinpath(epath, "solution", "obj.jld2")) == obj_before
            rec = load(cfg, rf, :recursions)
            @test keys(rec) == (:claims,) && varnames(rec.claims) == varnames(obj.Vfct)
            pts = collect(points(obj.ssg))
            @test rec.claims(pts) == obj.Vfct(pts)
            @test dims(rec.claims.ssg) == dims(obj.ssg)
            save_result(cfg, rf, (; welfare = obj.Vfct); dirty_repo_check = :ignore)   # a second one adds to the first
            @test keys(load(cfg, rf, :recursions)) == (:claims, :welfare)

            # moments by sample, as describe returns them: one table per sample, restored in order
            # (a_all sorts before uncond in the folder, but comes second)
            samples = describe(simseries; filters = (a_all = Returns(true),)).moments
            @test keys(samples) == (:uncond, :a_all)
            rf_s = RunHandle("ngm_samples"; branch = "testbranch", experdef = "base")
            epath_s = save_result(cfg, rf_s, (; obj, stats = samples); dirty_repo_check = :ignore)
            @test sort(readdir(joinpath(epath_s, "stats"))) == ["a_all.parquet", "uncond.parquet"]
            ds = Parquet2.Dataset(joinpath(epath_s, "stats", "a_all.parquet"))
            @test DataAPI.metadata(ds, "outputvault.part_of") == "stats" && DataAPI.metadata(ds, "outputvault.part_index") == "2"
            restored = load(cfg, rf_s, :stats).stats
            @test keys(restored) == keys(samples) && restored == samples

            # compare_economies over saved runs reads each run's stats component
            moms = (mean_K = SimulationMoment(:K),)
            @test with_config(() -> compare_economies(moms, (a = rf_s, b = rf_s)), cfg) ==
                  compare_economies(moms, (a = samples, b = samples))

            # a run with a solution and parameters but no stats serves parameter moments (and calculations on them)
            rf_p = RunHandle("ngm_params"; branch = "testbranch", experdef = "base")
            save_result(cfg, rf_p, (; obj, params = collect_parameters(obj)); dirty_repo_check = :ignore)
            pname = first(row_names(collect_parameters(obj)))
            pmoms = (p = ParameterMoment(pname),
                     twice = CalculatedMoment(nt -> 2 * nt.p, (p = ParameterMoment(pname),)))
            from_runs = with_config(() -> compare_economies(pmoms, (a = rf_p, b = rf_p)), cfg)
            @test from_runs == compare_economies(pmoms, (a = EconomyResult(; params = collect_parameters(obj)),
                                                         b = EconomyResult(; params = collect_parameters(obj))))
            # a simulation moment still needs stats, which this run lacks
            @test_throws Exception with_config(() -> compare_economies((; m = SimulationMoment(:K)), (a = rf_p,)), cfg)
        end

        # tables need a table format
        cfg0 = Config(; output_root = root)
        cd(git_dir) do
            @test_throws ArgumentError save_result(cfg0, RunHandle("nofmt"; branch = "testbranch"), (; obj, stats);
                                                   dirty_repo_check = :ignore)
        end
    end
end

# allocations of f(args...) after a warm-up call
allocs_after_warmup(f, args...) = (f(args...); @allocated f(args...))
const ALLOC_ROWS = ntuple(i -> Symbol("r$i"), 12)
const ALLOC_COLS = ntuple(j -> Symbol("c$j"), 6)
restore_static(table) = MomentArray{ALLOC_ROWS, ALLOC_COLS, Float64, SMatrix{12, 6, Float64}, :__row}(table)
restore_dense(table) = MomentArray{ALLOC_ROWS, ALLOC_COLS, Float64, Matrix{Float64}, :__row}(table)

@testset "TFI: restoring a MomentArray from parquet allocates little beyond Parquet2's reads" begin
    R, C = length(ALLOC_ROWS), length(ALLOC_COLS)
    ma = MomentArray(reshape(collect(1.0:R*C), R, C), ALLOC_ROWS, ALLOC_COLS)
    path = joinpath(mktempdir(), "ma.parquet")
    OutputVault.write_table_file(PARQUET, path, ma, Dict{String,String}())
    ds = OutputVault.read_table_file(PARQUET, path)
    @test restore_static(ds) == ma && restore_dense(ds) == ma
    # baseline: Parquet2's part of the work (metadata entries, the column table and its names,
    # each column, the row names as Strings). The restore adds less than one matrix (static) or
    # two (dense).
    function parquet_reads(ds)
        meta = (DataAPI.metadata(ds, "tfi.kind", ""), DataAPI.metadata(ds, "tfi.rowkey", ""))
        tbl = Tables.columns(ds)
        rownames = Tables.getcolumn(tbl, :__row)
        (meta, Tables.columnnames(tbl), ntuple(i -> Symbol(rownames[i]), 12), map(c -> Tables.getcolumn(tbl, c), ALLOC_COLS))
    end
    matrix_bytes = sizeof(Float64) * R * C
    baseline = allocs_after_warmup(parquet_reads, ds)
    @test allocs_after_warmup(restore_static, ds) - baseline < matrix_bytes
    @test allocs_after_warmup(restore_dense, ds) - baseline < 2 * matrix_bytes
end

struct ParametersModel <: AbstractModel
    a::Float64
    n::Int
    flag::Bool
    label::String
    grid::Vector{Float64}
end

@testset "TFI: default parameters are the scalar real and Boolean fields" begin
    p = collect_parameters(ParametersModel(0.5, 3, true, "x", [1.0, 2.0]))
    @test row_names(p) == (:a, :n, :flag) && col_names(p) == (:value,)
    @test vec(p.data) == [0.5, 3.0, 1.0]
end


@testset "TFI: Interpolant files record provenance" begin
    with_tempdir() do dir
        cfg = make_cfg(dir)
        OutputVault.write_object(cfg, dir, "fct", obj.Vfct; provenance = Dict("git_commit_id" => "abc123", "branch" => "main"))
        path = joinpath(dir, "fct.jld2")
        @test isfile(path)
        jldopen(path, "r") do io
            @test io["meta/provenance/git_commit_id"] == "abc123"
            @test io["meta/provenance/branch"] == "main"
        end
        @test OutputVault.read_object(cfg, dir, "fct") == obj.Vfct
    end
end
