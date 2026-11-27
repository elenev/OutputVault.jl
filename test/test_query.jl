using DuckDB
const DBI = DuckDB.DBInterface

# rows of a column table as tuples, for comparisons
rowset(t) = collect(zip(values(t)...))

@testset "queries" begin
    base = RunHandle("base"; branch = "main", experdef = "v1")
    alt = RunHandle("alt"; branch = "main", experdef = "v1")
    other = RunHandle("base"; branch = "main", experdef = "v2")
    nested = RunHandle("base"; branch = "feature/x", experdef = "v1")
    with_vault() do root, repo
        for rf in (base, alt, other, nested)
            save_solution(rf, (; x = 1))
        end
        save_result_item(base, "stats", (uncond = (variable = [:c, :k], mean = [0.71, 2.9], std = [0.02, 0.11]),
                                          boom = (variable = [:c, :k], mean = [0.8, 3.0], std = [0.03, NaN])))
        # alt: no std, an extra statistic and a missing cell
        save_result_item(alt, "stats/uncond", (variable = [:c, :k], mean = [0.5, missing], skew = [1.0, 2.0]))
        save_result_item(other, "stats/uncond", (variable = [:c], mean = [9.0], std = [9.0], note = ["text"]))
        save_result_item(nested, "stats/uncond", (variable = [:c], mean = [7.0], std = [7.0]))
        save_result_item(base, "irf/ss/stats", (shock = [:tfp, :tfp, :g], period = [1, 2, 1], y = [1.0, 2.0, 3.0], c = [4.0, 5.0, 6.0]))
        save_result_item(base, "params/params", (parameter = [:beta, :sigma], value = [0.99, 2.0]))
        save_result_item(base, "stats/broken", Plain(1, Float64[]))   # a .jld2 file is not queryable

        stats = QueryShape("stats/{sample}"; keys = (:variable,), column = :stat)

        @testset "long form" begin
            t = query_results([base], stats; sample = :uncond)
            @test keys(t) == (:branch, :experdef, :variant, :sample, :variable, :stat, :value)
            @test rowset(t) == [("main", "v1", "base", "uncond", "c", "mean", 0.71), ("main", "v1", "base", "uncond", "c", "std", 0.02),
                                ("main", "v1", "base", "uncond", "k", "mean", 2.9), ("main", "v1", "base", "uncond", "k", "std", 0.11)]
            @test eltype(t.variable) == String && eltype(t.value) == Float64
        end

        @testset "selections" begin
            t = query_results(RunPattern(; experdef = "v1"), stats; sample = [:uncond, :boom], variable = :k, stat = :mean)
            @test rowset(t) == [("main", "v1", "base", "boom", "k", "mean", 3.0), ("main", "v1", "base", "uncond", "k", "mean", 2.9)]
            t = query_results(RunPattern(; experdef = "v1"), stats; sample = "b*", stat = "s*")
            @test t.sample == ["boom", "boom"] && t.stat == ["std", "std"] && isequal(t.value, [0.03, NaN])
            t = query_results([base], stats; sample = :uncond, variable = ["k", "c*"], stat = :mean)   # a glob and a value on a key
            @test t.variable == ["c", "k"] && t.value == [0.71, 2.9]
            t = query_results(RunPattern(), stats; sample = :uncond, stat = :mean)       # the missing cell gives no row
            @test rowset(t) == [("main", "v1", "alt", "uncond", "c", "mean", 0.5), ("main", "v1", "base", "uncond", "c", "mean", 0.71),
                                ("main", "v1", "base", "uncond", "k", "mean", 2.9), ("main", "v2", "base", "uncond", "c", "mean", 9.0)]
            t = query_results(RunPattern(; branch = "**", variant = "base"), stats; sample = :uncond, variable = "c", stat = :mean)
            @test t.branch == ["feature/x", "main", "main"] && t.value == [7.0, 0.71, 9.0]
            @test isempty(query_results([base], stats; sample = :absent).value)
            @test keys(query_results([base], stats; sample = :absent)) == keys(t)
            @test isempty(query_results(RunPattern(; experdef = "none"), stats).value)
            @test isempty(query_results([base], stats; stat = :absent).value)
            @test isempty(query_results([RunHandle("unsaved"; branch = "main", experdef = "v1")], stats).value)   # no run folder
            @test_throws ArgumentError with_config(() -> query_results([base], stats), Config(; output_root = root))  # no table format
            err = try query_results([base], stats; shock = :tfp); nothing catch e; e end
            @test err isa ArgumentError && occursin("sample, variable, stat", err.msg)
        end

        @testset "casting" begin
            err = try query_results([other], stats); nothing catch e; e end
            @test err isa ArgumentError && occursin("column note", err.msg)
            @test query_results([other], stats; stat = [:mean, :std]).value == [9.0, 9.0]
            t = query_results([other], QueryShape("stats/{sample}"; keys = (:variable,), column = :stat, valuetype = String); stat = :note)
            @test t.value == ["text"]
            save_result_item(base, "counts", (name = [:a, :b], n = [1, 2], flag = [true, false]))
            counts(T) = QueryShape("counts"; keys = (:name,), column = :col, valuetype = T)
            for T in (Int64, Int32, Float32)
                v = query_results([base], counts(T); col = :n).value
                @test eltype(v) == T && v == [1, 2]
            end
            @test query_results([base], counts(Bool); col = :flag).value == [true, false]
        end

        @testset "numeric keys and nested placeholders" begin
            irf = QueryShape("irf/{start}/stats"; keys = (:shock, :period), column = :variable)
            t = query_results([base, alt], irf; start = :ss, shock = :tfp, variable = [:y, :c])
            @test keys(t) == (:branch, :experdef, :variant, :start, :shock, :period, :variable, :value)
            @test rowset(t) == [("main", "v1", "base", "ss", "tfp", 1, "y", 1.0), ("main", "v1", "base", "ss", "tfp", 1, "c", 4.0),
                                ("main", "v1", "base", "ss", "tfp", 2, "y", 2.0), ("main", "v1", "base", "ss", "tfp", 2, "c", 5.0)]
            @test eltype(t.period) == Int64
            @test query_results([base], irf; period = 2, variable = :c).value == [5.0]
            params = QueryShape("params/params"; keys = (:parameter,), column = :stat)
            @test rowset(query_results([base], params)) == [("main", "v1", "base", "beta", "value", 0.99), ("main", "v1", "base", "sigma", "value", 2.0)]
        end

        @testset "shapes" begin
            @test_throws ArgumentError QueryShape("stats/{sample}"; keys = (:sample,))
            @test_throws ArgumentError QueryShape("stats/{variant}")
            @test_throws ArgumentError QueryShape("stats/a.b")
            @test_throws ArgumentError QueryShape("stats"; valuetype = Complex{Float64})
            @test_throws ArgumentError query_results([base], QueryShape("stats/{sample}"; keys = (:absent,)); sample = :uncond)
        end

        @testset "SQL macros" begin
            con = vault_connection()
            try
                q(sql) = Tables.columntable(DBI.execute(con, sql))
                f = joinpath(OutputVault.run_path(root, base), "stats", "uncond.parquet")
                t = q("SELECT variable, mean, __row FROM vault_table_parquet(['$f'])")
                @test rowset(t) == [("c", 0.71, 0), ("k", 2.9, 1)]
                @test isempty(q("SELECT * FROM vault_metadata_parquet(['$f'])").key)
                s = q("SELECT UNNEST(vault_split_variant('capbail85', '^([a-z]+)(\\d*)\$', ['scheme', 'level']))")
                @test (s.scheme[1], s.level[1]) == ("capbail", "85")
            finally
                DBI.close!(con)
            end
        end
    end
end
