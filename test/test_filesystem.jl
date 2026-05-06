@testset "filesystem" begin
    @testset "output_path" begin
        mktempdir() do root
            cfg = make_cfg(root)

            p = OutputVault.output_path(cfg, "mybranch")
            @test isdir(p)
            @test p == joinpath(root, "mybranch")

            # idempotent
            p2 = OutputVault.output_path(cfg, "mybranch")
            @test p2 == p
        end
    end

    @testset "output_path global config wrapper" begin
        mktempdir() do root
            cfg = make_cfg(root)
            with_config(cfg) do
                p = output_path("wrapbranch")
                @test isdir(p)
                @test p == joinpath(root, "wrapbranch")
            end
        end
    end

    @testset "economy_folder" begin
        mktempdir() do root
            cfg = make_cfg(root)
            rf  = RunHandle("usa"; branch="main", experdef="base")

            # create=true creates and returns the folder
            ef = OutputVault.economy_folder(cfg, rf; create=true)
            @test isdir(ef)
            @test ef == joinpath(root, "main", "res-base-usa")

            # path ends with res-<experdef>-<economy>
            @test endswith(ef, "res-base-usa")

            # create=false on existing folder is fine
            ef2 = OutputVault.economy_folder(cfg, rf; create=false)
            @test ef2 == ef

            # create=false on missing folder errors
            rf_missing = RunHandle("eu"; branch="main", experdef="base")
            @test_throws ErrorException OutputVault.economy_folder(cfg, rf_missing; create=false)

            # error message contains the path
            try
                OutputVault.economy_folder(cfg, rf_missing; create=false)
            catch e
                @test occursin("res-base-eu", e.msg)
            end
        end
    end

    @testset "economy_folder global config wrapper" begin
        mktempdir() do root
            cfg = make_cfg(root)
            rf  = RunHandle("usa"; branch="wrap", experdef="e")
            with_config(cfg) do
                ef = OutputVault.economy_folder(rf; create=true)
                @test isdir(ef)
                @test ef == joinpath(root, "wrap", "res-e-usa")
            end
        end
    end
end
