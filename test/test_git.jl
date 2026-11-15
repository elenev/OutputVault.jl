@testset "git" begin
    @testset "current_branch and is_repo_clean" begin
        git_dir = make_git_repo()
        cd(git_dir) do
            branch = OutputVault.current_branch()
            @test branch isa String
            @test !isempty(branch)

            @test OutputVault.is_repo_clean() == true

            # write untracked file → dirty
            write(joinpath(git_dir, "dirty.txt"), "x")
            @test OutputVault.is_repo_clean() == false
        end
    end

    @testset "from a subfolder of the repository" begin
        git_dir = make_git_repo()
        sub = mkpath(joinpath(git_dir, "code", "pkg"))
        write(joinpath(git_dir, "top_untracked.txt"), "x")
        cd(sub) do
            @test OutputVault.current_branch() isa String
            commit_id, diffs = OutputVault.get_commit_id(:ignore)
            @test occursin(r"^[0-9a-f]{40}$", commit_id)
            @test occursin("top_untracked.txt", diffs.unstaged)    # untracked files repository-wide
        end
    end

    @testset "get_commit_id clean repo" begin
        git_dir = make_git_repo()
        cd(git_dir) do
            commit_id, diffs = OutputVault.get_commit_id(:ignore)
            @test occursin(r"^[0-9a-f]{40}$", commit_id)
            @test diffs.staged   == ""
            @test diffs.unstaged == ""
        end
    end

    @testset "get_commit_id dirty repo" begin
        # use separate repo per subtest to avoid index contamination
        @testset ":warn warns and returns commit_id" begin
            git_dir = make_git_repo()
            cd(git_dir) do
                write(joinpath(git_dir, "dirty.txt"), "x")
                commit_id = nothing
                @test_logs (:warn, r"not clean") match_mode=:any begin
                    commit_id, _ = OutputVault.get_commit_id(:warn)
                end
                @test occursin(r"^[0-9a-f]{40}$", commit_id)
            end
        end

        @testset ":error throws" begin
            git_dir = make_git_repo()
            cd(git_dir) do
                write(joinpath(git_dir, "dirty.txt"), "x")
                @test_throws ErrorException OutputVault.get_commit_id(:error)
            end
        end

        @testset ":ignore returns commit_id and captures diffs" begin
            git_dir = make_git_repo()
            cd(git_dir) do
                write(joinpath(git_dir, "newfile.txt"), "content")
                commit_id, diffs = OutputVault.get_commit_id(:ignore)
                @test occursin(r"^[0-9a-f]{40}$", commit_id)
                # at least one diff should mention the new file
                @test occursin("newfile.txt", diffs.staged) ||
                      occursin("newfile.txt", diffs.unstaged)
            end
        end

        @testset "staged changes stay staged; untracked files are in the unstaged diff" begin
            git_dir = make_git_repo()
            cd(git_dir) do
                write(joinpath(git_dir, "staged.txt"), "s")
                run(`git -C $git_dir add staged.txt`)
                write(joinpath(git_dir, "untracked.txt"), "u")
                staged_before = read(`git -C $git_dir diff --staged --name-only`, String)
                _, diffs = OutputVault.get_commit_id(:ignore)
                @test read(`git -C $git_dir diff --staged --name-only`, String) == staged_before
                @test occursin("staged.txt", diffs.staged)
                @test occursin("untracked.txt", diffs.unstaged)
                # untracked file not marked in the repository's index
                @test !occursin("untracked.txt", read(`git -C $git_dir diff --name-only`, String))
            end
        end

        @testset "index is restored after get_commit_id" begin
            git_dir = make_git_repo()
            cd(git_dir) do
                write(joinpath(git_dir, "newfile.txt"), "content")
                # repo is dirty before
                @test !OutputVault.is_repo_clean()
                OutputVault.get_commit_id(:ignore)
                # still dirty (untracked file remains), but no extra staged files
                @test !OutputVault.is_repo_clean()
                # verify nothing got accidentally staged: run git diff --staged
                staged = read(`git -C $git_dir diff --staged`, String)
                @test isempty(staged)
            end
        end
    end
end
