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
    with_tempdir() do root
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
        # every macro with the economy split: the split columns after economy, then the macro's own columns
        split_args = "'**', '*', '^([^_]+)(?:_(.+))?\$', ['model', 'scheme']"
        own = (vault_stats = (:sample, :variable, :stat, :value), vault_errstats = (:equation, :stat, :value),
               vault_params = (:parameter, :value), vault_irf = (:shock, :stat, :period, :variable, :value),
               vault_runs = ())
        for (macro_, cols) in pairs(own)
            plain = q("SELECT * FROM $macro_('$root')")
            split = q("SELECT * FROM $macro_('$root', $split_args)")
            @test keys(split) == (:branch, :experdef, :economy, :model, :scheme, cols...)
            @test keys(plain) == (:branch, :experdef, :economy, cols...)
            @test length(split.economy) == length(plain.economy)
            @test Set(zip(split.economy, split.model)) ⊆ Set([("arm", "arm"), ("frm_init-a", "frm")])
        end
        sims = q("SELECT * FROM vault_simulation('$root', $split_args)")
        @test keys(sims)[1:5] == (:branch, :experdef, :economy, :model, :scheme) && length(sims.economy) == length(simseries.data)
        # the named-argument forms, one at a time
        @test only(unique(q("SELECT economy FROM vault_errstats('$root', economies := ['arm'])").economy)) == "arm"
        @test only(unique(q("SELECT economy FROM vault_irf('$root', branch_glob := 'feat/*')").economy)) == "frm_init-a"
        @test only(unique(q("SELECT economy FROM vault_params('$root', experdef_glob := 'base')").economy)) == "frm_init-a"
        @test only(unique(q("SELECT economy FROM vault_simulation('$root', economies := ['frm*'])").economy)) == "frm_init-a"
        @test q("SELECT economy FROM vault_runs('$root', branch_glob := 'feat/*', experdef_glob := 'base')").economy == ["frm_init-a"]
    end

    # moments read from the saved runs: the same table as from the results in memory
    with_tempdir() do root
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
        memory = EconomyResult(; stats = samples, irf)
        # runs are named by the full key unless a shorter one is asked for
        @test Set(keys(split_by_economy(table))) == Set((:main__alt__ngm, :main__alt__ngm2, :main__alt__noirf))
        economies = split_by_economy(table; key = :economy, order = [:ngm, :ngm2])
        @test keys(economies) == (:ngm, :ngm2) && all(e -> e isa Dict, values(economies))
        @test keys(split_by_economy(table; key = :economy, order = [:ngm2, :ngm])) == (:ngm2, :ngm)   # in that order
        @test_throws ArgumentError split_by_economy(table; key = :economy, order = [:ngm, :nope])     # not in the table
        # the same economy name in two branches: the full key keeps them apart, :economy is an error
        other = merge(table, (; branch = fill("dev", length(table.value))))
        both = NamedTuple{keys(table)}(Tuple(vcat(table[k], other[k]) for k in keys(table)))
        @test length(split_by_economy(both)) == 6
        @test_throws ArgumentError split_by_economy(both; key = :economy)
        @test keys(split_by_economy(both; key = (:branch, :economy), order = [:dev__ngm, :main__ngm])) == (:dev__ngm, :main__ngm)
        # disjoint rows of two runs with the same economy name are not merged either
        part(b, rows) = NamedTuple{keys(table)}(Tuple(k === :branch ? fill(b, length(rows)) : table[k][rows] for k in keys(table)))
        ngm_rows = findall(==("ngm"), table.economy)
        disjoint = let a = part("main", ngm_rows[1:1]), b = part("dev", ngm_rows[2:2])
            NamedTuple{keys(table)}(Tuple(vcat(a[k], b[k]) for k in keys(table)))
        end
        @test_throws ArgumentError split_by_economy(disjoint; key = :economy)
        @test getmoment(economies.ngm, moments.irf_K) == getmoment(memory, moments.irf_K)
        @test_throws ArgumentError split_by_economy(merge(table, (; economy = fill("ngm", length(table.value)))))   # duplicate rows in one run
        via_root = compare_economies(moments, (:ngm, :ngm2), root; experdef = "alt")
        @test via_root.data == compare_economies(moments, (ngm = memory, ngm2 = memory)).data
        @test via_root.data == compare_economies(moments, economies).data
        @test_throws KeyError compare_economies((x = SimulationMoment(:K; stat = :p99),), (:ngm,), root)
        @test_throws KeyError getmoment(economies.ngm, SimulationMoment(:K; stat = :p99))
        # a calculated moment, with named moments, reads from the table as from memory
        calc = @CalculatedMoment moments mean_K / a_std_K + irf_K
        @test getmoment(economies.ngm, calc) == getmoment(memory, calc)
        # rows of a moment
        @test OutputVault.momentrows(moments.irf_K) == ((kind = :impulse, group = :pos, variable = :K, stat = :mean, period = 3),
                                                        (kind = :impulse, group = :uncond, variable = :K, stat = :mean, period = 3))
        @test length(OutputVault.momentrows(calc)) == 4       # mean_K, a_std_K, and irf_K's two rows, none repeated
        # the same over RunHandles of the active configuration, reading the IRFs for impulse moments
        runs = (ngm = RunHandle("ngm"; branch = "main", experdef = "alt"), ngm2 = RunHandle("ngm2"; branch = "main", experdef = "alt"))
        via_handles = with_config(cfg) do
            compare_economies(moments, runs)
        end
        @test via_handles.data == compare_economies(moments, (ngm = memory, ngm2 = memory)).data
        # the root form names runs by economy: the same name in another branch is an error until narrowed
        cd(git_dir) do
            save_result(cfg, RunHandle("ngm"; branch = "dev", experdef = "alt"), (; obj, stats = samples, irf); dirty_repo_check = :ignore)
        end
        @test_throws ArgumentError compare_economies(moments, (:ngm, :ngm2), root; experdef = "alt")
        @test compare_economies(moments, (:ngm, :ngm2), root; branch = "main", experdef = "alt").data == via_root.data
        # the base economy is the first one named
        @test compare_economies(moments, (:ngm2, :ngm), root; branch = "main", experdef = "alt").data == via_root.data
    end

    # parameters from saved runs
    with_tempdir() do root
        cfg = Config(; output_root = root, table_format = PARQUET)
        cd(git_dir) do
            save_result(cfg, RunHandle("pars"; branch = "main", experdef = "alt"),
                        (; obj, stats = samples, params = collect_parameters(obj)); dirty_repo_check = :ignore)
            save_result(cfg, RunHandle("nopars"; branch = "main", experdef = "alt"),
                        (; obj, stats = samples); dirty_repo_check = :ignore)
        end
        pars = collect_parameters(obj)
        name = first(row_names(pars))
        value = getmoment(pars, name, :value)
        K_moments = (mean_K = SimulationMoment(:K),)
        nrow(table) = length(table.value)
        all_pars = assemble_moments(root, K_moments)
        @test Set(all_pars.kind) == Set(["simulation", "parameter"]) && Set(all_pars.economy) == Set(["pars", "nopars"])
        @test count(==("parameter"), all_pars.kind) == length(row_names(pars))                 # the economy without params has none
        @test all(==("pars"), all_pars.economy[all_pars.kind .== "parameter"])
        @test nrow(assemble_moments(root, K_moments; parameters = false)) == 2
        named = assemble_moments(root, K_moments; parameters = [name])
        @test count(==("parameter"), named.kind) == 1 && only(named.variable[named.kind .== "parameter"]) == String(name)
        # a ParameterMoment is fetched even with parameters = false
        pm = ParameterMoment(name)
        required = assemble_moments(root, (; pm); parameters = false)
        @test count(==("parameter"), required.kind) == 1
        economies = split_by_economy(all_pars; key = :economy)
        @test getmoment(economies.pars, pm) == value
        @test getmoment(economies.pars, ParameterMoment(name; transformation = TransitionFunctionIteration.Transformations.Pct())) == 100value
        @test_throws KeyError getmoment(economies.nopars, pm)
        @test_throws KeyError getmoment(economies.pars, ParameterMoment(:not_a_parameter))
        # and a calculated moment of a statistic and a parameter
        named = (pm = pm, mean_K = SimulationMoment(:K))
        calc = @CalculatedMoment named pm * mean_K
        memory = EconomyResult(; stats = samples, params = pars)
        @test getmoment(economies.pars, calc) == getmoment(memory, calc)
        # over RunHandles, the parameters are loaded when a moment needs them
        runs = (pars = RunHandle("pars"; branch = "main", experdef = "alt"),)
        via_handles = with_config(cfg) do
            compare_economies((calc = calc,), runs)
        end
        @test via_handles(:calc, :pars) == getmoment(memory, calc)
    end

    # Windows separators in the root and the file path
    k = q(raw"""SELECT vault_path_keys('C:\out\', 'C:\out\feat\x\res-base-frm-1\stats\uncond.parquet') AS k""").k
    @test only(k) == (branch = "feat/x", experdef = "base", economy = "frm-1", file = "uncond")
end
