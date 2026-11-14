module OutputVault

using LibGit2
using JLD2
using FileIO
using Glob
using DataAPI: DataAPI

export RunHandle, Config, TableFormat, LAYOUT
export set_config!, with_config
export output_path
export save_result
export save_solution, load_solution, save_steadystate, load_steadystate
export model_metadata, model_from_metadata
export find_matching_results, get_results_folders
export duckdb_sql_path, duckdb_statements
export load  # re-exports FileIO.load (extended below)

include("git.jl")        # current_branch, is_repo_clean, get_commit_id
include("types.jl")      # RunHandle, LAYOUT, table formats (Formats), AbstractConfig, Config
include("global_config.jl")  # set_config!, global_config, with_config
include("filesystem.jl") # output_path, economy_folder
include("save_load.jl")  # FileIO.load, save_result
include("discovery.jl")
include("duckdb.jl")     # duckdb_sql_path, duckdb_statements  # find_matching_results, get_results_folders

end # module
