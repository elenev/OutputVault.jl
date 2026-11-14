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
    cfg = Config(; output_root = "/tmp/test")
    @test OutputVault.output_root(cfg)     == "/tmp/test"
    @test isnothing(OutputVault.table_format(cfg))
    @test OutputVault.solution_format(cfg) == (:portable, :native)

    cfg2 = Config(; output_root = "/tmp/x", table_format = OutputVault.Formats.ParquetFormat(),
                  solution_format = :portable)
    @test OutputVault.table_format(cfg2) === OutputVault.Formats.ParquetFormat()
    @test OutputVault.solution_format(cfg2) == (:portable,)
    @test_throws ArgumentError Config(; output_root = "/tmp/x", solution_format = :exact)
    @test_throws ArgumentError Config(; output_root = "/tmp/x", solution_format = ())
end

@testset "LAYOUT" begin
    @test keys(LAYOUT) == (:solution, :stats, :errstats, :simulation, :irf)
    @test LAYOUT.solution == (:obj, :stv) && LAYOUT.stats == (:stats,) && LAYOUT.errstats == (:errstats,)
    @test OutputVault.layout_properties(:simulation) == (:simseries, :errs)
    @test_throws ArgumentError OutputVault.layout_properties(:other)
end

@testset "table formats" begin
    fmt = TableFormat(ext = "txt", write = (path, t, m) -> write(path, "x"), read = path -> read(path, String))
    @test OutputVault.table_extension(fmt) == "txt"
    path = tempname() * ".txt"
    OutputVault.write_table_file(fmt, path, nothing, Dict{String,String}())
    @test OutputVault.read_table_file(fmt, path) == "x"
    @test OutputVault.table_extension(OutputVault.Formats.ParquetFormat()) == "parquet"
end

struct _MinCfg <: OutputVault.AbstractConfig end  # module-level: struct inside @testset is a syntax error
struct _NoContract <: OutputVault.AbstractTableFormat end

@testset "AbstractConfig interface" begin
    mc = _MinCfg()
    @test_throws ErrorException OutputVault.output_root(mc)
    @test isnothing(OutputVault.table_format(mc))
    @test OutputVault.solution_format(mc) == (:portable, :native)
    @test_throws ErrorException OutputVault.write_table_file(_NoContract(), "p", nothing, Dict{String,String}())
end
