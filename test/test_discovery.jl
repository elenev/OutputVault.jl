@testset "discovery" begin

    # ── run keys ─────────────────────────────────────────────────────────────

    @testset "run keys" begin
        run(b, x, e) = (branch = b, experdef = x, economy = e)
        runs = [run("main", "v1", "usa"), run("main", "v1", "eu")]
        @test OutputVault.run_keys(runs, OutputVault.RUN_FIELDS) == [:main__v1__usa, :main__v1__eu]
        @test OutputVault.run_keys(runs, :economy) == [:usa, :eu]
        @test OutputVault.run_keys(runs, (:experdef, :economy)) == [:v1__usa, :v1__eu]
        @test OutputVault.run_keys(runs, (:economy, :branch)) == [:usa__main, :eu__main]   # in the order given
        # characters other than letters, digits and _ become _
        @test OutputVault.run_keys([run("feat/my-thing", "v1", "us-east")], OutputVault.RUN_FIELDS) == [:feat_my_thing__v1__us_east]
        # bad keys
        for bad in (:bogus, (), (:economy, :economy), ("economy",))
            @test_throws ArgumentError OutputVault.run_keys(runs, bad)
        end
        # a clash names the runs and suggests a longer key
        clash = [run("main", "v1", "usa"), run("dev", "v1", "usa")]
        err = try OutputVault.run_keys(clash, :economy); nothing catch e; e end
        @test err isa ArgumentError && occursin("main/res-v1-usa", err.msg) && occursin("dev/res-v1-usa", err.msg) &&
              occursin("longer key", err.msg)
        @test OutputVault.run_keys(clash, (:branch, :economy)) == [:main__usa, :dev__usa]
        # with the full key, only the replaced characters can clash
        err = try OutputVault.run_keys([run("feat/x", "v1", "usa"), run("feat-x", "v1", "usa")], OutputVault.RUN_FIELDS); nothing catch e; e end
        @test err isa ArgumentError && occursin("rename", err.msg)
    end

    # ── get_results_folders ───────────────────────────────────────────────────

    @testset "get_results_folders" begin
        cfg = make_cfg("/tmp/irrelevant")  # output_root not used here

        # NTuple of Symbols
        r = get_results_folders(cfg, (:usa, :eu); branch="main", experdef="v1")
        @test r isa NamedTuple
        @test keys(r) == (:usa, :eu)
        @test r.usa isa RunHandle
        @test r.usa.economy  == "usa"
        @test r.usa.branch   == "main"
        @test r.usa.experdef == "v1"

        # NTuple of Strings
        r2 = get_results_folders(cfg, ("usa", "eu"); branch="main", experdef="v1")
        @test keys(r2) == (:usa, :eu)
        @test r2.usa.economy == "usa"

        # Vector of Strings
        r3 = get_results_folders(cfg, ["usa", "eu"]; branch="main", experdef="v1")
        @test keys(r3) == (:usa, :eu)

        # scalar String
        r4 = get_results_folders(cfg, "solo"; branch="main", experdef="v1")
        @test keys(r4) == (:solo,)
        @test r4.solo.economy == "solo"

        # scalar Symbol
        r5 = get_results_folders(cfg, :solo; branch="main", experdef="v1")
        @test keys(r5) == (:solo,)
        @test r5.solo.economy == "solo"

        # global config wrapper
        with_config(cfg) do
            r6 = get_results_folders((:usa,); branch="main", experdef="v1")
            @test r6.usa.economy == "usa"
        end
    end

    # ── find_matching_results ─────────────────────────────────────────────────

    @testset "find_matching_results" begin
        with_tempdir() do root
            cfg = make_cfg(root)

            # empty glob returns empty NamedTuple
            @test find_matching_results(cfg, "nonexistent/res-*") == NamedTuple()

            # build folder tree
            mkpath(joinpath(root, "main", "res-base-usa"))
            mkpath(joinpath(root, "main", "res-base-eu"))
            mkpath(joinpath(root, "main", "res-alt-usa"))
            mkpath(joinpath(root, "feat", "res-base-usa"))

            @testset "basic glob and parsing" begin
                r = find_matching_results(cfg, "main/res-*")
                @test length(r) == 3
                @test all(v -> v isa RunHandle, values(r))
                @test keys(r) == (:main__alt__usa, :main__base__eu, :main__base__usa)   # the full key by default
            end

            @testset "a shorter key" begin
                r = find_matching_results(cfg, "main/res-*"; key = (:experdef, :economy))
                @test keys(r) == (:alt__usa, :base__eu, :base__usa)
                r = find_matching_results(cfg, "main/res-base-*"; key = :economy)
                @test r.usa.branch == "main" && r.usa.experdef == "base" && r.usa.economy == "usa"
                @test r.eu.economy == "eu"
            end

            @testset "a key that clashes throws" begin
                @test_throws ArgumentError find_matching_results(cfg, "main/res-*"; key = :economy)    # usa twice
                @test_throws ArgumentError find_matching_results(cfg, "*/res-base-usa"; key = :economy) # main and feat
                @test keys(find_matching_results(cfg, "*/res-base-usa"; key = (:branch, :economy))) == (:feat__usa, :main__usa)
            end

            @testset "nested branch keeps its full name" begin
                mkpath(joinpath(root, "feature", "x", "res-base-usa"))
                r = find_matching_results(cfg, "feature/x/res-*")
                @test only(values(r)).branch == "feature/x"
                @test keys(r) == (:feature_x__base__usa,)
            end

            @testset "malformed folder name is skipped" begin
                mkpath(joinpath(root, "main", "res-nohyphen"))
                @test length(find_matching_results(cfg, "main/res-*")) == 3
            end

            @testset "non-directory is excluded" begin
                write(joinpath(root, "main", "res-base-fakefile"), "")
                @test !haskey(find_matching_results(cfg, "main/res-*"), :main__base__fakefile)
            end

            @testset "economy with hyphen parses correctly" begin
                mkpath(joinpath(root, "main", "res-base-us-east"))
                r = find_matching_results(cfg, "main/res-base-us-east"; key = :economy)
                @test r.us_east.economy == "us-east" && r.us_east.experdef == "base"
            end

            @testset "experdef with hyphen: split at the first hyphen" begin
                mkpath(joinpath(root, "main", "res-my-v2-usa"))
                rf = only(values(find_matching_results(cfg, "main/res-my-v2-usa")))
                @test rf.experdef == "my" && rf.economy == "v2-usa"
            end

            @testset "global config wrapper" begin
                with_config(cfg) do
                    r = find_matching_results("main/res-base-*"; key = :economy)
                    @test haskey(r, :usa)
                end
            end
        end
    end

end
