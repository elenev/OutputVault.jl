# The walkthroughs of the documentation as written: the code blocks of the guide pages below run in
# fresh Julia processes, in a temporary output root (replacing "/path/to/outputs") and a throwaway git
# repository. A block preceded by `<!-- doctest: SPEC -->` runs as SPEC says:
#   file NAME         written to NAME in the working folder
#   process N         appended to script N; scripts run in order, each in its own process
#   process N, throws E   part of script N, must throw E; a plain ``` block right after it is the
#                     error message shown on the page and must match
# Blocks without a spec are not run.

const DOC_PAGES = ("quickstart.md", "lifecycle.md")
const DOC_ROOT_PLACEHOLDER = "\"/path/to/outputs\""

# the specified blocks of a page: (spec, code, shown), `shown` the message block after a throws block
function doc_blocks(path)
    lines = readlines(path)
    blocks = NamedTuple{(:spec, :code, :shown), Tuple{String, String, Union{Nothing, String}}}[]
    for (i, l) in enumerate(lines)
        m = match(r"^<!-- doctest: (.*) -->$", l)
        isnothing(m) && continue
        lines[i + 1] == "```julia" || error("$path:$i: a doctest spec must precede a ```julia block")
        j = findnext(==("```"), lines, i + 2)
        shown = nothing
        k = j + 1
        while k <= length(lines) && isempty(strip(lines[k])); k += 1; end
        if k <= length(lines) && lines[k] == "```"
            e = findnext(==("```"), lines, k + 1)
            shown = join(lines[k + 1:e - 1], "\n")
        end
        push!(blocks, (spec = m[1], code = join(lines[i + 2:j - 1], "\n"), shown = shown))
    end
    return blocks
end

# the scripts of a page, by process number, with the files it writes
function doc_scripts(blocks, root)
    files = Dict{String, String}()
    scripts = Dict{Int, Vector{String}}()
    for b in blocks
        code = replace(b.code, DOC_ROOT_PLACEHOLDER => repr(root))
        f = match(r"^file (\S+)$", b.spec)
        if !isnothing(f)
            files[f[1]] = code
            continue
        end
        p = match(r"^process (\d+)(?:, throws (\w+))?$", b.spec)
        isnothing(p) && error("unknown doctest spec: $(b.spec)")
        n = parse(Int, p[1])
        if !isnothing(p[2])
            shown = isnothing(b.shown) ? "nothing" : repr(b.shown)
            code = """
                let shown = $shown
                    err = try
                        $(code)
                        nothing
                    catch e
                        e
                    end
                    err isa $(p[2]) || error("expected a $(p[2]), got " * repr(err))
                    msg = sprint(showerror, err)
                    isnothing(shown) || msg == shown || error("the page shows\\n" * shown * "\\nbut the error is\\n" * msg)
                end"""
        end
        push!(get!(scripts, n, String[]), code)
    end
    return files, sort!(collect(scripts); by = first)
end

@testset "Documentation walkthroughs" begin
    for page in DOC_PAGES
        @testset "$page" begin
            path = joinpath(pkgdir(OutputVault), "docs", "src", "guide", page)
            git_dir = make_git_repo()
            with_tempdir() do root
                files, scripts = doc_scripts(doc_blocks(path), root)
                @test !isempty(scripts)
                for (name, code) in files
                    write(joinpath(git_dir, name), code)
                end
                for (n, parts) in scripts
                    script = joinpath(git_dir, "script$n.jl")
                    write(script, join(parts, "\n\n") * "\n\nprintln(\"DOCTEST DONE\")\n")
                    cmd = Cmd(`$(Base.julia_cmd()) --project=$(Base.active_project()) $script`; dir = git_dir)
                    out = IOBuffer()
                    ok = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out)).exitcode == 0
                    log = String(take!(out))
                    passed = ok && occursin("DOCTEST DONE", log)
                    passed || println("── $page, process $n ──\n", log)
                    @test passed
                end
            end
        end
    end
end
