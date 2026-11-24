# Replacing a run's folder when a new solution is saved (src/save_load.jl, "Replacing a run's
# folder"). Fake data, no model. The test bodies never collect garbage, so that files an earlier
# read left mapped stay locked on Windows; with_tempdir only collects at teardown.
using Parquet2, Tables

struct RSummary
    variable::Vector{String}
    mean::Vector{Float64}
end
Tables.istable(::Type{RSummary}) = true
Tables.columnaccess(::Type{RSummary}) = true
Tables.columns(s::RSummary) = (variable = s.variable, mean = s.mean)
OutputVault.storage_kind(::RSummary) = "OutputVaultTests.RSummary"
OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, s::RSummary; provenance = Dict{String,String}()) =
    OutputVault.write_table(cfg, joinpath(dir, name), s)
OutputVault.read_kind(::Val{Symbol("OutputVaultTests.RSummary")}, source, path, fmt) =
    RSummary(string.(Tables.getcolumn(source, :variable)), collect(Float64, Tables.getcolumn(source, :mean)))

# a run saved with solution `(a = a,)` and stats with mean `m`
function save_run(cfg, rf, a, m)
    save_result(cfg, rf, (; obj = (a = a,), stats = RSummary(["K"], [m])); dirty_repo_check = :ignore)
end

# config, run handle and the pieces of paths for a fresh root
function replace_setup(root)
    cfg = Config(; output_root = joinpath(root, "out"), table_format = OutputVault.Formats.ParquetFormat(),
                 staging_root = joinpath(root, "staging"))
    rf = RunHandle("base"; branch = "main", experdef = "v1")
    cfg, rf, joinpath(root, "out", "main", "res-v1-base")
end

@testset "Replacing a run's folder" begin
    git_dir = make_git_repo()

    @testset "plain replacement" begin
        with_tempdir() do root
            cfg, rf, final = replace_setup(root)
            cd(git_dir) do
                save_run(cfg, rf, 1, 1.0)
                @test save_run(cfg, rf, 2, 2.0) == final
                @test load(cfg, rf, :stats).stats.mean == [2.0]
                @test load(cfg, rf, :solution).obj == (a = 2,)
                @test !any(startswith(".replaced"), readdir(dirname(final)))
                @test isempty(readdir(joinpath(root, "staging", "main")))
            end
        end
    end

    @testset "old folder with a memory-mapped file" begin
        with_tempdir() do root
            cfg, rf, final = replace_setup(root)
            cd(git_dir) do
                save_run(cfg, rf, 1, 1.0)
                ds = Parquet2.Dataset(joinpath(final, "stats", "stats.parquet"))
                col = Tables.columntable(ds)   # keeps the file mapped
                # the rename succeeds and the new results are in place; on Windows the delete of
                # the renamed folder is blocked by the mapping, which only warns
                path = if Sys.iswindows()
                    @test_logs (:warn, r"could not be deleted") save_run(cfg, rf, 2, 2.0)
                else
                    @test_logs save_run(cfg, rf, 2, 2.0)
                end
                @test path == final
                @test load(cfg, rf, :stats).stats.mean == [2.0]
                @test load(cfg, rf, :solution).obj == (a = 2,)
                Sys.iswindows() && @test any(startswith(".replaced"), readdir(dirname(final)))
                @test col.mean == [1.0]
            end
        end
    end

    if Sys.iswindows()
        @testset "old folder cannot be renamed: results stay in staging" begin
            with_tempdir() do root
                cfg, rf, final = replace_setup(root)
                cd(git_dir) do
                    save_run(cfg, rf, 1, 1.0)
                    io = open(joinpath(final, "solution", "git_commit.txt"))   # an open file blocks the rename
                    path = @test_logs (:warn, r"RESULTS NOT AT THE RUN'S PATH") save_run(cfg, rf, 2, 2.0)
                    close(io)
                    @test path != final && startswith(path, joinpath(root, "staging"))
                    # the old results are intact where they were, the new ones are complete in staging
                    @test load(cfg, rf, :stats).stats.mean == [1.0]
                    @test load(cfg, rf, :solution).obj == (a = 1,)
                    @test isfile(joinpath(path, "stats", "stats.parquet"))
                    @test isfile(joinpath(path, "solution", "res.jld2"))
                    @test !any(startswith(".replaced"), readdir(dirname(final)))
                end
            end
        end
    end

    @testset "what a save replaces" begin
        with_tempdir() do root
            cfg, rf, final = replace_setup(root)
            cd(git_dir) do
                save_run(cfg, rf, 1, 1.0)
                # a solution object set to nothing does not count: the save adds to the run
                @test save_result(cfg, rf, (; obj = nothing, irf = RSummary(["K"], [0.5]))) == final
                @test sort(readdir(final)) == ["irf", "solution", "stats"]
                # a save of stv alone replaces the whole run, obj included
                @test save_result(cfg, rf, (; stv = (b = 1,)); dirty_repo_check = :ignore) == final
                @test readdir(final) == ["solution"]
                @test keys(load(cfg, rf, :solution)) == (:stv,)
                @test !isfile(joinpath(final, "solution", "obj.jld2"))
            end
        end
    end

    @testset "staged folder cannot be moved: the old folder is restored" begin
        with_tempdir() do root
            cfg, rf, final = replace_setup(root)
            cd(git_dir) do
                save_run(cfg, rf, 1, 1.0)
                missing_stage = joinpath(root, "staging", "main", "res-v1-base-0")   # nothing to move
                path = @test_logs (:warn, r"RESULTS NOT AT THE RUN'S PATH: the staged folder cannot be moved") OutputVault._replace_folder(missing_stage, final)
                @test path == missing_stage
                @test load(cfg, rf, :solution).obj == (a = 1,) && load(cfg, rf, :stats).stats.mean == [1.0]
                @test !any(startswith(".replaced"), readdir(dirname(final)))
            end
        end
    end

    @testset "the warning lists every copy" begin
        msg = ""
        logger = Test.TestLogger()
        Base.CoreLogging.with_logger(logger) do
            OutputVault._stranded("STAGE", "FINAL", "a reason", ErrorException("boom"); aside = "ASIDE")
        end
        msg = string(only(logger.logs).message)
        @test all(occursin(msg), ["STAGE", "FINAL", "ASIDE", "a reason", "boom"])
    end
end
