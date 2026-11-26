@testset "RunHandle" begin
    rf = RunHandle(; branch = "main", experdef = "v1", variant = "base")
    @test (rf.branch, rf.experdef, rf.variant) == ("main", "v1", "base")
    @test RunHandle("base"; branch = "main", experdef = "v1") == rf
    @test RunHandle(:base; branch = "main", experdef = "v1") == rf
    @test RunHandle(7; branch = "main").variant == "7"
    @test RunHandle("x"; branch = "main").experdef == "default"
    @test RunHandle("frm-grid_a.1+b=2"; branch = "feature/x", experdef = "e.1").variant == "frm-grid_a.1+b=2"

    @test_throws ArgumentError RunHandle("x"; branch = "main", experdef = "high-risk")
    @test_throws ArgumentError RunHandle("a b"; branch = "main")
    @test_throws ArgumentError RunHandle("a/b"; branch = "main")
    @test_throws ArgumentError RunHandle("a*"; branch = "main")
    @test_throws ArgumentError RunHandle("x"; branch = "res-old")
    @test_throws ArgumentError RunHandle("x"; branch = "feature/res-x")
    @test_throws ArgumentError RunHandle("x"; branch = "a//b")
    @test_throws ArgumentError RunHandle("x"; branch = ".staging")

    @test OutputVault.run_path("/root", RunHandle("b"; branch = "f/x", experdef = "e")) ==
          joinpath("/root", "f", "x", "res-e-b")
    @test OutputVault.parse_run_folder("res-v1-frm-grid") == ("v1", "frm-grid")
    @test isnothing(OutputVault.parse_run_folder("results"))

    # the default branch is that of the active project's repository
    repo = make_git_repo()
    try
        with_project(repo) do
            @test current_branch() == "main"
            @test RunHandle("x").branch == "main"
            git(repo, "checkout", "-q", "-b", "feature/y")
            @test RunHandle("x").branch == "feature/y"
            git(repo, "checkout", "-q", "--detach")
            err = try current_branch(); nothing catch e; e end
            @test err isa ErrorException && occursin("detached HEAD", err.msg)
        end
        with_tempdir() do dir
            write(joinpath(dir, "Project.toml"), "")
            with_project(dir) do
                @test_throws ErrorException current_branch()
            end
        end
    finally
        rm(repo; recursive = true, force = true)
    end
end

@testset "globs" begin
    m = OutputVault.glob_match
    @test m("*", "main") && !m("*", "feature/x")
    @test m("**", "main") && m("**", "feature/x/y")
    @test m("feature/*", "feature/x") && !m("feature/*", "feature")
    @test m("feature/**", "feature") && m("a/**/b", "a/b") && m("a/**/b", "a/x/y/b")
    @test m("v?", "v1") && !m("v?", "v12")
    @test m("[ab]x", "bx") && !m("[ab]x", "cx") && m("[!ab]x", "cx") && m("[a-c]x", "bx")
    @test m("r_*", "r_k") && !m("r_*", "rk")
    @test m("a.b", "a.b") && !m("a.b", "axb")          # regex characters are literal
    @test m(OutputVault.escape_glob("a*b"), "a*b") && !m(OutputVault.escape_glob("a*b"), "axb")
    @test OutputVault.isglob("boom*") && !OutputVault.isglob("boom")

    p = RunPattern(; experdef = "v1")
    @test OutputVault.matches(p, RunHandle("x"; branch = "main", experdef = "v1"))
    @test !OutputVault.matches(p, RunHandle("x"; branch = "main", experdef = "v2"))
    @test !OutputVault.matches(p, RunHandle("x"; branch = "f/x", experdef = "v1"))
    @test OutputVault.matches(RunPattern(; branch = "**"), RunHandle("x"; branch = "f/x"))
end
