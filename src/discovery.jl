"""
    get_results_folders(cfg::AbstractConfig, economies; experdef=nothing, branch=nothing)
    get_results_folders(economies; kwargs...)

Construct a `NamedTuple` of `RunHandle`s keyed by economy name for each entry in
`economies` (a single name or a collection). `experdef` and `branch` default to the
`RunHandle` constructor defaults when not supplied.
"""
function get_results_folders(cfg::AbstractConfig,
        economies::Union{NTuple{N, S}, Vector{S}, S} where {N, S <: Union{AbstractString, Symbol}};
        experdef=nothing, branch=nothing)
    kwargs = Pair{Symbol, String}[]
    isnothing(experdef) || push!(kwargs, :experdef => string(experdef))
    isnothing(branch)   || push!(kwargs, :branch   => string(branch))
    ec = Tuple(Symbol.(economies isa Union{AbstractString, Symbol} ? (economies,) : economies))
    return NamedTuple{ec}(map(e -> RunHandle(e; kwargs...), ec))
end

get_results_folders(economies; kwargs...) =
    get_results_folders(global_config(), economies; kwargs...)

function _rf_key(rf::RunHandle, format::Symbol)
    raw = if format === :economy;                     rf.economy
          elseif format === :experdef;                rf.experdef
          elseif format === :branch;                  rf.branch
          elseif format === :experdef_economy;        rf.experdef * "_" * rf.economy
          elseif format === :branch_economy;          rf.branch   * "_" * rf.economy
          elseif format === :branch_experdef;         rf.branch   * "_" * rf.experdef
          elseif format === :branch_experdef_economy; rf.branch   * "_" * rf.experdef * "_" * rf.economy
          else throw(ArgumentError("Unknown key_format :$format"))
          end
    Symbol(replace(raw, r"[^a-zA-Z0-9_]" => "_"))
end

function _auto_key_format(rfs::Vector{RunHandle})
    for fmt in (:economy, :experdef_economy, :branch_experdef_economy)
        allunique(_rf_key(rf, fmt) for rf in rfs) && return fmt
    end
    return :branch_experdef_economy
end

"""
    find_matching_results(cfg::AbstractConfig, wildcard="\$(current_branch())/res-*"; key_format=:auto)
    find_matching_results(wildcard=...; kwargs...)

Glob the output root for folders matching `wildcard`, parse their names as
`res-{experdef}-{economy}`, and return a `NamedTuple` of `RunHandle`s.

# Keyword arguments
- `key_format`: `:auto` (default), `:economy`, `:experdef_economy`, or
  `:branch_experdef_economy`. `:auto` selects the shortest format that yields unique keys.

Throws `ArgumentError` if the chosen format produces duplicate keys.
"""
function find_matching_results(cfg::AbstractConfig, wildcard="$(current_branch())/res-*";
        key_format::Symbol=:auto)
    fullpaths = filter(isdir, glob(wildcard, output_root(cfg)))

    function _parse_path(fullpath)
        parentpath, econ_folder = splitdir(fullpath)
        m = match(r"res-(?<experdef>[^-]+)-(?<economy>.+)$", econ_folder)
        isnothing(m) && return nothing
        return RunHandle(m[:economy]; experdef=m[:experdef], branch=basename(parentpath))
    end

    rfs = [p for p in (_parse_path(fp) for fp in fullpaths) if !isnothing(p)]
    isempty(rfs) && return NamedTuple()

    fmt  = key_format === :auto ? _auto_key_format(rfs) : key_format
    keys = [_rf_key(rf, fmt) for rf in rfs]
    if !allunique(keys)
        dups = unique(k for k in keys if count(==(k), keys) > 1)
        throw(ArgumentError("key_format=:$key_format produces duplicate keys: $dups"))
    end
    return NamedTuple{Tuple(keys)}(Tuple(rfs))
end

find_matching_results(wildcard="$(current_branch())/res-*"; kwargs...) =
    find_matching_results(global_config(), wildcard; kwargs...)
