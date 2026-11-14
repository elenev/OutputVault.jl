using Test
using OutputVault
using JLD2
using FileIO
using LibGit2

# ── Shared helpers ─────────────────────────────────────────────────────────────

make_cfg(root) = Config(;
    output_root     = root,
    components      = (solution=(:obj, :val), stats=(:n,)),
    git_component   = :solution,
    skip_components = (:simulation,),
)

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
    include("test_discovery.jl")
    include("tfi_fixtures.jl")
    include("test_tfi.jl")
end
