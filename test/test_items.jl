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
            @test load_result_item(rf, "plain", Plain) == Plain(3, [1.0, 2.0])   # read_portable_jld2's default
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
        with_vault() do root, repo                                         # its native copy has one key
            save_solution(rf, Plain(1, [1.0]))
            @test load_result_item(rf, "solution"; native = true) == (; solution = Plain(1, [1.0]))
        end
    end

    @testset "an item in several forms" begin
        with_vault() do root, repo
            dir = save_solution(rf, (; x = 1))
            save_result_item(rf, "stats/uncond", (a = [1.0],))
            jldsave(joinpath(dir, "stats", "uncond.jld2"); value = 1)          # written outside OutputVault
            err = try load_result_item(rf, "stats/uncond"); nothing catch e; e end
            @test err isa ArgumentError && occursin("several forms", err.msg) && occursin("uncond.jld2", err.msg)
            err = try load_result_item(rf, "stats"); nothing catch e; e end
            @test err isa ArgumentError && occursin("item uncond in several forms", err.msg)
        end
    end

    # Windows keeps a Parquet file open after it is read, which blocks its deletion, and an open
    # handle blocks renaming its folder. On every platform the item must stay whole.
    @testset "saving over an item" begin
        with_vault() do root, repo
            dir = save_solution(rf, (; x = 1))
            column(t) = only(Tables.columns(t).a)
            values_of(item) = map(column, load_result_item(rf, item))
            stats(u, c) = (uncond = (a = [u],), crisis = (a = [c],))
            leftovers() = filter(f -> contains(f, ".old-") || contains(f, ".tmp-"), readdir(dir))

            # a folder item with a member read earlier
            save_result_item(rf, "stats", stats(1.0, 2.0))
            read_before = load_result_item(rf, "stats/uncond")
            save_result_item(rf, "stats", (uncond = (a = [3.0],), boom = (a = [4.0],)))
            @test values_of("stats") == (boom = 4.0, uncond = 3.0)
            @test column(read_before) == 1.0

            # a file item read earlier
            save_result_item(rf, "table", (a = [1.0],))
            read_before = load_result_item(rf, "table")
            save_result_item(rf, "table", (a = [2.0],))
            @test column(load_result_item(rf, "table")) == 2.0
            @test column(read_before) == 1.0
            @test filter(!startswith("solution"), list_run(rf).items.path) == ["stats", "stats/boom", "stats/uncond", "table"]

            # an open handle in the old item: the save fails on Windows and leaves the old item
            save_result_item(rf, "held", stats(1.0, 2.0))
            io = open(joinpath(dir, "held", "crisis.parquet"))
            if Sys.iswindows()
                @test_throws Base.IOError save_result_item(rf, "held", stats(5.0, 6.0))
                @test values_of("held") == (crisis = 2.0, uncond = 1.0)
            else
                save_result_item(rf, "held", stats(5.0, 6.0))
                @test values_of("held") == (crisis = 6.0, uncond = 5.0)
            end
            close(io)
            save_result_item(rf, "held", stats(7.0, 8.0))
            @test values_of("held") == (crisis = 8.0, uncond = 7.0)

            # the new item cannot be moved into place: the old one is moved back
            stem = joinpath(dir, "held")
            @test_throws Base.IOError OutputVault.replace_item(joinpath(dir, ".none"), stem, stem)
            @test values_of("held") == (crisis = 8.0, uncond = 7.0)
            @test_logs (:warn, r"could not be moved back") OutputVault.restore_forms([joinpath(dir, ".none")], [stem])

            # another form replaces the old one
            save_result_item(rf, "z", 1)
            save_result_item(rf, "z", (a = [1.0],))
            @test isfile(joinpath(dir, "z.parquet")) && !ispath(joinpath(dir, "z.jld2"))

            # only Windows may leave old copies, and they are hidden
            if !Sys.iswindows()
                @test isempty(leftovers())
            end
            @test !any(contains(".old-"), list_run(rf).items.path)

            # an old copy that cannot be deleted only warns (here a read-only folder)
            if !Sys.iswindows()
                save_result_item(rf, "locked", stats(1.0, 2.0))
                chmod(joinpath(dir, "locked"), 0o500)
                @test_logs (:warn, r"old copy could not be deleted") save_result_item(rf, "locked", stats(3.0, 4.0))
                @test values_of("locked") == (crisis = 4.0, uncond = 3.0)
                chmod(joinpath(dir, only(leftovers())), 0o700)
            end
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

            GC.gc(); GC.gc()      # Windows keeps the Parquet files just read open until collection
            delete_result_item(rf, "irfs/paths")
            @test keys(load_result_item(rf, "irfs")) == (:stats,)
            GC.gc(); GC.gc()
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
