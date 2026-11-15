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
    irf = simulate_irf(obj, simseries; shocks = (pos = 2, uncond = Int64[]), T = 5, N = 20)
    mktempdir() do root
        cfg = Config(; output_root = root, table_format = PARQUET)
        cd(git_dir) do
            save_result(cfg, RunHandle("frm_init-a"; branch = "feat/nested", experdef = "base"),
                        (; obj, stats = samples, errstats, simseries, irf, params = collect_parameters(obj));
                        dirty_repo_check = :ignore)
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

        # parameters and impulse responses, long form
        pr = q("SELECT * FROM vault_params('$root')")
        @test keys(pr) == (:branch, :experdef, :economy, :parameter, :value) && pr.economy == fill("frm_init-a", length(pr.value))
        @test Dict(zip(pr.parameter, pr.value)) == Dict(string(k) => v for (k, v) in zip(row_names(collect_parameters(obj)), collect_parameters(obj).data))
        ir = q("SELECT * FROM vault_irf('$root')")
        @test keys(ir) == (:branch, :experdef, :economy, :shock, :stat, :period, :variable, :value)
        @test only(q("SELECT value FROM vault_irf('$root') WHERE shock = 'pos' AND stat = 'mean' AND period = 3 AND variable = 'K'").value) ==
              irf.means.pos.K[3]

        # glob filters open only the matching runs
        @test q("SELECT economy FROM vault_runs('$root', branch_glob := 'main')").economy == ["arm"]
        @test q("SELECT DISTINCT economy FROM vault_stats('$root', experdef_glob := 'base')").economy == ["frm_init-a"]
        @test_throws Exception q("SELECT * FROM vault_stats('$root', experdef_glob := 'nope')")   # no such files
        @test Set(q("SELECT DISTINCT economy FROM vault_stats('$root', 'feat/*', '*', '^([^_]+)', ['model'])").economy) == Set(["frm_init-a"])

        es = q("SELECT * FROM vault_errstats('$root') WHERE economy = 'frm_init-a'")
        @test keys(es) == (:branch, :experdef, :economy, :equation, :stat, :value)
        @test length(es.value) == length(errstats.data)

        sim = q("SELECT branch, economy, count(*) AS n FROM vault_simulation('$root') GROUP BY ALL")
        @test sim.branch == ["feat/nested"] && sim.economy == ["frm_init-a"]
        @test only(sim.n) == length(simseries.data)

        # economy split by a project regex: named columns after economy, '' where a group is empty
        sp = q("SELECT DISTINCT * FROM vault_runs('$root', '**', '*', '^([^_]+)(?:_(.+))?\$', ['model', 'scheme'])
                ORDER BY economy")
        @test keys(sp) == (:branch, :experdef, :economy, :model, :scheme)
        @test sp.model == ["arm", "frm"] && sp.scheme == ["", "init-a"]
        sps = q("SELECT * FROM vault_stats('$root', '**', '*', '^([^_]+)(?:_(.+))?\$', ['model', 'scheme']) LIMIT 1")
        @test keys(sps) == (:branch, :experdef, :economy, :model, :scheme, :sample, :variable, :stat, :value)
    end

    # moments read from the saved runs: the same table as from the results in memory
    mktempdir() do root
        cfg = Config(; output_root = root, table_format = PARQUET)
        cd(git_dir) do
            save_result(cfg, RunHandle("ngm"; branch = "main", experdef = "alt"),
                        (; obj, stats = samples, irf); dirty_repo_check = :ignore)
            save_result(cfg, RunHandle("ngm2"; branch = "main", experdef = "alt"),
                        (; obj, stats = samples, irf); dirty_repo_check = :ignore)
            save_result(cfg, RunHandle("noirf"; branch = "main", experdef = "alt"),
                        (; obj, stats = samples); dirty_repo_check = :ignore)
        end
        moments = (mean_K = SimulationMoment(:K), a_std_K = SimulationMoment(:K; sample = :a_all, stat = :std),
                   irf_K = ImpulseMoment(:K, :pos, 3; transformation = TransitionFunctionIteration.Transformations.DiffLevel()))
        table = assemble_moments(root, moments; experdef = "alt")
        @test Set(keys(table)) == Set((:branch, :experdef, :economy, :kind, :group, :variable, :stat, :period, :value))
        @test Set(table.kind) == Set(["simulation", "impulse"]) && Set(table.economy) == Set(["ngm", "ngm2", "noirf"])
        # (two simulation entries + shock and uncond points) in the two runs with IRFs, two simulation entries without
        @test length(table.value) == 2 * (2 + 2) + 2
        @test sum(table.economy .== "noirf") == 2 && all(table.kind[table.economy .== "noirf"] .== "simulation")
        @test Set(Tables.columntable(DBInterface.execute(con, "SELECT DISTINCT economy FROM vault_stats('$root', economies := ['ngm', 'noirf'])")).economy) ==
              Set(["ngm", "noirf"])
        @test length(assemble_moments(root, moments; economies = [:ngm]).value) == 4
        memory = EconomyResults(samples, irf)
        economies = (:ngm, :ngm2)
        via_root = compare_economies(moments, economies, root; experdef = "alt")
        @test via_root.data == compare_economies(moments, (ngm = memory, ngm2 = memory)).data
        @test via_root.data == compare_economies(moments, economies, table).data
        @test_throws KeyError compare_economies((x = SimulationMoment(:K; stat = :p99),), (:ngm,), root)
        # the same over RunHandles of the active configuration, reading the IRFs for impulse moments
        runs = (ngm = RunHandle("ngm"; branch = "main", experdef = "alt"), ngm2 = RunHandle("ngm2"; branch = "main", experdef = "alt"))
        via_handles = with_config(cfg) do
            compare_economies(moments, runs)
        end
        @test via_handles.data == compare_economies(moments, (ngm = memory, ngm2 = memory)).data
    end

    # Windows separators in the root and the file path
    k = q(raw"""SELECT vault_path_keys('C:\out\', 'C:\out\feat\x\res-base-frm-1\stats\uncond.parquet') AS k""").k
    @test only(k) == (branch = "feat/x", experdef = "base", economy = "frm-1", file = "uncond")
end
