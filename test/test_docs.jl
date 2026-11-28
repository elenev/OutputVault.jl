# The documentation's examples run in fresh Julia processes, in an environment that holds only the
# packages the documentation tells users to install: the ```julia blocks of the README and the home
# page, and each named group of @example blocks of a walkthrough page, one script per group, in the
# throwaway repository that the docs build also uses (docs/walkthroughs.jl). This checks what the
# docs build cannot: the build loads every package first, so a script that forgets a `using` would
# still build. An @repl block must throw, as the page says.

using TOML

include(joinpath(pkgdir(OutputVault), "docs", "walkthroughs.jl"))

const USER_PACKAGES = ("OutputVault", "Parquet2")

# an environment in `dir` whose only direct dependencies are USER_PACKAGES, at the versions of the
# active one: a Project.toml that names them next to a copy of the active manifest, with the
# manifest's relative paths made absolute
function user_environment(dir)
    active = Base.active_project()
    manifest = TOML.parsefile(Base.project_file_manifest_path(active))
    for entries in values(manifest["deps"]), entry in entries
        if haskey(entry, "path")
            entry["path"] = abspath(dirname(active), entry["path"])
        end
    end
    deps = Dict(p => string(Base.identify_package(p).uuid) for p in USER_PACKAGES)
    open(io -> TOML.print(io, Dict("deps" => deps)), joinpath(dir, "Project.toml"), "w")
    open(io -> TOML.print(io, manifest), joinpath(dir, "Manifest.toml"), "w")
    return joinpath(dir, "Project.toml")
end

# the ```julia blocks of a page that run: all but the installation commands
function example_blocks(path)
    lines = readlines(path)
    blocks = String[]
    for i in findall(==("```julia"), lines)
        j = findnext(==("```"), lines, i + 1)
        push!(blocks, join(lines[i + 1:j - 1], "\n"))
    end
    return filter(b -> !occursin("Pkg.", b), blocks)
end

# the script of a group: its blocks, a @repl block wrapped to require an error
function walkthrough_script(blocks)
    parts = map(blocks) do (kind, code)
        kind === :example && return code
        """
        let err = try
                $(code)
                nothing
            catch e
                e
            end
            isnothing(err) && error("the @repl block was expected to throw")
            println("REPL BLOCK THREW: ", sprint(showerror, err))
        end"""
    end
    return join(parts, "\n\n") * "\n\nprintln(\"WALKTHROUGH DONE\")\n"
end

# whether the script of `blocks` runs to its end in a fresh process in `repo`, with the environment
# `env`; its output is printed if not
function runs_to_end(blocks, repo, env, name)
    script = joinpath(repo, "$name.jl")    # in the repository: `include` is relative to the script
    write(script, walkthrough_script(blocks))
    cmd = walkthrough_cmd(script, repo, env)
    out = IOBuffer()
    ok = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out)).exitcode == 0
    log = String(take!(out))
    passed = ok && occursin("WALKTHROUGH DONE", log)
    passed || println("── $name ──\n", log)
    return passed
end

# f(repo) in a fresh walkthrough repository, removed afterwards
function with_walkthrough_repo(f)
    repo = walkthrough_repo()
    try
        f(repo)
    finally
        GC.gc(); GC.gc()
        rm(dirname(repo); recursive = true, force = true)
    end
end

@testset "Documentation examples" begin
    env = user_environment(mktempdir())

    @testset "environment" begin
        check = """
        using OutputVault, Parquet2
        @assert isnothing(Base.identify_package("Tables"))
        @assert isnothing(Base.identify_package("DataAPI"))
        """
        with_walkthrough_repo() do repo
            @test runs_to_end([(:example, check)], repo, env, "environment")
        end
    end

    @testset "$page" for page in ("README.md", joinpath("docs", "src", "index.md"))
        blocks = example_blocks(joinpath(pkgdir(OutputVault), page))
        @test !isempty(blocks)
        with_walkthrough_repo() do repo
            @test runs_to_end([(:example, b) for b in blocks], repo, env, "example")
        end
    end

    @testset "$page" for page in WALKTHROUGH_PAGES
        groups = doc_groups(walkthrough_path(page))
        @test !isempty(groups)
        with_walkthrough_repo() do repo
            for (name, blocks) in groups
                @test runs_to_end(blocks, repo, env, name)
            end
        end
    end
end
