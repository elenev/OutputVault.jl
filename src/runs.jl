# Run identity: RunHandle (one run) and RunPattern (runs matched by globs), and the path grammar
# <output_root>/<branch>/res-<experdef>-<variant>/

const VARIANT_CHARS = r"^[A-Za-z0-9_.+=-]+$"
const EXPERDEF_CHARS = r"^[A-Za-z0-9_.+=]+$"
const RUN_PREFIX = "res-"

"""
    RunHandle(variant; branch = current_branch(), experdef = "default")
    RunHandle(; branch, experdef, variant)

Identifies a run, and so its folder `<output_root>/<branch>/res-<experdef>-<variant>`.

- `variant` uses only `A–Z`, `a–z`, `0–9` and `_ . + = -`; a `Symbol` or an integer is converted
  with `string`.
- `experdef` uses the same characters without `-`, so the folder name splits at its first hyphen.
- `branch` defaults to the git branch of the active project's repository ([`current_branch`](@ref)).
  It may contain `/` (nested folders); no level may start with `res-` or `.`. Passing a branch
  chooses only the folder: provenance always comes from the active project's repository.

The names are checked when the handle is made.
"""
struct RunHandle
    branch::String
    experdef::String
    variant::String
    function RunHandle(branch, experdef, variant)
        b, e, v = string(branch), string(experdef), string(variant)
        check_branch(b)
        if !occursin(EXPERDEF_CHARS, e)
            throw(ArgumentError("experdef \"$e\" may use only letters, digits and _ . + = (no '-': the run folder res-<experdef>-<variant> splits at the first hyphen)"))
        end
        if !occursin(VARIANT_CHARS, v)
            throw(ArgumentError("variant \"$v\" may use only letters, digits and _ . + = -"))
        end
        new(b, e, v)
    end
end

RunHandle(; branch = current_branch(), experdef = "default", variant) = RunHandle(branch, experdef, variant)
RunHandle(variant; branch = current_branch(), experdef = "default") = RunHandle(branch, experdef, variant)

function check_branch(b)
    levels = split(b, '/')
    if isempty(b) || any(isempty, levels) || occursin('\\', b)
        throw(ArgumentError("branch \"$b\" must be nonempty levels separated by '/'"))
    end
    for l in levels
        if startswith(l, RUN_PREFIX) || startswith(l, ".")
            throw(ArgumentError("branch \"$b\": a level may not start with \"$RUN_PREFIX\" or \".\""))
        end
    end
end

Base.show(io::IO, rf::RunHandle) =
    print(io, "RunHandle(branch = ", repr(rf.branch), ", experdef = ", repr(rf.experdef), ", variant = ", repr(rf.variant), ")")

# the folder name of a run
run_folder_name(rf::RunHandle) = RUN_PREFIX * rf.experdef * "-" * rf.variant

# the run's folder under `root` (not created)
run_path(root::AbstractString, rf::RunHandle) = joinpath(root, split(rf.branch, '/')..., run_folder_name(rf))

"""
    run_path(rf::RunHandle) -> String

The folder of the run under the configured output root. It exists once the solution is saved.
"""
run_path(rf::RunHandle) = run_path(output_root(global_config()), rf)

# (experdef, variant) of a run folder name, or `nothing` if it is not one
function parse_run_folder(name)
    m = match(r"^res-([^-]+)-(.+)$", name)
    if isnothing(m)
        return nothing
    end
    return (m[1], m[2])
end

"""
    RunPattern(; branch = "*", experdef = "*", variant = "*")

Runs matched by globs, one per part of the run's identity: `*` matches within one level, `?` one
character, `[...]` one of a set of characters, and `**` (in `branch`) any number of levels, so
`branch = "**"` includes nested branches. Used by [`find_runs`](@ref) and `query_results`.
"""
@kwdef struct RunPattern
    branch::String = "*"
    experdef::String = "*"
    variant::String = "*"
end

"""
    matches(pattern::RunPattern, rf::RunHandle) -> Bool

Whether the run's branch, experdef and variant match the pattern's globs.
"""
matches(p::RunPattern, rf::RunHandle) =
    glob_match(p.branch, rf.branch) && glob_match(p.experdef, rf.experdef) && glob_match(p.variant, rf.variant)

## Globs

"""
    isglob(s) -> Bool

Whether the string contains a glob character (`*`, `?` or `[`).
"""
isglob(s::AbstractString) = any(in(('*', '?', '[')), s)

"""
    glob_match(pattern, name) -> Bool

Whether `name` (levels separated by `/`) matches the glob `pattern`: `*` within a level, `?` one
character, `[abc]`, `[a-z]` and `[!abc]` one character of a set, and a level `**` any number of
levels.
"""
glob_match(pattern::AbstractString, name::AbstractString) = match_levels(split(pattern, '/'), split(name, '/'))

function match_levels(pat, lev)
    if isempty(pat)
        return isempty(lev)
    end
    if pat[1] == "**"
        return any(i -> match_levels(pat[2:end], lev[i:end]), 1:length(lev)+1)
    end
    if isempty(lev)
        return false
    end
    return occursin(level_regex(pat[1]), lev[1]) && match_levels(pat[2:end], lev[2:end])
end

# a regex for one glob level
function level_regex(p::AbstractString)
    io = IOBuffer()
    print(io, '^')
    chars = collect(p)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if c == '*'
            print(io, ".*")
        elseif c == '?'
            print(io, '.')
        elseif c == '[' && (j = findnext(==(']'), chars, i + 2)) !== nothing
            body = String(chars[i+1:j-1])
            neg = startswith(body, '!') || startswith(body, '^')
            body = neg ? body[2:end] : body
            print(io, '[', neg ? "^" : "", replace(body, '\\' => "\\\\"), ']')
            i = j
        else
            print(io, escape_regex(c))
        end
        i += 1
    end
    print(io, '$')
    return Regex(String(take!(io)))
end

escape_regex(c::Char) = c in "\\^\$.|?*+()[]{}" ? "\\" * c : string(c)

# a glob that matches the string `s` exactly
escape_glob(s::AbstractString) = join(c in ('*', '?', '[') ? "[$c]" : string(c) for c in s)
