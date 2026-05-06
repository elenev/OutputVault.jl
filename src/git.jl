current_branch() = LibGit2.with(LibGit2.GitRepo(".")) do repo
    LibGit2.branch(repo)
end

is_repo_clean() = LibGit2.with(LibGit2.GitRepo(".")) do repo
    length(LibGit2.GitStatus(repo)) == 0
end

function _get_git_diff(staged::Bool)
    cmd = staged ? `git -C . diff --staged` : `git -C . diff`
    out = read(cmd, String)
    if sizeof(out) > 1024^2
        @warn "Diff is greater than 1 MB. Not storing..."
        return ""
    end
    return out
end

function get_commit_id(check_clean::Symbol=:warn)
    dirty = !is_repo_clean()
    if dirty
        if check_clean === :warn
            @warn "Repository is not clean. Saving git diffs to file."
        elseif check_clean === :error
            error("Repository is not clean. Commit changes before saving.")
        end
    end

    commit_id = LibGit2.with(LibGit2.GitRepo(".")) do repo
        string(LibGit2.GitHash(LibGit2.head(repo)))
    end

    if dirty
        run(pipeline(`git -C . add -N .`, stdout=devnull, stderr=devnull))
        diffs = (staged=_get_git_diff(true), unstaged=_get_git_diff(false))
        run(pipeline(`git -C . reset`, stdout=devnull, stderr=devnull))
    else
        diffs = (staged="", unstaged="")
    end

    return commit_id, diffs
end
