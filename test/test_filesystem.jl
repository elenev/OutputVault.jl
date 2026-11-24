@testset "filesystem" begin
    @testset "output_path" begin
        with_tempdir() do root
            cfg = make_cfg(root)

            # default: the path only, nothing created
            p = OutputVault.output_path(cfg, "mybranch")
            @test p == joinpath(root, "mybranch")
            @test !isdir(p)

            # create=true creates it; idempotent
            @test OutputVault.output_path(cfg, "mybranch"; create=true) == p
            @test isdir(p)
            @test OutputVault.output_path(cfg, "mybranch"; create=true) == p
        end
    end

    @testset "output_path global config wrapper" begin
        with_tempdir() do root
            cfg = make_cfg(root)
            with_config(cfg) do
                p = output_path("wrapbranch")
                @test p == joinpath(root, "wrapbranch")
                @test !isdir(p)
                @test output_path("wrapbranch"; create=true) == p
                @test isdir(p)
            end
        end
    end

    @testset "economy_folder" begin
        with_tempdir() do root
            cfg = make_cfg(root)
            rf  = RunHandle("usa"; branch="main", experdef="base")

            # missing folder errors with its path and creates nothing
            err = try OutputVault.economy_folder(cfg, rf); nothing catch e; e end
            @test err isa ErrorException
            @test occursin("res-base-usa", err.msg)
            @test !isdir(joinpath(root, "main"))

            # existing folder is returned
            mkpath(joinpath(root, "main", "res-base-usa"))
            @test OutputVault.economy_folder(cfg, rf) == joinpath(root, "main", "res-base-usa")
        end
    end

    @testset "economy_folder global config wrapper" begin
        with_tempdir() do root
            cfg = make_cfg(root)
            rf  = RunHandle("usa"; branch="wrap", experdef="e")
            mkpath(joinpath(root, "wrap", "res-e-usa"))
            with_config(cfg) do
                @test OutputVault.economy_folder(rf) == joinpath(root, "wrap", "res-e-usa")
            end
        end
    end
end
