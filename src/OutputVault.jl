"""
    OutputVault

Storage of model runs: one folder per run, `<output_root>/<branch>/res-<experdef>-<variant>/`,
holding a solution with the git state that produced it and result items saved after it, and
queries across runs with DuckDB.
"""
module OutputVault

using JLD2
using DuckDB: DuckDB
using Tables: Tables
using DataAPI: DataAPI
using Random: randstring

include("Formats.jl")    # OutputVault.Formats: table file formats
using .Formats: Formats, AbstractTableFormat, StoredTable

export RunHandle, RunPattern, Config
export set_config!, with_config, current_branch, find_runs
export to_storage, from_storage, write_jld2, read_jld2
export save_solution, save_result_item, load_result_item, move_result_item, delete_result_item, list_run
export write_object_file, read_object_file
export QueryShape, query_results, vault_connection

include("config.jl")     # AbstractConfig, Config, set_config!, with_config
include("runs.jl")       # RunHandle, RunPattern, globs
include("git.jl")        # current_branch, provenance
include("storage.jl")    # storage hooks and rules
include("items.jl")      # save_solution, save/load/move/delete_result_item, list_run, object files
include("discovery.jl")  # find_runs
include("query.jl")      # QueryShape, query_results, vault_connection

end # module
