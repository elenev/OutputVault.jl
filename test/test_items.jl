struct Plain
    a::Int
    b::Vector{Float64}
end
Base.:(==)(x::Plain, y::Plain) = x.a == y.a && x.b == y.b

files_under(dir) = sort([relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs])

@testset "items" begin
    rf = RunHandle("base"; branch = "main", experdef = "v1")

    @testset "storage rules" begin
        with_vault() do root, repo
            @test_throws ArgumentError save_result_item(rf, "stats", (a = [1],))    # no run yet
            dir = save_solution(rf, (; obj = Plain(1, [2.0]), params = (p = [:a, :b], value = [1.0, 2.0])))
            @test dir == OutputVault.run_path(root, rf)
            @test files_under(dir) == [joinpath(".provenance", "git_commit.txt"), "native.jld2",
                                       joinpath("solution", "obj.jld2"), joinpath("solution", "params.parquet")]
            @test !isdir(joinpath(root, ".staging")) || isempty(readdir(joinpath(root, ".staging")))

            save_result_item(rf, "stats", (uncond = (variable = [:c, :k], mean = [0.7, 2.9]), note = "text", n = 3))
            save_result_item(rf, "irf/ss", (stats = (shock = [:tfp], value = [1.0]), extra = (; deep = Plain(2, Float64[]))))
            save_result_item(rf, "plain", Plain(3, [1.0, 2.0]))
            save_result_item(rf, "greek", (α = 0.33, β = [1.0, 2.0]))     # a folder with non-ASCII names
            @test isfile(joinpath(dir, "stats", "uncond.parquet")) && isfile(joinpath(dir, "stats", "note.jld2"))
            @test isfile(joinpath(dir, "irf", "ss", "stats.parquet")) && isfile(joinpath(dir, "irf", "ss", "extra", "deep.jld2"))
            @test isfile(joinpath(dir, "plain.jld2"))
            @test !any(f -> occursin(".tmp", f), files_under(dir))

            # reading: data only
            stats = load_result_item(rf, "stats")
            @test keys(stats) == (:n, :note, :uncond)                     # alphabetical
            @test stats.uncond isa Formats.StoredTable
            @test Tables.columns(stats.uncond).variable == [:c, :k] && Tables.columns(stats.uncond).mean == [0.7, 2.9]
            @test stats.note == Dict("value" => "text")
            @test Tables.columns(load_result_item(rf, "stats/uncond")).mean == [0.7, 2.9]
            @test load_result_item(rf, "plain")["value"] == Plain(3, [1.0, 2.0])
            @test load_result_item(rf, "plain", Plain) == Plain(3, [1.0, 2.0])   # read_jld2's default
            @test load_result_item(rf, "greek").α["value"] == 0.33
            move_result_item(rf, "greek/α", "greek/γ")
            @test keys(load_result_item(rf, "greek")) == (:β, :γ)
            @test "greek/γ" in list_run(rf).items.path
            @test load_result_item(rf, "irf").ss.extra.deep["value"] == Plain(2, Float64[])
            sol = load_result_item(rf, "solution")
            @test keys(sol) == (:obj, :params) && Tables.columns(sol.params).p == [:a, :b]
            @test load_result_item(rf, "solution"; native = true) == (obj = Plain(1, [2.0]), params = (p = [:a, :b], value = [1.0, 2.0]))
            @test_throws ArgumentError load_result_item(rf, "stats"; native = true)
            @test_throws MethodError load_result_item(rf, "stats", Plain)     # no from_storage method
            @test_throws ArgumentError load_result_item(rf, "absent")
            @test_throws ArgumentError load_result_item(rf, ".provenance")
            @test_throws ArgumentError load_result_item(rf, "native")
        end
    end

    @testset "paths and conflicts" begin
        with_vault() do root, repo
            dir = save_solution(rf, (; x = 1))
            for bad in ("", "a//b", "a.b", "a\\b", "/a", "a/")
                @test_throws ArgumentError save_result_item(rf, bad, 1)
            end
            for reserved in ("solution", "solution/x", ".provenance", "native")
                @test_throws ArgumentError save_result_item(rf, reserved, 1)
            end
            @test_throws ArgumentError save_result_item(rf, "t", (a = [1, 2], b = [1.0]))   # unequal lengths
            save_result_item(rf, "irf", Plain(1, Float64[]))
            err = try save_result_item(rf, "irf/tfp", 1); nothing catch e; e end
            @test err isa ArgumentError && occursin("is a file", err.msg)

            # replacing: every form at the path goes, a folder with everything in it
            save_result_item(rf, "irf", (a = 1, b = 2))
            @test !isfile(joinpath(dir, "irf.jld2")) && isdir(joinpath(dir, "irf"))
            save_result_item(rf, "irf/c", 3)
            @test keys(load_result_item(rf, "irf")) == (:a, :b, :c)
            save_result_item(rf, "irf", (; d = 4))
            @test keys(load_result_item(rf, "irf")) == (:d,)
            save_result_item(rf, "irf", (d = [1.0],))
            @test isfile(joinpath(dir, "irf.parquet")) && !isdir(joinpath(dir, "irf"))
            save_result_item(rf, "empty", (;))
            @test load_result_item(rf, "empty") == (;)
        end
    end

    @testset "no table format" begin
        with_vault(; table_format = nothing) do root, repo
            save_solution(rf, (; x = 1))
            err = try save_result_item(rf, "t", (a = [1],)); nothing catch e; e end
            @test err isa ArgumentError && occursin("no table format", err.msg)
            @test !any(f -> occursin(".tmp", f), files_under(OutputVault.run_path(root, rf)))
            @test_throws ArgumentError save_solution(rf, (; t = (a = [1],)))
            @test load_result_item(rf, "solution/x")["value"] == 1          # the failed save changed nothing
        end
    end

    @testset "saving the solution starts the run over" begin
        with_vault(; native = false) do root, repo
            dir = save_solution(rf, (; x = 1))
            save_result_item(rf, "stats", 2)
            @test save_solution(rf, (; y = 2)) == dir
            @test files_under(dir) == [joinpath(".provenance", "git_commit.txt"), joinpath("solution", "y.jld2")]
            @test_throws ArgumentError load_result_item(rf, "solution"; native = true)
            @test filter(!startswith("."), readdir(joinpath(root, "main"))) == ["res-v1-base"]
            @test !any(startswith(".trash"), readdir(joinpath(root, "main")))
            save_solution(rf, Plain(1, [1.0]))                             # a solution that is not a NamedTuple
            @test load_result_item(rf, "solution", Plain) == Plain(1, [1.0])
        end
    end

    @testset "move and delete" begin
        with_vault() do root, repo
            dir = save_solution(rf, (; x = 1))
            save_result_item(rf, "irf/irf", (shock = [:tfp], value = [1.0]))
            save_result_item(rf, "irf/irf_paths", (shock = [:tfp], value = [2.0]))
            move_result_item(rf, "irf/irf", "irf/ss/stats")
            move_result_item(rf, "irf/irf_paths", "irf/ss/paths")
            @test isfile(joinpath(dir, "irf", "ss", "stats.parquet")) && isfile(joinpath(dir, "irf", "ss", "paths.parquet"))
            @test_throws ArgumentError move_result_item(rf, "irf/absent", "irf/y")
            save_result_item(rf, "z", 1)
            @test_throws ArgumentError move_result_item(rf, "z", "irf/ss/stats")
            @test_throws ArgumentError move_result_item(rf, "z", "solution/z")
            @test_throws ArgumentError move_result_item(rf, "solution", "s")
            move_result_item(rf, "irf/ss", "irfs")
            @test keys(load_result_item(rf, "irfs")) == (:paths, :stats)

            delete_result_item(rf, "irfs/paths")
            @test keys(load_result_item(rf, "irfs")) == (:stats,)
            delete_result_item(rf, "irfs")
            @test !isdir(joinpath(dir, "irfs"))
            @test_throws ArgumentError delete_result_item(rf, "irfs")
            @test_throws ArgumentError delete_result_item(rf, "solution")
            @test_throws ArgumentError delete_result_item(rf, ".provenance")
        end
    end

    @testset "list_run" begin
        with_vault() do root, repo
            save_solution(rf, (; obj = Plain(1, [1.0])))
            save_result_item(rf, "stats", (uncond = (v = [1.0],),))
            c = list_run(rf)
            @test c.run == rf
            @test c.items.path == ["solution", "solution/obj", "stats", "stats/uncond"]
            @test c.items.kind == [:folder, :jld2, :folder, :table]
            @test c.items.format == ["", "jld2", "", "parquet"]
            @test Tables.istable(c.items)
            s = sprint(show, MIME"text/plain"(), c)
            @test occursin("main/res-v1-base", s) && occursin("stats/uncond.parquet", s) && occursin("commit: ", s)
        end
    end

    @testset "runs saved with OutputVault 0.3" begin
        with_vault() do root, repo
            # the 0.3 layout: provenance and the native copy res.jld2 inside solution/
            dir = mkpath(joinpath(root, "main", "res-v1-base", "solution"))
            jldsave(joinpath(dir, "res.jld2"); obj = Plain(1, [1.0]), stv = Plain(2, [2.0]))
            jldsave(joinpath(dir, "obj.jld2"); value = Plain(1, [1.0]))
            write(joinpath(dir, "git_commit.txt"), "0123456789abcdef0123456789abcdef01234567\n")
            write(joinpath(dir, "git_unstaged.diff"), "diff")
            @test load_result_item(rf, "solution"; native = true) == (obj = Plain(1, [1.0]), stv = Plain(2, [2.0]))
            @test keys(load_result_item(rf, "solution")) == (:obj,)       # res.jld2 and the text files skipped
            p = list_run(rf).provenance
            @test p.commit == "0123456789abcdef0123456789abcdef01234567" && p.dirty
        end
    end

    @testset "object files" begin
        with_tempdir() do dir
            path = joinpath(dir, "obj.jld2")
            @test write_object_file(path, Plain(1, [3.0])) == path
            @test read_object_file(path, Plain) == Plain(1, [3.0])
            @test readdir(dir) == ["obj.jld2"]
        end
    end
end
