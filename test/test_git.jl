provenance_file(root, rf, f) = joinpath(OutputVault.run_path(root, rf), ".provenance", f)

@testset "provenance" begin
    rf = RunHandle("base"; branch = "main", experdef = "v1")

    @testset "clean repository" begin
        with_vault() do root, repo
            save_solution(rf, (; x = 1))
            commit = strip(git(repo, "rev-parse", "HEAD"))
            @test readlines(provenance_file(root, rf, "git_commit.txt")) == [commit]
            @test !isfile(provenance_file(root, rf, "git_staged.diff"))
            @test !isfile(provenance_file(root, rf, "git_unstaged.diff"))
            @test list_run(rf).provenance == (commit = commit, dirty = false)
        end
    end

    @testset "dirty repository" begin
        with_vault() do root, repo
            write(joinpath(repo, "Project.toml"), "name = \"Changed\"\n")
            write(joinpath(repo, "staged.txt"), "staged\n")
            git(repo, "add", "staged.txt")
            write(joinpath(repo, "new.jl"), "x = 1\ny = 2")
            mkpath(joinpath(repo, "sub"))
            write(joinpath(repo, "sub", "data.bin"), UInt8[0x01, 0x00, 0x02])
            index_before = read(joinpath(repo, ".git", "index"))
            @test_logs (:warn, r"uncommitted changes") match_mode = :any save_solution(rf, (; x = 1))
            @test read(joinpath(repo, ".git", "index")) == index_before     # the index is not touched
            staged = read(provenance_file(root, rf, "git_staged.diff"), String)
            unstaged = read(provenance_file(root, rf, "git_unstaged.diff"), String)
            @test occursin("+staged", staged) && !occursin("Changed", staged)
            @test occursin("+name = \"Changed\"", unstaged)
            @test occursin("+++ b/new.jl", unstaged) && occursin("+y = 2", unstaged) &&
                  occursin("No newline at end of file", unstaged)
            @test !occursin("data.bin", unstaged)                         # binary files are skipped
            @test list_run(rf).provenance.dirty

            @test_throws ErrorException save_solution(rf, (; x = 2); dirty_repo_check = :error)
            @test load_result_item(rf, "solution/x")["value"] == 1           # the run is unchanged
            @test_logs save_solution(rf, (; x = 3); dirty_repo_check = :ignore)
            @test_throws ArgumentError save_solution(rf, (; x = 4); dirty_repo_check = :maybe)
        end
    end

    @testset "untracked files are truncated at 1 MB" begin
        with_vault() do root, repo
            write(joinpath(repo, "a.txt"), "a\n" ^ 300_000)
            write(joinpath(repo, "b.txt"), "b\n" ^ 300_000)
            save_solution(rf, (; x = 1); dirty_repo_check = :ignore)
            unstaged = read(provenance_file(root, rf, "git_unstaged.diff"), String)
            @test occursin("+++ b/a.txt", unstaged) && !occursin("+++ b/b.txt", unstaged)
            @test occursin("untracked files truncated", unstaged)
        end
    end

    @testset "submodules" begin
        with_vault() do root, repo
            sub = make_git_repo()
            try
                git(repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "lib")
                git(repo, "commit", "-q", "-m", "add submodule")
                write(joinpath(repo, "lib", "Project.toml"), "dirty inside the submodule")
                save_solution(rf, (; x = 1))
                lines = readlines(provenance_file(root, rf, "git_commit.txt"))
                @test lines[2] == "submodule lib $(strip(git(sub, "rev-parse", "HEAD")))"
                @test !isfile(provenance_file(root, rf, "git_unstaged.diff"))   # not its diffs
            finally
                rm(sub; recursive = true, force = true)
            end
        end
    end

    @testset "no repository" begin
        with_tempdir() do dir
            write(joinpath(dir, "Project.toml"), "")
            with_tempdir() do root
                with_config(Config(; output_root = root)) do
                    with_project(dir) do
                        @test_logs (:warn, r"not in a git repository") save_solution(rf, (; x = 1))
                        @test occursin("no git repository", read(provenance_file(root, rf, "git_commit.txt"), String))
                        @test isnothing(list_run(rf).provenance.commit)
                        @test_throws ErrorException save_solution(rf, (; x = 1); dirty_repo_check = :error)
                        @test_logs save_solution(rf, (; x = 1); dirty_repo_check = :ignore)
                    end
                end
            end
        end
    end
end
