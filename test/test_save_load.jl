# result type for save/load tests
struct _TestResult
    obj::Float64
    val::Int
    n::Int
    extra::String  # not in any component — should be ignored
end

@testset "save_load" begin
    git_dir = make_git_repo()

    mktempdir() do root
        cfg = make_cfg(root)
        rf  = RunHandle("usa"; branch="testbranch", experdef="base")
        res = _TestResult(3.14, 7, 42, "ignored")

        cd(git_dir) do
            @testset "save_result basics" begin
                epath = save_result(cfg, rf, res; skip=(), dirty_repo_check=:ignore)

                @test isdir(epath)
                @test epath == OutputVault.economy_folder(cfg, rf)
                @test isfile(joinpath(epath, "solution.jld2"))
                @test isfile(joinpath(epath, "stats.jld2"))
                # simulation is in skip_components default — verify it's absent
                @test !isfile(joinpath(epath, "simulation.jld2"))
            end

            @testset "default skip omits simulation" begin
                rf2  = RunHandle("eu"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf2, res; dirty_repo_check=:ignore)
                @test  isfile(joinpath(epath, "solution.jld2"))
                @test  isfile(joinpath(epath, "stats.jld2"))
                @test !isfile(joinpath(epath, "simulation.jld2"))
            end

            @testset "explicit skip" begin
                rf3   = RunHandle("skip_test"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf3, res; skip=(:stats,), dirty_repo_check=:ignore)
                @test  isfile(joinpath(epath, "solution.jld2"))
                @test !isfile(joinpath(epath, "stats.jld2"))
            end

            @testset "git metadata in solution only" begin
                epath  = OutputVault.economy_folder(cfg, rf)
                sol_d  = JLD2.load(joinpath(epath, "solution.jld2"))
                stats_d = JLD2.load(joinpath(epath, "stats.jld2"))

                @test haskey(sol_d, "git_commit_id")
                @test haskey(sol_d, "git_diffs")
                @test occursin(r"^[0-9a-f]{40}$", sol_d["git_commit_id"])
                @test !haskey(stats_d, "git_commit_id")
            end

            @testset "load round-trip" begin
                sol   = load(cfg, rf, :solution)
                @test sol isa NamedTuple
                @test keys(sol) == (:obj, :val)
                @test sol.obj ≈ res.obj
                @test sol.val == res.val

                stats = load(cfg, rf, :stats)
                @test keys(stats) == (:n,)
                @test stats.n == res.n
            end

            @testset "load missing file errors" begin
                rf_missing = RunHandle("ghost"; branch="testbranch", experdef="base")
                # economy folder must exist for economy_folder to not error
                mkpath(OutputVault.economy_folder(cfg, rf_missing; create=true))
                @test_throws ErrorException load(cfg, rf_missing, :solution)
            end

            @testset "global config wrappers" begin
                rf4 = RunHandle("wrap"; branch="testbranch", experdef="base")
                with_config(cfg) do
                    epath = save_result(rf4, res; skip=(), dirty_repo_check=:ignore)
                    @test isfile(joinpath(epath, "solution.jld2"))
                    sol = load(rf4, :solution)
                    @test sol.obj ≈ res.obj
                end
            end

            @testset "dirty_repo_check=:error throws" begin
                write(joinpath(git_dir, "dirty_save.txt"), "x")
                rf5 = RunHandle("dirty_err"; branch="testbranch", experdef="base")
                @test_throws ErrorException save_result(cfg, rf5, res; dirty_repo_check=:error)
                # no files should have been written
                @test !isdir(OutputVault.output_path(cfg, "testbranch") * "/res-base-dirty_err")
            end

            @testset "dirty_repo_check=:warn saves and warns" begin
                rf6   = RunHandle("dirty_warn"; branch="testbranch", experdef="base")
                epath = nothing
                @test_logs (:warn, r"not clean") match_mode=:any begin
                    epath = save_result(cfg, rf6, res; skip=(), dirty_repo_check=:warn)
                end
                @test isfile(joinpath(epath, "solution.jld2"))
                # clean up the untracked file for later tests
                rm(joinpath(git_dir, "dirty_save.txt"); force=true)
            end
        end
    end
end
