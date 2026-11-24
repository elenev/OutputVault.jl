"""
    output_path(cfg::AbstractConfig, branch=current_branch(); create=false) -> String
    output_path(branch=current_branch(); create=false) -> String

Return the branch-level output directory `output_root(cfg)/branch`. With `create = true` the
directory is created if absent; otherwise only the path is returned. The no-config form uses the
module-level config set by `set_config!`.
"""
function output_path(cfg::AbstractConfig, branch::AbstractString=current_branch(); create::Bool=false)
    p = joinpath(output_root(cfg), string(branch))
    create && mkpath(p)
    return p
end

output_path(branch::AbstractString=current_branch(); kwargs...) =
    output_path(global_config(), branch; kwargs...)

# `output_root/branch/res-{experdef}-{economy}`, which must exist
function economy_folder(cfg::AbstractConfig, rf::RunHandle)
    p = _economy_path(cfg, rf)
    isdir(p) || error("Economy folder $p does not exist; save the solution first.")
    return p
end

economy_folder(rf::RunHandle) = economy_folder(global_config(), rf)

# `output_root/branch/res-{experdef}-{economy}`, not created
_economy_path(cfg, rf) = joinpath(output_path(cfg, rf.branch), "res-$(rf.experdef)-$(rf.economy)")
