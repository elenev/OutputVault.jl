# Finding saved runs from folder names alone: every folder res-<experdef>-<variant> under the root,
# its branch the levels above it. Folders whose names start with '.' (staging, replaced runs) are
# skipped.

"""
    find_runs(pattern = RunPattern(); root = output_root(global_config())) -> Vector{RunHandle}

The saved runs under `root` that match `pattern` (a [`RunPattern`](@ref)), sorted by branch,
experdef and variant. Reads only folder names, so no file is opened or downloaded. Folders whose
names are not valid run names are skipped with a warning.
"""
function find_runs(pattern::RunPattern = RunPattern(); root::AbstractString = output_root(global_config()))
    runs = RunHandle[]
    if isdir(root)
        collect_runs!(runs, root, String[])
    end
    found = filter(rf -> matches(pattern, rf), runs)
    return sort!(found; by = rf -> (rf.branch, rf.experdef, rf.variant))
end

function collect_runs!(runs, dir, branch)
    for f in readdir(dir)
        p = joinpath(dir, f)
        if startswith(f, ".") || !isdir(p)
            continue
        end
        if startswith(f, RUN_PREFIX)
            add_run!(runs, branch, f, p)
        else
            collect_runs!(runs, p, vcat(branch, f))
        end
    end
end

function add_run!(runs, branch, f, p)
    if isempty(branch)
        return
    end
    keys = parse_run_folder(f)
    if isnothing(keys)
        @warn "Skipping $p: not a run folder name res-<experdef>-<variant>" maxlog = 10
        return
    end
    try
        push!(runs, RunHandle(join(branch, '/'), keys...))
    catch err
        if !(err isa ArgumentError)
            rethrow()
        end
        @warn "Skipping $p: $(err.msg)" maxlog = 10
    end
end
