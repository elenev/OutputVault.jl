module OutputVault

using LibGit2
using JLD2
using FileIO
using Glob

export RunHandle, Config
export set_config!, with_config
export output_path
export save_result
export find_matching_results, get_results_folders
export load  # re-exports FileIO.load (extended below)

include("git.jl")        # current_branch, is_repo_clean, get_commit_id
include("types.jl")      # RunHandle, AbstractConfig, Config
include("global_config.jl")  # set_config!, global_config, with_config
include("filesystem.jl") # output_path, economy_folder
include("save_load.jl")  # FileIO.load, save_result
include("discovery.jl")  # find_matching_results, get_results_folders

end # module
