"""
    load(cfg::AbstractConfig, rf::RunHandle, component::Symbol) -> NamedTuple
    load(rf::RunHandle, component::Symbol) -> NamedTuple

Load a saved component from its `.jld2` file and return a `NamedTuple` keyed by the
property names declared for that component in `cfg`. The no-config form uses the
module-level config.
"""
function FileIO.load(cfg::AbstractConfig, rf::RunHandle, component::Symbol)
    path = joinpath(economy_folder(cfg, rf), "$component.jld2")
    isfile(path) || error("File not found: $path")
    d     = load(path)
    props = components(cfg)[component]
    return NamedTuple{props}(tuple((d[string(p)] for p in props)...))
end

FileIO.load(rf::RunHandle, component::Symbol) =
    FileIO.load(global_config(), rf, component)

"""
    save_result(cfg::AbstractConfig, rf::RunHandle, result; skip, dirty_repo_check) -> String
    save_result(rf::RunHandle, result; kwargs...) -> String

Save all components of `result` to `.jld2` files under the economy folder for `rf`.

# Keyword arguments
- `skip`: tuple of component symbols to omit; defaults to `skip_components(cfg)`.
- `dirty_repo_check`: `:warn` (default), `:error`, or `:ignore`. Controls behavior when
  the repository has uncommitted changes.

Git provenance (`git_commit_id`, `git_diffs`) is injected into the `git_component(cfg)`
file. Returns the economy folder path.
"""
function save_result(cfg::AbstractConfig, rf::RunHandle, result;
        skip::Tuple{Vararg{Symbol}} = skip_components(cfg),
        dirty_repo_check::Symbol    = :warn)

    commit_id, diffs = get_commit_id(dirty_repo_check)
    epath = economy_folder(cfg, rf; create=true)

    for (component, props) in pairs(components(cfg))
        component in skip && continue
        data = Dict{Symbol, Any}(p => getproperty(result, p) for p in props)
        if component === git_component(cfg)
            data[:git_commit_id] = commit_id
            data[:git_diffs]     = diffs
        end
        jldsave(joinpath(epath, "$component.jld2"); data...)
    end

    return epath
end

save_result(rf::RunHandle, result; kwargs...) =
    save_result(global_config(), rf, result; kwargs...)
