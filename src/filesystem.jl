"""
    output_path(cfg::AbstractConfig, branch=current_branch()) -> String
    output_path(branch=current_branch()) -> String

Return the branch-level output directory `output_root(cfg)/branch`, creating it if absent.
The no-config form uses the module-level config set by `set_config!`.
"""
function output_path(cfg::AbstractConfig, branch::AbstractString=current_branch())
    p = joinpath(output_root(cfg), string(branch))
    isdir(p) || mkpath(p)
    return p
end

output_path(branch::AbstractString=current_branch()) = output_path(global_config(), branch)

function economy_folder(cfg::AbstractConfig, rf::RunHandle; create::Bool=false)
    p = joinpath(output_path(cfg, rf.branch), "res-$(rf.experdef)-$(rf.economy)")
    if !isdir(p)
        create ? mkpath(p) : error("Economy folder $p does not exist and create=false.")
    end
    return p
end

economy_folder(rf::RunHandle; kwargs...) = economy_folder(global_config(), rf; kwargs...)
