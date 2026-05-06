module OutputVaultTFIExt

using OutputVault
using FileIO
using TransitionFunctionIteration

function TransitionFunctionIteration.compare_economies(
        moments::NamedTuple,
        economies::NamedTuple{K, NTuple{N, OutputVault.RunHandle}} where {K, N};
        kwargs...)
    stats = map(e -> FileIO.load(e, :stats).stats, economies)
    return compare_economies(moments, stats; kwargs...)
end

end # module
