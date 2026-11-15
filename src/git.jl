current_branch() = LibGit2.with(LibGit2.GitRepoExt(".")) do repo
    LibGit2.branch(repo)
end

is_repo_clean() = LibGit2.with(LibGit2.GitRepoExt(".")) do repo
    length(LibGit2.GitStatus(repo)) == 0
end

# `git diff` output (staged: index vs HEAD; otherwise working tree vs index), empty if over 1 MB
function _get_git_diff(staged::Bool)
    cmd = staged ? `git -C . diff --staged` : `git -C . diff`
    out = read(cmd, String)
    if sizeof(out) > 1024^2
        @warn "Diff is greater than 1 MB. Not storing..."
        return ""
    end
    return out
end

# unstaged diff including untracked files anywhere in the repository (`git add -N :/` marks them,
# also from a subfolder) in a temporary copy of the index, so the repository's own index (and
# what the user has staged) is never touched. The repository is found from the working
# directory upward.
function _unstaged_diff_with_untracked()
    index = strip(read(`git -C . rev-parse --path-format=absolute --git-path index`, String))
    tmp = tempname()
    try
        isfile(index) && cp(index, tmp)
        withenv("GIT_INDEX_FILE" => tmp) do
            run(pipeline(`git -C . add -N :/`, stdout=devnull, stderr=devnull))
            _get_git_diff(false)
        end
    finally
        rm(tmp; force=true)
    end
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

    commit_id = LibGit2.with(LibGit2.GitRepoExt(".")) do repo
        string(LibGit2.GitHash(LibGit2.head(repo)))
    end

    diffs = dirty ? (staged=_get_git_diff(true), unstaged=_unstaged_diff_with_untracked()) :
                    (staged="", unstaged="")
    return commit_id, diffs
end
