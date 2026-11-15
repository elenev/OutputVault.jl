# The run lifecycle of docs/src/guide/lifecycle.md across processes: save a solution, reload its
# portable copy in a fresh Julia process (which only has the model's code), simulate it, add a result
# computed there, and read everything back. Uses tfi_fixtures.jl (obj, stv, simseries from TFI's NGM).

@testset "Run lifecycle across processes" begin
    git_dir = make_git_repo()
    with_tempdir() do root
        cfg = Config(; output_root = root, table_format = PARQUET)
        rf = RunHandle("base"; branch = "main", experdef = "demo")
        saved_stats = describe(simseries).moments
        cd(git_dir) do
            save_result(cfg, rf, (; obj, stv, stats = saved_stats, params = collect_parameters(obj));
                        dirty_repo_check = :ignore)
        end
        folder = OutputVault.economy_folder(cfg, rf)
        solution_before = read(joinpath(folder, "solution", "obj.jld2"))

        # a fresh process: the model type from TFI's example, the portable load, a simulation that must
        # reproduce the saved moments, and an IRF saved afterwards
        example = read(joinpath(pkgdir(TransitionFunctionIteration), "examples", "ngm.jl"), String)
        model_code = first(split(example, "\nobj, stv = main_setup(ngm)"))
        script = """
            using OutputVault, Parquet2, TransitionFunctionIteration
            $model_code
            cfg = Config(output_root = $(repr(root)), table_format = OutputVault.Formats.ParquetFormat())
            rf = RunHandle("base"; branch = "main", experdef = "demo")
            (; obj, stv) = load(cfg, rf, :solution; solution_format = :portable, model = NeoclassicalGrowthModel)
            saved = load(cfg, rf, :stats).stats
            simseries, errs = simulate(obj, stv)
            same = describe(simseries).moments.uncond == saved.uncond
            irf = simulate_irf(obj, simseries; shocks = (up = 2, uncond = Int[]), T = 5, N = 20)
            save_result(cfg, rf, (; irf))
            println("LIFECYCLE same=", same, " restored=", obj.model == NeoclassicalGrowthModel())
            """
        out = read(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $script`, String)
        @test occursin("LIFECYCLE same=true restored=true", out)

        # back in this process: the late result is there and the solution folder was not touched
        @test sort(readdir(folder)) == ["irf", "params", "solution", "stats"]
        @test read(joinpath(folder, "solution", "obj.jld2")) == solution_before
        @test keys(load(cfg, rf, :irf).irf.means) == (:up, :uncond)
        @test load(cfg, rf, :stats).stats == saved_stats
        @test keys(find_matching_results(cfg, "main/res-demo-*")) == (:base,)
    end
end
