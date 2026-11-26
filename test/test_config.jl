struct MinimalConfig <: AbstractConfig end
OutputVault.output_root(::MinimalConfig) = "/tmp/minimal"

struct NoRootConfig <: AbstractConfig end

@testset "Config" begin
    cfg = Config(; output_root = "/tmp/test")
    @test OutputVault.output_root(cfg) == "/tmp/test"
    @test isnothing(OutputVault.table_format(cfg))
    @test OutputVault.native(cfg)
    @test OutputVault.staging_root(cfg) == joinpath("/tmp/test", ".staging")
    cfg2 = Config(; output_root = "/r", table_format = PARQUET, native = false, staging_root = "/s")
    @test OutputVault.table_format(cfg2) === PARQUET && !OutputVault.native(cfg2) && OutputVault.staging_root(cfg2) == "/s"

    mc = MinimalConfig()
    @test isnothing(OutputVault.table_format(mc)) && OutputVault.native(mc)
    @test OutputVault.staging_root(mc) == joinpath("/tmp/minimal", ".staging")
    @test_throws ErrorException OutputVault.output_root(NoRootConfig())
end

@testset "active configuration" begin
    old = OutputVault._GLOBAL_CONFIG[]
    try
        OutputVault._GLOBAL_CONFIG[] = nothing
        @test_throws ErrorException OutputVault.global_config()
        a, b = Config(; output_root = "/a"), Config(; output_root = "/b")
        @test set_config!(a) === a
        @test OutputVault.global_config() === a
        @test with_config(() -> OutputVault.global_config(), b) === b
        @test OutputVault.global_config() === a
        @test_throws ErrorException with_config(() -> error("x"), b)
        @test OutputVault.global_config() === a
    finally
        OutputVault._GLOBAL_CONFIG[] = old
    end
end
