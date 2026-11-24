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

## Run keys: the names that identify runs in a NamedTuple of results

const RUN_FIELDS = (:branch, :experdef, :economy)

# the fields of a run key: one of RUN_FIELDS or a tuple of them
function _key_fields(key)
    fields = key isa Symbol ? (key,) : Tuple(key)
    (isempty(fields) || !all(f -> f isa Symbol && f in RUN_FIELDS, fields) || !allunique(fields)) &&
        throw(ArgumentError("key must be one of $RUN_FIELDS or a tuple of distinct ones, got $(repr(key))"))
    return fields
end

# a name as a Symbol that can be typed as a NamedTuple field: other characters become '_'
_key_name(x) = Symbol(replace(string(x), r"[^A-Za-z0-9_]" => "_"))

# the key of a run (branch, experdef, economy): its `key` fields joined with "__"
_run_key(run::NamedTuple, fields) = _key_name(join((getproperty(run, f) for f in fields), "__"))

# the keys of `runs` (NamedTuples with fields branch, experdef, economy); distinct runs with the
# same key are an error that lists them
function run_keys(runs::AbstractVector, key)
    fields = _key_fields(key)
    keys = [_run_key(r, fields) for r in runs]
    if !allunique(keys)
        clashes = join(("  $k: " * join(("$(r.branch)/res-$(r.experdef)-$(r.economy)" for (r, k2) in zip(runs, keys) if k2 == k), ", ")
                        for k in unique(k for k in keys if count(==(k), keys) > 1)), "\n")
        hint = length(fields) == length(RUN_FIELDS) ?
               "Their names differ only in characters that become '_'; rename one of them." :
               "Narrow the runs (branch, experdef) or use a longer key, such as $(repr(RUN_FIELDS))."
        throw(ArgumentError("key = $(repr(key)) gives the same name to different runs:\n$clashes\n$hint"))
    end
    return keys
end

"""
    find_matching_results(cfg::AbstractConfig, wildcard = "\$(current_branch())/res-*"; key = (:branch, :experdef, :economy))
    find_matching_results(wildcard = ...; kwargs...)

The saved runs whose folders match `wildcard`, a glob relative to the output root, as a `NamedTuple`
of `RunHandle`s. Folders whose names are not of the form `res-<experdef>-<economy>` are skipped.

Each run is named by `key`: the run's `branch`, `experdef` and `economy` joined with `__`, or only
the fields you pass (`key = :economy`, `key = (:experdef, :economy)`). Characters other than letters,
digits and `_` become `_`, so that `feature/x` is `feature_x`. If two runs get the same name, it is an
`ArgumentError` that lists them.
"""
function find_matching_results(cfg::AbstractConfig, wildcard="$(current_branch())/res-*";
        key = RUN_FIELDS)
    root = output_root(cfg)
    runs = RunHandle[]
    for path in sort(filter(isdir, glob(wildcard, root)))
        m = match(r"^res-(?<experdef>[^-]+)-(?<economy>.+)$", basename(path))
        isnothing(m) && continue
        branch = replace(relpath(dirname(path), root), '\\' => '/')
        push!(runs, RunHandle(m[:economy]; experdef = m[:experdef], branch))
    end
    names = run_keys([(; r.branch, r.experdef, r.economy) for r in runs], key)
    return NamedTuple{Tuple(names)}(Tuple(runs))
end

find_matching_results(wildcard="$(current_branch())/res-*"; kwargs...) =
    find_matching_results(global_config(), wildcard; kwargs...)
