# result type for save/load tests
struct _TestResult
    obj::Float64
    val::Int
    n::Int
    extra::String  # not in any component — should be ignored
end

# a producer's type: stored under its own kind with jld2_record, restored by read_kind
struct _Kinded
    x::Int
end
OutputVault.storage_kind(::_Kinded) = "OutputVaultTests.Kinded"
OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, k::_Kinded;
                         provenance = Dict{String,String}()) =
    OutputVault.jld2_record(io -> (io["x"] = k.x), joinpath(dir, name * ".jld2"), k)
OutputVault.read_kind(::Val{Symbol("OutputVaultTests.Kinded")}, path) = _Kinded(JLD2.load(path, "x"))

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
                # one folder per component, one file per property
                @test isfile(joinpath(epath, "solution", "obj.jld2"))
                @test isfile(joinpath(epath, "solution", "val.jld2"))
                @test isfile(joinpath(epath, "stats", "n.jld2"))
                # simulation is in skip_components default — verify it's absent
                @test !isdir(joinpath(epath, "simulation"))
            end

            @testset "default skip omits simulation" begin
                rf2  = RunHandle("eu"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf2, res; dirty_repo_check=:ignore)
                @test  isdir(joinpath(epath, "solution"))
                @test  isdir(joinpath(epath, "stats"))
                @test !isdir(joinpath(epath, "simulation"))
            end

            @testset "explicit skip" begin
                rf3   = RunHandle("skip_test"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf3, res; skip=(:stats,), dirty_repo_check=:ignore)
                @test  isdir(joinpath(epath, "solution"))
                @test !isdir(joinpath(epath, "stats"))
            end

            @testset "git commit in solution folder only" begin
                epath = OutputVault.economy_folder(cfg, rf)
                commit = strip(read(joinpath(epath, "solution", "git_commit.txt"), String))
                @test occursin(r"^[0-9a-f]{40}$", commit)
                @test !isfile(joinpath(epath, "solution", "git_unstaged.diff"))   # clean repo: no diffs
                @test !isfile(joinpath(epath, "stats", "git_commit.txt"))
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
                    @test isfile(joinpath(epath, "solution", "obj.jld2"))
                    sol = load(rf4, :solution)
                    @test sol.obj ≈ res.obj
                end
            end

            @testset "producer interface: storage kinds" begin
                rf_k  = RunHandle("kinded"; branch="testbranch", experdef="base")
                cfg_k = Config(; output_root=root, components=(solution=(:obj,),))
                epath = save_result(cfg_k, rf_k, (; obj=_Kinded(5)); dirty_repo_check=:ignore)
                path  = joinpath(epath, "solution", "obj.jld2")
                @test OutputVault.recorded_kind(path) == "OutputVaultTests.Kinded"
                @test load(cfg_k, rf_k, :solution).obj == _Kinded(5)
                # objects without a kind are stored as they are
                @test isnothing(OutputVault.recorded_kind(joinpath(OutputVault.economy_folder(cfg, rf), "solution", "obj.jld2")))
            end

            @testset "components saved by OutputVault 0.1 still load" begin
                rf_old = RunHandle("legacy"; branch="testbranch", experdef="base")
                epath  = OutputVault.economy_folder(cfg, rf_old; create=true)
                jldsave(joinpath(epath, "solution.jld2"); obj=2.5, val=3, git_commit_id="abc")
                sol = load(cfg, rf_old, :solution)
                @test sol == (obj=2.5, val=3)
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
                @test isfile(joinpath(epath, "solution", "obj.jld2"))
                # the untracked file is in the unstaged diff
                @test occursin("dirty_save.txt", read(joinpath(epath, "solution", "git_unstaged.diff"), String))
                # clean up the untracked file for later tests
                rm(joinpath(git_dir, "dirty_save.txt"); force=true)
            end
        end
    end
end
