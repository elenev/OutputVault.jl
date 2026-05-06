@testset "discovery" begin

    # ── _rf_key ──────────────────────────────────────────────────────────────

    @testset "_rf_key formats" begin
        rf = RunHandle("usa"; branch="main", experdef="v1")

        @test OutputVault._rf_key(rf, :economy)               == :usa
        @test OutputVault._rf_key(rf, :experdef)              == :v1
        @test OutputVault._rf_key(rf, :branch)                == :main
        @test OutputVault._rf_key(rf, :experdef_economy)      == :v1_usa
        @test OutputVault._rf_key(rf, :branch_economy)        == :main_usa
        @test OutputVault._rf_key(rf, :branch_experdef)       == :main_v1
        @test OutputVault._rf_key(rf, :branch_experdef_economy) == :main_v1_usa
    end

    @testset "_rf_key sanitizes special characters" begin
        rf = RunHandle("us-east"; branch="feat/my-thing", experdef="v1.0")

        @test OutputVault._rf_key(rf, :economy)  == :us_east
        @test OutputVault._rf_key(rf, :branch)   == :feat_my_thing
        @test OutputVault._rf_key(rf, :experdef) == :v1_0

        # two distinct strings that sanitize to the same symbol
        rf_a = RunHandle("x"; branch="feat/abc", experdef="e")
        rf_b = RunHandle("x"; branch="feat-abc", experdef="e")
        @test OutputVault._rf_key(rf_a, :branch) == OutputVault._rf_key(rf_b, :branch)
    end

    @testset "_rf_key unknown format throws" begin
        rf = RunHandle("usa"; branch="main", experdef="v1")
        @test_throws ArgumentError OutputVault._rf_key(rf, :bogus)
    end

    # ── _auto_key_format ──────────────────────────────────────────────────────

    @testset "_auto_key_format" begin
        mkrf(eco; branch="main", exp="v1") = RunHandle(eco; branch=branch, experdef=exp)

        # unique economies → :economy
        @test OutputVault._auto_key_format([mkrf("usa"), mkrf("eu")]) == :economy

        # single handle → :economy
        @test OutputVault._auto_key_format([mkrf("usa")]) == :economy

        # same economy, different experdef → :experdef_economy
        @test OutputVault._auto_key_format([
            mkrf("usa"; exp="v1"), mkrf("usa"; exp="v2")
        ]) == :experdef_economy

        # same economy + experdef, different branches → :branch_experdef_economy
        @test OutputVault._auto_key_format([
            mkrf("usa"; branch="main", exp="v1"),
            mkrf("usa"; branch="dev",  exp="v1"),
        ]) == :branch_experdef_economy

        # branches that sanitize to the same symbol but unique experdef_economy →
        # :economy would collide, so escalates to :experdef_economy
        @test OutputVault._auto_key_format([
            RunHandle("usa"; branch="feat/x", experdef="v1"),
            RunHandle("eu";  branch="feat-x", experdef="v1"),
        ]) == :economy  # distinct economies, so :economy is unique

        # sanitization makes all three formats collide → fallback return after loop exits
        @test OutputVault._auto_key_format([
            RunHandle("usa"; branch="main/x", experdef="v1"),
            RunHandle("usa"; branch="main-x", experdef="v1"),
        ]) == :branch_experdef_economy
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
        mktempdir() do root
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
                @test all(k -> k isa Symbol, keys(r))
            end

            @testset "auto key selects experdef_economy for duplicate economy" begin
                # main has base-usa, base-eu, alt-usa → :economy has duplicate :usa
                r = find_matching_results(cfg, "main/res-*")
                @test haskey(r, :base_usa)
                @test haskey(r, :base_eu)
                @test haskey(r, :alt_usa)
            end

            @testset "explicit key_format" begin
                r = find_matching_results(cfg, "main/res-*"; key_format=:branch_experdef_economy)
                @test haskey(r, :main_base_usa)
                @test haskey(r, :main_alt_usa)
            end

            @testset "duplicate key throws" begin
                # :economy has duplicate :usa → should throw
                @test_throws ArgumentError find_matching_results(cfg, "main/res-*"; key_format=:economy)
            end

            @testset "cross-branch wildcard" begin
                r = find_matching_results(cfg, "*/res-base-usa")
                @test length(r) == 2
            end

            @testset "parsed fields" begin
                r = find_matching_results(cfg, "main/res-base-*"; key_format=:economy)
                @test r.usa.branch   == "main"
                @test r.usa.experdef == "base"
                @test r.usa.economy  == "usa"
                @test r.eu.economy   == "eu"
            end

            @testset "malformed folder name is silently skipped" begin
                mkpath(joinpath(root, "main", "res-nohyphen"))
                r = find_matching_results(cfg, "main/res-*")
                # should still have the 3 valid results, not the malformed one
                @test all(k -> k != :nohyphen, keys(r))
            end

            @testset "non-directory is excluded" begin
                write(joinpath(root, "main", "res-base-fakefile"), "")
                r = find_matching_results(cfg, "main/res-*")
                @test !haskey(r, :fakefile)
                @test !haskey(r, :base_fakefile)
            end

            @testset "economy with hyphen parses correctly" begin
                mkpath(joinpath(root, "main", "res-base-us-east"))
                r = find_matching_results(cfg, "main/res-base-us-east"; key_format=:economy)
                @test haskey(r, :us_east)
                @test r.us_east.economy  == "us-east"
                @test r.us_east.experdef == "base"
            end

            @testset "experdef with hyphen — known limitation" begin
                # res-my-v2-usa: regex captures experdef="my", economy="v2-usa"
                # because experdef capture is [^-]+ (no hyphens)
                mkpath(joinpath(root, "main", "res-my-v2-usa"))
                r = find_matching_results(cfg, "main/res-my-v2-usa"; key_format=:experdef_economy)
                k = only(keys(r))
                rf = r[k]
                @test rf.experdef == "my"
                @test rf.economy  == "v2-usa"
            end

            @testset "global config wrapper" begin
                with_config(cfg) do
                    r = find_matching_results("main/res-base-*"; key_format=:economy)
                    @test haskey(r, :usa)
                end
            end
        end
    end

end
