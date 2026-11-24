# The walkthrough pages (quick start, lifecycle) run their code: Documenter runs their @example and
# @repl blocks when it builds the docs, and test/test_docs.jl runs the same blocks in fresh Julia
# processes. Both run them in a throwaway git repository on branch `main`, prepared here, with the
# pages' output root `../outputs` next to it. A ```julia block whose preceding paragraph begins
# "Save this as `NAME`" is written to NAME in the repository.

const WALKTHROUGH_PAGES = ("quickstart.md", "lifecycle.md")
walkthrough_path(page) = joinpath(@__DIR__, "src", "guide", page)

# the ```julia blocks of a page that its text says to save as a file: the block after a paragraph
# beginning "Save this as `NAME`", by NAME
function doc_files(path)
    lines = readlines(path)
    files = Dict{String, String}()
    for (i, l) in enumerate(lines)
        m = match(r"^Save this as `([^`]+)`", l)
        isnothing(m) && continue
        start = findnext(==("```julia"), lines, i)
        j = findnext(==("```"), lines, start + 1)
        files[m[1]] = join(lines[start + 1:j - 1], "\n") * "\n"
    end
    return files
end

# the @example and @repl blocks of a page, grouped by name in order of first appearance:
# [(name, [(kind, code), ...]), ...] with kind :example or :repl
function doc_groups(path)
    lines = readlines(path)
    groups = Pair{String, Vector{Tuple{Symbol, String}}}[]
    for (i, l) in enumerate(lines)
        m = match(r"^```@(example|repl) (\S+)$", l)
        isnothing(m) && continue
        j = findnext(==("```"), lines, i + 1)
        k = findfirst(g -> first(g) == m[2], groups)
        isnothing(k) && (push!(groups, m[2] => Tuple{Symbol, String}[]); k = length(groups))
        push!(last(groups[k]), (Symbol(m[1]), join(lines[i + 1:j - 1], "\n")))
    end
    return groups
end

# a fresh folder holding `repo/`, a git repository on `main` with the walkthroughs' files committed;
# returns the repository's path (the outputs go to `../outputs`, next to it)
function walkthrough_repo()
    repo = mkpath(joinpath(mktempdir(), "repo"))
    for page in WALKTHROUGH_PAGES, (name, code) in doc_files(walkthrough_path(page))
        write(joinpath(repo, name), code)
    end
    write(joinpath(repo, "README"), "OutputVault walkthroughs\n")
    git = `git -C $repo -c user.name=docs -c user.email=docs@example.com`
    run(pipeline(`$git init -q -b main`; stdout = devnull))
    run(`$git add -A`)
    run(`$git commit -q -m walkthroughs`)
    return repo
end
