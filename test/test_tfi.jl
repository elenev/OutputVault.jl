# OutputVault with TransitionFunctionIteration: solution and steady-state files, tables through a
# TableFormat (parquet), save_result/load round trips, and allocations when restoring from
# parquet. Uses tfi_fixtures.jl.
using Parquet2, Tables, DataAPI, Statistics, StaticArrays
const PARQUET = TableFormat(ext = "parquet", read = Parquet2.Dataset,
                            write = (path, table, meta) -> Parquet2.writefile(path, table; metadata = meta))

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

    o1 = load_solution(path)                                  # exact model
    @test same_solution(o1, obj) && o1.model == ngm
    @test solution_id(o1) == solution_id(obj)                    # the id survives the file
    o2 = @test_logs load_solution(path, ngm)                  # supplied model, matching metadata
    @test same_solution(o2, obj)
    @test_logs (:warn, r"metadata differ") match_mode = :any load_solution(path, NeoclassicalGrowthModel(β = 0.95))
    o3 = load_solution(path, NeoclassicalGrowthModel)         # model_from_metadata
    @test same_solution(o3, obj) && o3.model == ngm

    # the restored solution evaluates and simulates like the original
    pt = (exst = 2, K = 3.0)
    @test o1.Pfct(pt) == obj.Pfct(pt)
    @test simulate(o1, stv; sz = 100 => 2)[1].data == simulate(obj, stv; sz = 100 => 2)[1].data

    # forecasting functions and a one-state exogenous environment
    fm = ForecastNGM(NeoclassicalGrowthModel(N_A = 1))
    objf, _ = main_setup(fm)
    main_execute!(objf; maxiter = 300, tol = -7, logging = COMPLETE)
    pathf = save_solution(joinpath(mktempdir(), "solf.jld2"), objf)
    of = load_solution(pathf)
    @test same_solution(of, objf) && varnames(of.Ffct) == (:Cnow,)
    @test solution_id(of) == solution_id(objf) != solution_id(obj)
    @test same_solution(load_solution(pathf, fm), objf)

    # stored layout: plain arrays over the grid axes, Tfct with a next-state axis
    jldopen(path, "r") do io
        @test io["outputvault/kind"] == "TransitionFunctionIteration.ModelSolution"
        @test io["meta/schema_version"] == 1
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
    @test load_steadystate(path) == stv                       # model from the solution next to it
    @test load_steadystate(path, ngm) == stv
    @test load_steadystate(path, NeoclassicalGrowthModel) == stv
    jldopen(path, "r") do io
        @test io["outputvault/kind"] == "TransitionFunctionIteration.SteadyState"
        @test !haskey(io, "exact")                                    # no copy of the model
    end
    # alone in a folder, the model must be supplied
    alone = save_steadystate(joinpath(mktempdir(), "stv.jld2"), stv)
    @test_throws ArgumentError load_steadystate(alone)
end

@testset "TFI: save_result and load" begin
    git_dir = make_git_repo()
    irf = simulate_irf(obj, simseries; shocks = (pos = 2,), path_vars = (:K,), T = 5, N = 20)
    result = (; obj, stv, stats, errstats, simseries, errs, irf)
    comps = (solution = (:obj, :stv), stats = (:stats, :errstats), simulation = (:simseries, :errs), irf = (:irf,))

    mktempdir() do root
        cfg = Config(; output_root = root, components = comps, table_format = PARQUET)
        rf = RunHandle("ngm"; branch = "testbranch", experdef = "base")
        cd(git_dir) do
            epath = save_result(cfg, rf, result; skip = (), dirty_repo_check = :ignore)
            for f in ("solution/obj.jld2", "solution/stv.jld2", "solution/git_commit.txt",
                      "stats/stats.parquet", "stats/errstats.parquet",
                      "simulation/simseries.parquet", "simulation/errs.parquet",
                      "irf/irf.parquet", "irf/irf_paths.parquet")
                @test isfile(joinpath(epath, f))
            end
            # OutputVault records the storage kind next to TFI's own table metadata
            ds = Parquet2.Dataset(joinpath(epath, "simulation", "simseries.parquet"))
            @test DataAPI.metadata(ds, "outputvault.kind") == "TransitionFunctionIteration.SimulationPanel"
            @test DataAPI.metadata(ds, "tfi.kind") == "SimulationPanel"
            commit = strip(read(joinpath(epath, "solution", "git_commit.txt"), String))
            @test jldopen(io -> io["meta/provenance/git_commit_id"], joinpath(epath, "solution", "obj.jld2")) == commit

            # every object comes back as its own type
            sol = load(cfg, rf, :solution)
            @test same_solution(sol.obj, obj) && sol.obj.model == ngm
            @test sol.stv == stv
            st = load(cfg, rf, :stats)
            @test st.stats == stats && st.errstats == errstats
            sim = load(cfg, rf, :simulation)
            @test sim.simseries.data == simseries.data && sim.simseries.provenance == simseries.provenance
            @test endog_states(sim.simseries) == endog_states(simseries)
            @test sim.errs.data == errs.data && sim.errs.provenance == errs.provenance
            r = load(cfg, rf, :irf).irf
            @test r.means == irf.means && r.stdevs == irf.stdevs && r.paths.pos == irf.paths.pos
            @test r.provenance == irf.provenance
        end

        # tables need a table format
        cfg0 = Config(; output_root = root, components = (stats = (:stats,),))
        cd(git_dir) do
            @test_throws ArgumentError save_result(cfg0, RunHandle("nofmt"; branch = "testbranch"), (; stats);
                                                   dirty_repo_check = :ignore)
        end
    end
end

# allocations of f(args...) after a warm-up call
allocs_after_warmup(f, args...) = (f(args...); @allocated f(args...))
const ALLOC_ROWS = ntuple(i -> Symbol("r$i"), 12)
const ALLOC_COLS = ntuple(j -> Symbol("c$j"), 6)
restore_static(table) = MomentArray{ALLOC_ROWS, ALLOC_COLS, Float64, SMatrix{12, 6, Float64}}(table)
restore_dense(table) = MomentArray{ALLOC_ROWS, ALLOC_COLS, Float64}(table)

@testset "TFI: restoring a MomentArray from parquet allocates little beyond Parquet2's reads" begin
    R, C = length(ALLOC_ROWS), length(ALLOC_COLS)
    ma = MomentArray(reshape(collect(1.0:R*C), R, C), ALLOC_ROWS, ALLOC_COLS)
    path = joinpath(mktempdir(), "ma.parquet")
    PARQUET.write(path, ma, Dict{String,String}())
    ds = PARQUET.read(path)
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
