# A run's items: saving the solution (which replaces the run), saving, loading, moving and
# deleting result items, and listing a run.

# the run's folder, which must exist
function existing_run(rf::RunHandle)
    p = run_path(output_root(global_config()), rf)
    if !isdir(p)
        throw(ArgumentError("no saved run $(rf.branch)/$(run_folder_name(rf)) under $(output_root(global_config())); save its solution first"))
    end
    return p
end

"""
    save_solution(rf::RunHandle, solution; dirty_repo_check = :warn) -> String

Start the run `rf` over with `solution`: everything saved for the run before is replaced. The
solution is written at the path `solution` by the storage rules (a NamedTuple `(; obj, stv)` gives
`solution/obj.jld2` and `solution/stv.jld2`), the git state of the active project's repository in
`.provenance/`, and, if the configuration's `native` is set, the solution as Julia objects in
`native.jld2`, one key per member of a NamedTuple.

`dirty_repo_check` (`:warn`, `:error` or `:ignore`) says what to do when the repository has
uncommitted changes, or there is none. A dirty repository's staged and unstaged diffs (the latter
with untracked text files, up to 1 MB) are saved in `.provenance/`.

The new run is written to a folder under `staging_root`, then renamed into place; the old run is
renamed aside first and deleted last. Returns the folder holding the new run: the run's folder, or,
if a rename or move failed (on Windows, open files can block them), the staging folder, with a
warning that says where the new and the old run are. If only the final delete fails, the new run is
in place and a warning names the old folder to delete by hand.
"""
function save_solution(rf::RunHandle, solution; dirty_repo_check::Symbol = :warn)
    cfg = global_config()
    git = git_state(dirty_repo_check)
    stage = joinpath(mkpath(staging_root(cfg)), rf.experdef * "-" * rf.variant * "-" * randstring(8))
    try
        mkdir(stage)
        write_item(stage, SOLUTION, solution, table_format(cfg), SOLUTION)
        write_provenance(stage, git)
        if native(cfg)
            write_native(joinpath(stage, NATIVE_FILE), solution)
        end
    catch
        rm(stage; recursive = true, force = true)
        rethrow()
    end
    return replace_run(stage, run_path(output_root(cfg), rf))
end

# the solution as Julia objects: one key per member of a NamedTuple, else the key "solution"
function write_native(path, solution)
    jldopen(path, "w") do io
        if solution isa NamedTuple
            for (k, v) in pairs(solution)
                io[string(k)] = v
            end
        else
            io[SOLUTION] = solution
        end
    end
end

# put the staged run in place of the run folder `final`: old run aside, new one in, old one deleted.
# On Windows, open or memory-mapped files can block a rename or a delete. Whatever fails, no run is
# lost or partly deleted: `final` holds the new run or the intact old one, and a warning says where
# both are. Returns the folder holding the new run.
function replace_run(stage, final)
    parent = mkpath(dirname(final))
    trash = joinpath(parent, ".trash-" * basename(final) * "-" * randstring(8))
    had_old = isdir(final)
    if had_old
        try
            mv(final, trash)
        catch err
            return stranded(stage, final, "the existing run cannot be renamed", err)
        end
    end
    try
        move_folder(stage, final)
    catch err
        if had_old
            try
                mv(trash, final)
            catch err2
                return stranded(stage, final, "the new run cannot be moved into place and the old one cannot be restored", err2; trash)
            end
        end
        return stranded(stage, final, "the new run cannot be moved into place", err)
    end
    if had_old
        try
            rm(trash; recursive = true)
        catch err
            @warn "The new run is in place, but the old one could not be deleted; delete it by hand" trash exception = err
        end
    end
    return final
end

function stranded(stage, final, reason, err; trash = nothing)
    old = isnothing(trash) ? "unchanged: $final" : "renamed to $trash (nothing is at $final)"
    @warn """NEW RUN NOT AT THE RUN'S PATH: $reason.
      new run:  $stage
      old run:  $old
      reason:   $(sprint(showerror, err))
      Close whatever holds files in the old run (on Windows: open files, a shell or Julia session in it), then move the new run into place."""
    return stage
end

# rename, or copy when the staging root is on another file system
function move_folder(src, dst)
    try
        mv(src, dst)
    catch
        if ispath(dst) || !isdir(src)
            rethrow()
        end
        try
            cp(src, dst)
        catch
            rm(dst; recursive = true, force = true)
            rethrow()
        end
        rm(src; recursive = true, force = true)
    end
end

"""
    save_result_item(rf::RunHandle, path, value) -> String

Write `value` at `path` in the run (levels separated by `/`, e.g. `"stats"` or `"irf/ss"`) by the
storage rules: a table file `path.<ext>`, a folder `path/` for a NamedTuple, or `path.jld2`. What
was at `path` before is replaced, a folder with everything in it. The run's solution must have been
saved. Saving below an item that is a file (`"irf/ss"` when `irf.jld2` exists) is an error.
Returns the item's file or folder.
"""
function save_result_item(rf::RunHandle, path, value)
    levels = writable_levels(path)
    return write_at(existing_run(rf), levels, value, table_format(global_config()), string(path))
end

"""
    load_result_item(rf::RunHandle, path; native = false)
    load_result_item(rf::RunHandle, path, T; context = nothing)

The item at `path` in the run.

Without a type, its data: a table file as a [`StoredTable`](@ref Formats.StoredTable) (columns and
file metadata), a folder as a NamedTuple of its items in alphabetical order, and
a `.jld2` file as a Dict of its contents.

With a type `T`, the item restored as a `T`: `read_portable_jld2(T, io; context)` for a `.jld2` file, and
otherwise `from_storage(T, data; context)` of its data.

`load_result_item(rf, "solution"; native = true)` reads the native copy (`native.jld2`, or
`solution/res.jld2` in runs saved with OutputVault 0.3) with JLD2 alone, and returns a NamedTuple
with one member per key. `native = true` is an error for other paths.
"""
function load_result_item(rf::RunHandle, path; native::Bool = false)
    levels = readable_levels(path)
    dir = existing_run(rf)
    if native
        if levels != [SOLUTION]
            throw(ArgumentError("native = true reads only the solution, not \"$path\""))
        end
        return read_native(dir)
    end
    return read_form(single_form(joinpath(dir, levels...), string(path)); skip = solution_skip(levels))
end

function load_result_item(rf::RunHandle, path, T::Type; context = nothing)
    levels = readable_levels(path)
    return read_typed(joinpath(existing_run(rf), levels...), string(path), T, context; skip = solution_skip(levels))
end

# reading solution/ skips the native copy of runs saved with OutputVault 0.3
solution_skip(levels) = levels == [SOLUTION] ? [LEGACY_NATIVE_FILE] : String[]

function read_native(dir)
    path = joinpath(dir, NATIVE_FILE)
    if !isfile(path)
        path = joinpath(dir, SOLUTION, LEGACY_NATIVE_FILE)
    end
    if !isfile(path)
        throw(ArgumentError("the run $dir has no native copy of its solution (saved with native = false)"))
    end
    d = jldopen(path, "r") do io
        [Symbol(k) => io[k] for k in keys(io)]
    end
    return NamedTuple(d)
end

"""
    move_result_item(rf::RunHandle, from, to)

Move the item at path `from` to path `to` within the run, unchanged. An error if nothing is at
`from` or something is at `to`. Neither may be under a reserved name (`solution`,
`native`).
"""
function move_result_item(rf::RunHandle, from, to)
    src, dst = writable_levels(from), writable_levels(to)
    dir = existing_run(rf)
    p = single_form(joinpath(dir, src...), string(from))
    if !isempty(item_forms(joinpath(dir, dst...)))
        throw(ArgumentError("cannot move \"$from\" to \"$to\": an item is already at \"$to\""))
    end
    check_parents(dir, dst, string(to))
    suffix = isdir(p) ? "" : "." * file_extension(basename(p))
    target = joinpath(mkpath(joinpath(dir, dst[1:end-1]...)), dst[end] * suffix)
    mv(p, target)
    return target
end

"""
    delete_result_item(rf::RunHandle, path)

Remove the item at `path`, in every form. An error if there is none, and for the solution and the
reserved names.
"""
function delete_result_item(rf::RunHandle, path)
    levels = writable_levels(path)
    stem = joinpath(existing_run(rf), levels...)
    if isempty(item_forms(stem))
        throw(ArgumentError("no item \"$path\" in the run"))
    end
    remove_item(stem)
    return nothing
end

## Listing a run

"""
    RunDisplay

What a run holds, as returned by [`list_run`](@ref), printed as a readable listing: `run` (the `RunHandle`), `provenance` (a
NamedTuple `(; commit, dirty)`; `commit` is `nothing` if no commit was recorded) and `items` (a
column table with `path`, `kind` (`:table`, `:jld2` or `:folder`) and `format`, the file
extension).
"""
struct RunDisplay
    run::RunHandle
    provenance::NamedTuple{(:commit, :dirty), Tuple{Union{Nothing, String}, Bool}}
    items::NamedTuple{(:path, :kind, :format), Tuple{Vector{String}, Vector{Symbol}, Vector{String}}}
end

"""
    list_run(rf::RunHandle) -> RunDisplay

What the run holds, read from its folder: the run, its provenance (commit, dirty or not) and a
table of its items, the solution's included, with their paths, kinds and formats.
"""
function list_run(rf::RunHandle)
    dir = existing_run(rf)
    items = (path = String[], kind = Symbol[], format = String[])
    list_items!(items, dir, "")
    return RunDisplay(rf, read_provenance(dir), items)
end

function list_items!(items, dir, prefix)
    for f in sort(readdir(dir))
        p = joinpath(dir, f)
        if startswith(f, ".") || (isempty(prefix) && f == NATIVE_FILE)
            continue
        end
        if isdir(p)
            push!(items.path, prefix * f); push!(items.kind, :folder); push!(items.format, "")
            list_items!(items, p, prefix * f * "/")
        else
            kind = file_kind(f)
            if !isnothing(kind)
                push!(items.path, prefix * item_name(f))
                push!(items.kind, kind === :jld2 ? :jld2 : :table)
                push!(items.format, file_extension(f))
            end
        end
    end
end

# the commit and whether diffs were saved; runs saved with OutputVault 0.3 keep them in solution/
function read_provenance(dir)
    p = joinpath(dir, PROVENANCE)
    if !isdir(p)
        p = joinpath(dir, SOLUTION)
    end
    file = joinpath(p, "git_commit.txt")
    line = isfile(file) ? strip(first(eachline(file))) : ""
    commit = occursin(r"^[0-9a-f]{40}$", line) ? String(line) : nothing
    dirty = isfile(joinpath(p, "git_staged.diff")) || isfile(joinpath(p, "git_unstaged.diff"))
    return (; commit, dirty)
end

function Base.show(io::IO, ::MIME"text/plain", c::RunDisplay)
    println(io, "Run ", c.run.branch, "/", run_folder_name(c.run))
    commit = isnothing(c.provenance.commit) ? "none recorded" : c.provenance.commit
    println(io, "  commit: ", commit, c.provenance.dirty ? " (dirty: diffs saved)" : "")
    print(io, "  items:")
    for (p, k, f) in zip(c.items.path, c.items.kind, c.items.format)
        print(io, "\n    ", p, k === :folder ? "/" : "." * f)
    end
end

## Objects outside a run

"""
    write_object_file(path, x)

Save one object outside any run, as a `.jld2` file written by [`write_portable_jld2`](@ref). The file is
written to a temporary name and then moved to `path`.
"""
function write_object_file(path, x)
    tmp = path * ".tmp-" * randstring(8)
    try
        jldopen(io -> write_portable_jld2(io, x), tmp, "w")
        mv(tmp, path; force = true)
    finally
        rm(tmp; force = true)
    end
    return path
end

"""
    read_object_file(path, T; context = nothing)

Restore an object saved by [`write_object_file`](@ref) as a `T`, with [`read_portable_jld2`](@ref).
"""
read_object_file(path, T::Type; context = nothing) = jldopen(io -> read_portable_jld2(T, io; context), path, "r")
