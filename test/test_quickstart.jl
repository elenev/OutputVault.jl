# The model-free quick start of docs/src/guide/quickstart.md: a tiny producer type, saving, adding a
# result later, loading, replacement on saving a solution, and a DuckDB query.
using DuckDB, Tables

struct QSummary
    variable::Vector{String}
    mean::Vector{Float64}
    std::Vector{Float64}
end
Tables.istable(::Type{QSummary}) = true
Tables.columnaccess(::Type{QSummary}) = true
Tables.columns(s::QSummary) = (variable = s.variable, mean = s.mean, std = s.std)
OutputVault.storage_kind(::QSummary) = "OutputVaultTests.QSummary"
OutputVault.write_object(cfg::OutputVault.AbstractConfig, dir, name, s::QSummary; provenance = Dict{String,String}()) =
    OutputVault.write_table(cfg, joinpath(dir, name), s)
OutputVault.read_kind(::Val{Symbol("OutputVaultTests.QSummary")}, source, path, fmt) =
    QSummary(string.(Tables.getcolumn(source, :variable)),
             collect(Float64, Tables.getcolumn(source, :mean)), collect(Float64, Tables.getcolumn(source, :std)))

@testset "Quick start without a model" begin
    git_dir = make_git_repo()
    with_tempdir() do root
        cfg = Config(; output_root = root, table_format = PARQUET)
        rf = RunHandle("base"; branch = "main", experdef = "v1")
        folder = joinpath(root, "main", "res-v1-base")
        cd(git_dir) do
            save_result(cfg, rf, (; obj = (α = 0.33, β = 0.96), stats = QSummary(["K", "C"], [3.5, 1.2], [0.4, 0.1]));
                        dirty_repo_check = :ignore)
            @test sort(readdir(folder)) == ["solution", "stats"]

            save_result(cfg, rf, (; irf = QSummary(["K", "C"], [0.0, 0.01], [0.0, 0.0])); dirty_repo_check = :ignore)
            @test sort(readdir(folder)) == ["irf", "solution", "stats"]
            @test load(cfg, rf, :stats).stats.mean == [3.5, 1.2]
            @test load(cfg, rf, :solution).obj == (α = 0.33, β = 0.96)

            # a new solution replaces the run's folder
            save_result(cfg, rf, (; obj = (α = 0.33, β = 0.95)); dirty_repo_check = :ignore)
            @test readdir(folder) == ["solution"]

            # without solution objects the repository is not checked, even in a dirty one; with them it is
            write(joinpath(git_dir, "dirty.txt"), "x")
            @test_logs save_result(cfg, rf, (; irf = QSummary(["K"], [0.0], [0.0])))
            @test_logs save_result(cfg, rf, (; irf = QSummary(["K"], [0.0], [0.0])); dirty_repo_check = :error)
            @test !isfile(joinpath(folder, "irf", "git_commit.txt"))
            @test_logs (:warn, r"not clean") match_mode = :any save_result(cfg, rf, (; obj = (α = 0.33, β = 0.95)))
            @test isfile(joinpath(folder, "solution", "git_commit.txt"))

            save_result(cfg, rf, (; stats = QSummary(["K", "C"], [3.4, 1.19], [0.4, 0.1])); dirty_repo_check = :ignore)
        end

        con = DBInterface.connect(DuckDB.DB)
        foreach(s -> DBInterface.execute(con, s), duckdb_statements())
        q = Tables.columntable(DBInterface.execute(con,
            "SELECT economy, variable, stat, value FROM vault_stats('$root') ORDER BY variable, stat"))
        @test q.variable == ["C", "C", "K", "K"] && q.stat == ["mean", "std", "mean", "std"]
        @test q.value == [1.19, 0.1, 3.4, 0.4] && all(==("base"), q.economy)
    end
end
