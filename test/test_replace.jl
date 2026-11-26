# Replacing a run when its solution is saved again (src/items.jl, replace_run). The test bodies
# never collect garbage, so that files an earlier read left mapped stay locked on Windows;
# with_tempdir only collects at teardown.

using OutputVault: run_path

# a run whose solution is `(; a)` and whose stats have mean `m`
function save_run(rf, a, m)
    dir = save_solution(rf, (; a); dirty_repo_check = :ignore)
    if dir == run_path(rf)
        save_result_item(rf, "stats/stats", (variable = ["K"], mean = [m]))
    end
    return dir
end

stats_mean(rf) = Tables.columns(load_result_item(rf, "stats/stats")).mean
solution_a(rf) = load_result_item(rf, "solution/a")["value"]
trash_folders(final) = filter(startswith(".trash-"), readdir(dirname(final)))

@testset "Replacing a run" begin
    rf = RunHandle("base"; branch = "main", experdef = "v1")

    @testset "plain replacement" begin
        with_vault() do root, repo
            save_run(rf, 1, 1.0)
            @test save_run(rf, 2, 2.0) == run_path(rf)
            @test stats_mean(rf) == [2.0]
            @test solution_a(rf) == 2
            @test isempty(trash_folders(run_path(rf)))
            @test isempty(readdir(joinpath(root, ".staging")))
        end
    end

    @testset "old run with a memory-mapped file" begin
        with_vault() do root, repo
            save_run(rf, 1, 1.0)
            col = stats_mean(rf)             # keeps the file mapped
            # the rename succeeds and the new run is in place; on Windows the delete of the old
            # run is blocked by the mapping, which only warns
            path = if Sys.iswindows()
                @test_logs (:warn, r"could not be deleted") save_run(rf, 2, 2.0)
            else
                @test_logs save_run(rf, 2, 2.0)
            end
            @test path == run_path(rf)
            @test stats_mean(rf) == [2.0]
            @test solution_a(rf) == 2
            if Sys.iswindows()
                @test !isempty(trash_folders(run_path(rf)))
            end
            @test col == [1.0]
        end
    end

    if Sys.iswindows()
        @testset "old run cannot be renamed: the new run stays in staging" begin
            with_vault() do root, repo
                save_run(rf, 1, 1.0)
                io = open(joinpath(run_path(rf), ".provenance", "git_commit.txt"))   # an open file blocks the rename
                path = @test_logs (:warn, r"NEW RUN NOT AT THE RUN'S PATH") save_run(rf, 2, 2.0)
                close(io)
                @test path != run_path(rf) && startswith(path, joinpath(root, ".staging"))
                # the old run is intact where it was, the new one is complete in staging
                @test stats_mean(rf) == [1.0]
                @test solution_a(rf) == 1
                @test isfile(joinpath(path, "solution", "a.jld2"))
                @test isfile(joinpath(path, "native.jld2"))
                @test isempty(trash_folders(run_path(rf)))
            end
        end
    end

    @testset "staged run cannot be moved: the old run is restored" begin
        with_vault() do root, repo
            save_run(rf, 1, 1.0)
            missing_stage = joinpath(root, ".staging", "v1-base-none")   # nothing to move
            path = @test_logs (:warn, r"NEW RUN NOT AT THE RUN'S PATH: the new run cannot be moved") OutputVault.replace_run(missing_stage, run_path(rf))
            @test path == missing_stage
            @test solution_a(rf) == 1 && stats_mean(rf) == [1.0]
            @test isempty(trash_folders(run_path(rf)))
        end
    end

    @testset "the warning lists every copy" begin
        logger = Test.TestLogger()
        Base.CoreLogging.with_logger(logger) do
            OutputVault.stranded("STAGE", "FINAL", "a reason", ErrorException("boom"); trash = "TRASH")
        end
        msg = string(only(logger.logs).message)
        @test all(occursin(msg), ["STAGE", "FINAL", "TRASH", "a reason", "boom"])
    end
end
