# Git state of the active project's repository: the branch runs default to, and the provenance
# that save_solution records. Everything is read with the git command line; the repository's
# index is never written.

const UNTRACKED_LIMIT = 1024^2      # bytes of untracked text files added to git_unstaged.diff

# the folder of the active project, whose repository provenance comes from
project_dir() = dirname(Base.active_project())

# `git -C dir args...` output, or `nothing` if git fails
function git_output(dir, args...)
    out = IOBuffer()
    ok = success(pipeline(Cmd(`git -C $dir $args`; ignorestatus = true); stdout = out, stderr = devnull))
    if !ok
        return nothing
    end
    return String(take!(out))
end

# the top folder of the repository holding `dir`, or `nothing`
function repo_root(dir = project_dir())
    out = git_output(dir, "rev-parse", "--show-toplevel")
    if isnothing(out)
        return nothing
    end
    return strip(out)
end

"""
    current_branch() -> String

The git branch checked out in the repository of the active project (`Base.active_project()`), the
default branch of a [`RunHandle`](@ref). An error on a detached HEAD or outside a repository: pass
`branch` to `RunHandle` there.
"""
function current_branch()
    dir = project_dir()
    if isnothing(repo_root(dir))
        error("the active project's folder $dir is not in a git repository; pass `branch` to RunHandle")
    end
    out = git_output(dir, "symbolic-ref", "--short", "-q", "HEAD")
    if isnothing(out)
        error("the repository of $dir has a detached HEAD; pass `branch` to RunHandle")
    end
    return String(strip(out))
end

## Provenance

# what save_solution records: the commit (with submodule commits) and, if dirty, the diffs
struct GitState
    commit::String
    staged::String
    unstaged::String
    dirty::Bool
end

# the git state of the active project's repository; `check` (:warn, :error, :ignore) says what to
# do when the repository is dirty or absent
function git_state(check::Symbol)
    if !(check in (:warn, :error, :ignore))
        throw(ArgumentError("dirty_repo_check must be :warn, :error or :ignore, got :$check"))
    end
    dir = project_dir()
    root = repo_root(dir)
    if isnothing(root)
        report(check, "the active project's folder $dir is not in a git repository; no commit is recorded")
        return GitState("no git repository at $dir\n", "", "", false)
    end
    commit = strip(git_output(root, "rev-parse", "HEAD")) * "\n" * submodule_commits(root)
    dirty = !isempty(something(git_output(root, "status", "--porcelain", "--ignore-submodules=dirty"), ""))
    if !dirty
        return GitState(commit, "", "", false)
    end
    report(check, "the repository $root has uncommitted changes; their diffs are saved with the solution")
    staged = something(git_output(root, "diff", "--staged", "--ignore-submodules=dirty"), "")
    unstaged = something(git_output(root, "diff", "--ignore-submodules=dirty"), "") * untracked_diff(root)
    return GitState(commit, staged, unstaged, true)
end

function report(check, msg)
    if check === :error
        error(msg)
    elseif check === :warn
        @warn msg
    end
end

# one line per submodule: "submodule <path> <commit>"
function submodule_commits(root)
    out = something(git_output(root, "submodule", "status", "--recursive"), "")
    lines = String[]
    for l in split(out, '\n'; keepempty = false)
        parts = split(lstrip(l, [' ', '+', '-', 'U']))
        if length(parts) >= 2
            push!(lines, "submodule $(parts[2]) $(parts[1])")
        end
    end
    return isempty(lines) ? "" : join(lines, '\n') * "\n"
end

# untracked text files as added in a diff, up to UNTRACKED_LIMIT bytes in total; binary files skipped
function untracked_diff(root)
    files = split(something(git_output(root, "ls-files", "--others", "--exclude-standard", "-z"), ""), '\0'; keepempty = false)
    io = IOBuffer()
    total = 0
    for f in sort(files)
        bytes = read(joinpath(root, f))
        if is_binary(bytes)
            continue
        end
        if total + length(bytes) > UNTRACKED_LIMIT
            println(io, "# OutputVault: untracked files truncated at $(UNTRACKED_LIMIT ÷ 1024) KB")
            break
        end
        total += length(bytes)
        write_added_file(io, f, String(bytes))
    end
    return String(take!(io))
end

# git's heuristic: a NUL byte in the first 8000 bytes
is_binary(bytes) = any(==(0x00), view(bytes, 1:min(length(bytes), 8000)))

function write_added_file(io, f, text)
    lines = split(text, '\n')
    newline_at_end = endswith(text, '\n')
    if newline_at_end
        pop!(lines)
    end
    println(io, "diff --git a/$f b/$f\nnew file mode 100644\n--- /dev/null\n+++ b/$f")
    if isempty(lines)
        return
    end
    println(io, "@@ -0,0 +1,$(length(lines)) @@")
    for l in lines
        println(io, "+", l)
    end
    if !newline_at_end
        println(io, "\\ No newline at end of file")
    end
end

# provenance/ in the run folder `dir`
function write_provenance(dir, g::GitState)
    p = mkpath(joinpath(dir, PROVENANCE))
    write(joinpath(p, "git_commit.txt"), g.commit)
    if !isempty(g.staged)
        write(joinpath(p, "git_staged.diff"), g.staged)
    end
    if !isempty(g.unstaged)
        write(joinpath(p, "git_unstaged.diff"), g.unstaged)
    end
end
