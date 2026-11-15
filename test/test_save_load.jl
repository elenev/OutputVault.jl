# result type for save/load tests: properties named in LAYOUT plus one that is not
struct _TestResult
    obj::Float64
    stv::Int
    stats::Int
    extra::String  # not in the layout — ignored
end

# a producer's type: stored under its own kind with jld2_record, restored by read_kind
struct _Kinded
    x::Int
end
OutputVault.storage_kind(::_Kinded) = "OutputVaultTests.Kinded"
OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, k::_Kinded;
                         provenance = Dict{String,String}()) =
    OutputVault.jld2_record(io -> (io["x"] = k.x), joinpath(dir, name * ".jld2"), k)
OutputVault.read_kind(::Val{Symbol("OutputVaultTests.Kinded")}, path; model = nothing) = _Kinded(JLD2.load(path, "x"))

@testset "save_load" begin
    git_dir = make_git_repo()

    with_tempdir() do root
        cfg = make_cfg(root)
        rf  = RunHandle("usa"; branch="testbranch", experdef="base")
        res = _TestResult(3.14, 7, 42, "ignored")

        cd(git_dir) do
            @testset "save_result: each property at its place in the layout" begin
                epath = save_result(cfg, rf, res; dirty_repo_check=:ignore)
                @test isdir(epath)
                @test epath == OutputVault.economy_folder(cfg, rf)
                @test isfile(joinpath(epath, "solution", "obj.jld2"))
                @test isfile(joinpath(epath, "solution", "stv.jld2"))
                @test isfile(joinpath(epath, "stats", "stats.jld2"))
                # nothing else: no folders for properties the result lacks, none for `extra`
                @test sort(readdir(epath)) == ["solution", "stats"]
                @test !isfile(joinpath(epath, "solution", "extra.jld2"))
            end

            @testset "the caller chooses what is saved" begin
                rf2 = RunHandle("partial"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf2, (; obj = 1.0, stats = nothing, errstats = 5); dirty_repo_check=:ignore)
                @test sort(readdir(epath)) == ["errstats", "solution"]
                @test !isfile(joinpath(epath, "solution", "stv.jld2"))
                @test load(cfg, rf2, :solution; solution_format = :portable) == (obj = 1.0,)
                @test load(cfg, rf2, :solution) == (obj = 1.0,)
                @test load(cfg, rf2, :errstats) == (errstats = 5,)
                @test_throws ErrorException load(cfg, rf2, :stats)
                @test_throws ArgumentError load(cfg, rf2, :unknown)
            end

            @testset "git commit in solution folder only" begin
                epath = OutputVault.economy_folder(cfg, rf)
                commit = strip(read(joinpath(epath, "solution", "git_commit.txt"), String))
                @test occursin(r"^[0-9a-f]{40}$", commit)
                @test !isfile(joinpath(epath, "solution", "git_unstaged.diff"))   # clean repo: no diffs
                @test !isfile(joinpath(epath, "stats", "git_commit.txt"))
            end

            @testset "load round-trip" begin
                @test load(cfg, rf, :solution) == (obj = res.obj, stv = res.stv)
                @test load(cfg, rf, :stats) == (stats = res.stats,)
            end

            @testset "load missing component errors" begin
                rf_missing = RunHandle("ghost"; branch="testbranch", experdef="base")
                mkpath(OutputVault.economy_folder(cfg, rf_missing; create=true))
                @test_throws ErrorException load(cfg, rf_missing, :solution)
            end

            @testset "global config wrappers" begin
                rf4 = RunHandle("wrap"; branch="testbranch", experdef="base")
                with_config(cfg) do
                    epath = save_result(rf4, res; dirty_repo_check=:ignore)
                    @test isfile(joinpath(epath, "solution", "obj.jld2"))
                    @test load(rf4, :solution).obj ≈ res.obj
                end
            end

            @testset "producer interface: storage kinds" begin
                rf_k  = RunHandle("kinded"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf_k, (; obj=_Kinded(5)); dirty_repo_check=:ignore)
                path  = joinpath(epath, "solution", "obj.jld2")
                @test OutputVault.recorded_kind(path) == "OutputVaultTests.Kinded"
                @test load(cfg, rf_k, :solution; solution_format = :portable).obj == _Kinded(5)
                @test load(cfg, rf_k, :solution).obj == _Kinded(5)
                # objects without a kind are stored as they are
                @test isnothing(OutputVault.recorded_kind(joinpath(OutputVault.economy_folder(cfg, rf), "solution", "obj.jld2")))
            end

            @testset "solution formats" begin
                # default: both copies of the solution; other components portable only
                rf_f  = RunHandle("formats"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf_f, res; dirty_repo_check=:ignore)
                @test isfile(joinpath(epath, "solution", "res.jld2"))
                @test isfile(joinpath(epath, "solution", "obj.jld2"))
                @test !isfile(joinpath(epath, "stats", "res.jld2"))
                @test load(cfg, rf_f, :solution) == (obj = res.obj, stv = res.stv)
                @test load(cfg, rf_f, :solution; solution_format = :portable) == (obj = res.obj, stv = res.stv)
                @test load(cfg, rf_f, :stats; solution_format = :native) == (stats = res.stats,)   # ignored
                @test_throws ArgumentError load(cfg, rf_f, :solution; solution_format = :other)

                # one format only
                for (fmt, files, missing_fmt) in ((:native, ["res.jld2"], :portable),
                                                  (:portable, ["obj.jld2", "stv.jld2"], :native))
                    cfg_1 = Config(; output_root=root, solution_format=fmt)
                    rf_1  = RunHandle("only_$fmt"; branch="testbranch", experdef="base")
                    epath = save_result(cfg_1, rf_1, res; dirty_repo_check=:ignore)
                    @test sort(readdir(joinpath(epath, "solution"))) == sort([files; "git_commit.txt"])
                    @test load(cfg_1, rf_1, :solution; solution_format = fmt) == (obj = res.obj, stv = res.stv)
                    @test_throws ErrorException load(cfg_1, rf_1, :solution; solution_format = missing_fmt)
                end
            end

            @testset "saving a solution replaces the economy folder" begin
                rf_c  = RunHandle("clear"; branch="testbranch", experdef="base")
                epath = save_result(cfg, rf_c, res; dirty_repo_check=:ignore)
                write(joinpath(epath, "solution", "stale.txt"), "x")
                write(joinpath(epath, "leftover.txt"), "x")
                # a save without solution objects adds to the folder
                save_result(cfg, rf_c, (; errstats = 1); dirty_repo_check=:ignore)
                @test isfile(joinpath(epath, "leftover.txt"))
                @test isfile(joinpath(epath, "solution", "obj.jld2"))
                @test isfile(joinpath(epath, "errstats", "errstats.jld2"))
                # a save with solution objects starts from an empty folder
                save_result(cfg, rf_c, (; obj = 2.0); dirty_repo_check=:ignore)
                @test !isfile(joinpath(epath, "leftover.txt"))
                @test !isfile(joinpath(epath, "solution", "stale.txt"))
                @test sort(readdir(epath)) == ["solution"]
            end

            @testset "components saved by OutputVault 0.1 still load" begin
                rf_old = RunHandle("legacy"; branch="testbranch", experdef="base")
                epath  = OutputVault.economy_folder(cfg, rf_old; create=true)
                jldsave(joinpath(epath, "solution.jld2"); obj=2.5, stv=3, git_commit_id="abc")
                @test load(cfg, rf_old, :solution) == (obj=2.5, stv=3)
            end

            @testset "dirty_repo_check=:error throws" begin
                write(joinpath(git_dir, "dirty_save.txt"), "x")
                rf5 = RunHandle("dirty_err"; branch="testbranch", experdef="base")
                @test_throws ErrorException save_result(cfg, rf5, res; dirty_repo_check=:error)
                # a failed check leaves an existing folder untouched
                @test_throws ErrorException save_result(cfg, rf, res; dirty_repo_check=:error)
                @test isfile(joinpath(OutputVault.economy_folder(cfg, rf), "solution", "obj.jld2"))
                # no files should have been written
                @test !isdir(OutputVault.output_path(cfg, "testbranch") * "/res-base-dirty_err")
            end

            @testset "dirty_repo_check=:warn saves and warns" begin
                rf6   = RunHandle("dirty_warn"; branch="testbranch", experdef="base")
                epath = nothing
                @test_logs (:warn, r"not clean") match_mode=:any begin
                    epath = save_result(cfg, rf6, res; dirty_repo_check=:warn)
                end
                @test isfile(joinpath(epath, "solution", "obj.jld2"))
                # the untracked file is in the unstaged diff
                @test occursin("dirty_save.txt", read(joinpath(epath, "solution", "git_unstaged.diff"), String))
                rm(joinpath(git_dir, "dirty_save.txt"); force=true)
            end
        end
    end
end
