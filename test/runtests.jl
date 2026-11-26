using Test
using OutputVault
using OutputVault: Formats
using JLD2, Tables, DataAPI, Parquet2

# ── Shared helpers ─────────────────────────────────────────────────────────────

const PARQUET = Formats.ParquetFormat()

# Like mktempdir(f), but collects garbage before removal, so that no file is held open on Windows.
function with_tempdir(f)
    dir = mktempdir()
    try
        f(dir)
    finally
        GC.gc(); GC.gc()
        rm(dir; recursive = true, force = true)
    end
end

git(dir, args...) = read(`git -C $dir -c user.name=Test -c user.email=test@example.com $args`, String)

# a throwaway git repository with one commit on branch main, holding a Project.toml
function make_git_repo()
    dir = mktempdir()
    git(dir, "init", "-q", "-b", "main")
    write(joinpath(dir, "Project.toml"), "name = \"Throwaway\"\n")
    git(dir, "add", "Project.toml")
    git(dir, "commit", "-q", "-m", "init")
    return dir
end

# call f() with `dir`'s Project.toml as the active project, whose repository gives the provenance
function with_project(f, dir)
    old = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = joinpath(dir, "Project.toml")
    try
        return f()
    finally
        Base.ACTIVE_PROJECT[] = old
    end
end

# f(root, repo) with a configuration over a temporary root, in a throwaway repository
function with_vault(f; table_format = PARQUET, native = true)
    repo = make_git_repo()
    try
        with_tempdir() do root
            cfg = Config(; output_root = root, table_format, native)
            with_project(repo) do
                with_config(() -> f(root, repo), cfg)
            end
        end
    finally
        rm(repo; recursive = true, force = true)
    end
end

# ── Test suites ────────────────────────────────────────────────────────────────

@testset "OutputVault" begin
    include("test_formats.jl")
    include("test_runs.jl")
    include("test_config.jl")
    include("test_git.jl")
    include("test_items.jl")
    include("test_frontend.jl")
    include("test_discovery.jl")
end
