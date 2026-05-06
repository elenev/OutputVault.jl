@testset "RunHandle" begin
    rh = RunHandle(; branch="main", experdef="v1", economy="usa")
    @test rh.branch   == "main"
    @test rh.experdef == "v1"
    @test rh.economy  == "usa"

    # positional convenience constructor
    rh2 = RunHandle("usa"; branch="main", experdef="v1")
    @test rh2 == rh

    # Symbol economy is coerced to String
    rh3 = RunHandle(:usa; branch="main", experdef="v1")
    @test rh3.economy == "usa"

    # default experdef
    rh4 = RunHandle("foo"; branch="main")
    @test rh4.experdef == "default"
    @test rh4.economy  == "foo"

    # inner constructor: keyword path with Symbol/non-String args are coerced
    rh5 = RunHandle(; branch=:main, experdef=:v1, economy=:usa)
    @test rh5.branch   == "main"
    @test rh5.experdef == "v1"
    @test rh5.economy  == "usa"
    @test rh5.branch   isa String
    @test rh5.experdef isa String
    @test rh5.economy  isa String

    # inner constructor: integer-convertible values (any string()-able type)
    rh6 = RunHandle(; branch="main", experdef="v1", economy=42)
    @test rh6.economy == "42"

    # default branch calls current_branch() — smoke test inside a git repo
    git_dir = make_git_repo()
    cd(git_dir) do
        rh7 = RunHandle("x"; experdef="e")
        @test rh7.branch isa String
        @test !isempty(rh7.branch)
    end
end

@testset "Config" begin
    cfg = Config(;
        output_root     = "/tmp/test",
        components      = (solution=(:x, :y), stats=(:z,)),
        git_component   = :solution,
        skip_components = (:simulation,),
    )
    @test OutputVault.output_root(cfg)     == "/tmp/test"
    @test OutputVault.components(cfg)      == (solution=(:x, :y), stats=(:z,))
    @test OutputVault.git_component(cfg)   == :solution
    @test OutputVault.skip_components(cfg) == (:simulation,)

    # defaults
    cfg2 = Config(; output_root="/tmp/x", components=(solution=(:a,),))
    @test OutputVault.git_component(cfg2)   == :solution
    @test OutputVault.skip_components(cfg2) == (:simulation,)

    # skip_components as Vector is stored as NTuple
    cfg3 = Config(;
        output_root     = "/tmp/y",
        components      = (solution=(:a,),),
        skip_components = [:simulation, :stats],
    )
    @test OutputVault.skip_components(cfg3) isa NTuple
    @test OutputVault.skip_components(cfg3) == (:simulation, :stats)

    # empty skip_components
    cfg4 = Config(; output_root="/tmp/z", components=(solution=(:a,),), skip_components=())
    @test OutputVault.skip_components(cfg4) == ()
    @test OutputVault.skip_components(cfg4) isa NTuple{0, Symbol}

    # type parameter N matches length
    @test typeof(cfg3) <: OutputVault.Config{<:NamedTuple, 2}
    @test typeof(cfg4) <: OutputVault.Config{<:NamedTuple, 0}
end

struct _MinCfg <: OutputVault.AbstractConfig end  # module-level: struct inside @testset is a syntax error

@testset "AbstractConfig interface" begin
    mc = _MinCfg()

    # all four interface methods error on a bare subtype
    @test_throws ErrorException OutputVault.output_root(mc)
    @test_throws ErrorException OutputVault.components(mc)
    @test_throws ErrorException OutputVault.git_component(mc)
    @test_throws ErrorException OutputVault.skip_components(mc)
end
