@testset "find_runs" begin
    with_vault() do root, repo
        runs = [RunHandle("base"; branch = "main", experdef = "v1"), RunHandle("alt"; branch = "main", experdef = "v1"),
                RunHandle("base"; branch = "main", experdef = "v2"), RunHandle("base"; branch = "feature/x", experdef = "v1"),
                RunHandle("frm-grid5"; branch = "feature", experdef = "v1")]
        foreach(rf -> save_solution(rf, (; x = 1)), runs)
        mkpath(joinpath(root, "main", "res-v1-bad name"))        # not a valid variant
        mkpath(joinpath(root, "main", "res-v1"))                 # no variant
        mkpath(joinpath(root, "main", "results"))                # a branch level without runs
        mkpath(joinpath(root, "main", ".trash-res-v1-old"))

        @test (@test_logs (:warn, r"res-v1: not a run folder name") (:warn, r"bad name") find_runs()) ==
              [RunHandle("frm-grid5"; branch = "feature", experdef = "v1"), runs[2], runs[1], runs[3]]
        @test find_runs(RunPattern(; experdef = "v1", variant = "base")) == [runs[1]]
        @test find_runs(RunPattern(; branch = "**", variant = "base")) == [runs[4], runs[1], runs[3]]
        @test find_runs(RunPattern(; branch = "feature/*")) == [runs[4]]
        @test find_runs(RunPattern(; branch = "**", variant = "frm-*")) == [runs[5]]
        @test isempty(find_runs(RunPattern(; branch = "absent")))
        @test isempty(find_runs(; root = joinpath(root, "nowhere")))
        @test find_runs(RunPattern(; variant = "alt"); root) == [runs[2]]
    end
end
