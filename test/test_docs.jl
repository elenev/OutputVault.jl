# The walkthrough pages run as written in fresh Julia processes: each named group of @example blocks of
# a page is one script, run in its own process, in order, in the
# throwaway repository that the docs build also uses (docs/walkthroughs.jl). This checks what the docs
# build cannot: the build loads every package first, so a script that forgets a `using` would still
# build. An @repl block must throw, as the page says.

include(joinpath(pkgdir(OutputVault), "docs", "walkthroughs.jl"))

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

@testset "Documentation walkthroughs" begin
    for page in WALKTHROUGH_PAGES
        @testset "$page" begin
            groups = doc_groups(walkthrough_path(page))
            @test !isempty(groups)
            repo = walkthrough_repo()
            try
                for (name, blocks) in groups
                    script = joinpath(repo, "$name.jl")    # in the repository: `include` is relative to the script
                    write(script, walkthrough_script(blocks))
                    cmd = walkthrough_cmd(script, repo, Base.active_project())
                    out = IOBuffer()
                    ok = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out)).exitcode == 0
                    log = String(take!(out))
                    passed = ok && occursin("WALKTHROUGH DONE", log)
                    passed || println("── $page, $name ──\n", log)
                    @test passed
                end
            finally
                GC.gc(); GC.gc()
                rm(dirname(repo); recursive = true, force = true)
            end
        end
    end
end
