# The DuckDB interface (sql/outputvault.sql) over a temporary output root with saved TFI runs:
# long-form columns, run identity from paths (nested branch, hyphens in economy), the economy
# split, and Windows separators. Uses tfi_fixtures.jl and PARQUET from test_tfi.jl.
using DuckDB

@testset "DuckDB interface" begin
    git_dir = make_git_repo()
    con = DBInterface.connect(DuckDB.DB)
    foreach(s -> DBInterface.execute(con, s), duckdb_statements())
    @test isfile(duckdb_sql_path())
    q(sql) = Tables.columntable(DBInterface.execute(con, sql))

    samples = describe(simseries; filters = (a_all = Returns(true),)).moments
    mktempdir() do root
        cfg = Config(; output_root = root, table_format = PARQUET)
        cd(git_dir) do
            save_result(cfg, RunHandle("frm_init-a"; branch = "feat/nested", experdef = "base"),
                        (; obj, stats = samples, errstats, simseries); dirty_repo_check = :ignore)
            save_result(cfg, RunHandle("arm"; branch = "main", experdef = "alt"),
                        (; obj, stats = samples, errstats); dirty_repo_check = :ignore)
        end

        runs = q("SELECT * FROM vault_runs('$root') ORDER BY economy")
        @test keys(runs) == (:branch, :experdef, :economy)
        @test runs.branch == ["main", "feat/nested"] && runs.experdef == ["alt", "base"]
        @test runs.economy == ["arm", "frm_init-a"]

        st = q("SELECT * FROM vault_stats('$root')")
        @test keys(st) == (:branch, :experdef, :economy, :sample, :variable, :stat, :value)
        @test Set(st.sample) == Set(["uncond", "a_all"])
        K_mean = q("SELECT value FROM vault_stats('$root')
                    WHERE economy = 'arm' AND sample = 'uncond' AND variable = 'K' AND stat = 'mean'").value
        @test only(K_mean) == TransitionFunctionIteration.getmoment(samples.uncond, :K, :mean)
        @test length(st.value) == 2 * 2 * length(samples.uncond.data)   # runs × samples × cells

        es = q("SELECT * FROM vault_errstats('$root') WHERE economy = 'frm_init-a'")
        @test keys(es) == (:branch, :experdef, :economy, :variable, :stat, :value)
        @test length(es.value) == length(errstats.data)

        sim = q("SELECT branch, economy, count(*) AS n FROM vault_simulation('$root') GROUP BY ALL")
        @test sim.branch == ["feat/nested"] && sim.economy == ["frm_init-a"]
        @test only(sim.n) == length(simseries.data)

        # economy split by a project regex: named columns after economy, '' where a group is empty
        sp = q("SELECT DISTINCT * FROM vault_runs('$root', '^([^_]+)(?:_(.+))?\$', ['model', 'scheme'])
                ORDER BY economy")
        @test keys(sp) == (:branch, :experdef, :economy, :model, :scheme)
        @test sp.model == ["arm", "frm"] && sp.scheme == ["", "init-a"]
        sps = q("SELECT * FROM vault_stats('$root', '^([^_]+)(?:_(.+))?\$', ['model', 'scheme']) LIMIT 1")
        @test keys(sps) == (:branch, :experdef, :economy, :model, :scheme, :sample, :variable, :stat, :value)
    end

    # Windows separators in the root and the file path
    k = q(raw"""SELECT vault_path_keys('C:\out\', 'C:\out\feat\x\res-base-frm-1\stats\uncond.parquet') AS k""").k
    @test only(k) == (branch = "feat/x", experdef = "base", economy = "frm-1", file = "uncond")
end
