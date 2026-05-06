@testset "global_config" begin
    _cfg_a = Config(; output_root="/tmp/a", components=(solution=(:x,),))
    _cfg_b = Config(; output_root="/tmp/b", components=(solution=(:x,),))

    # helper: run f() with global config reset to nothing afterwards
    function isolated(f)
        old = OutputVault._GLOBAL_CONFIG[]
        try
            f()
        finally
            OutputVault._GLOBAL_CONFIG[] = old
        end
    end

    @testset "unset config errors" begin
        isolated() do
            OutputVault._GLOBAL_CONFIG[] = nothing
            @test_throws ErrorException OutputVault.global_config()
        end
    end

    @testset "set_config! stores and retrieves" begin
        isolated() do
            ret = set_config!(_cfg_a)
            @test ret === _cfg_a
            @test OutputVault.global_config() === _cfg_a
        end
    end

    @testset "with_config restores on success" begin
        isolated() do
            set_config!(_cfg_a)
            with_config(_cfg_b) do
                @test OutputVault.global_config() === _cfg_b
            end
            @test OutputVault.global_config() === _cfg_a
        end
    end

    @testset "with_config restores on throw" begin
        isolated() do
            set_config!(_cfg_a)
            @test_throws ErrorException with_config(_cfg_b) do
                error("boom")
            end
            @test OutputVault.global_config() === _cfg_a
        end
    end

    @testset "with_config restores nothing" begin
        isolated() do
            OutputVault._GLOBAL_CONFIG[] = nothing
            with_config(_cfg_a) do
                @test OutputVault.global_config() === _cfg_a
            end
            @test OutputVault._GLOBAL_CONFIG[] === nothing
        end
    end

    @testset "with_config return value" begin
        isolated() do
            result = with_config(_cfg_a) do
                42
            end
            @test result == 42
        end
    end

    @testset "nested with_config" begin
        isolated() do
            set_config!(_cfg_a)
            with_config(_cfg_b) do
                @test OutputVault.global_config() === _cfg_b
                with_config(_cfg_a) do
                    @test OutputVault.global_config() === _cfg_a
                end
                @test OutputVault.global_config() === _cfg_b
            end
            @test OutputVault.global_config() === _cfg_a
        end
    end
end
