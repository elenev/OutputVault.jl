using Test
using OutputVault
using JLD2
using FileIO
using LibGit2

# ── Shared helpers ─────────────────────────────────────────────────────────────

make_cfg(root) = Config(; output_root = root)

# Like mktempdir(f), but collects garbage before removal. On Windows, files that Parquet2 has
# memory-mapped cannot be deleted until a GC has run, which would log a cleanup error. Tests of
# that behaviour itself (test_replace.jl) do not collect inside their bodies.
function with_tempdir(f)
    dir = mktempdir()
    try
        f(dir)
    finally
        GC.gc(); GC.gc()
        rm(dir; recursive = true, force = true)
    end
end

function make_git_repo()
    dir = mktempdir()
    repo = LibGit2.init(dir)
    LibGit2.with(repo) do r
        sig = LibGit2.Signature("Test", "test@test.com", round(Int, time()), 0)
        write(joinpath(dir, ".gitkeep"), "")
        LibGit2.add!(r, ".gitkeep")
        LibGit2.commit(r, "init"; author=sig, committer=sig)
    end
    return dir
end

# ── Test suites ────────────────────────────────────────────────────────────────

@testset "OutputVault" begin
    include("test_types.jl")
    include("test_global_config.jl")
    include("test_filesystem.jl")
    include("test_git.jl")
    include("test_save_load.jl")
    include("test_replace.jl")
    include("test_discovery.jl")
    include("tfi_fixtures.jl")
    include("test_tfi.jl")
    include("test_lifecycle.jl")
    include("test_quickstart.jl")
    include("test_duckdb.jl")
end
