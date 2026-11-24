using Documenter
using OutputVault
# the extensions' packages, so that their methods are loaded when the docs are built
using Parquet2, DuckDB, Tables, StaticArrays, StructArrays, TransitionFunctionIteration

# the walkthrough pages run their code in a throwaway git repository (see walkthroughs.jl)
include("walkthroughs.jl")
const WORKDIR = walkthrough_repo()

makedocs(
    sitename = "OutputVault.jl",
    workdir = WORKDIR,
    modules = [OutputVault],
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "guide/quickstart.md",
            "guide/lifecycle.md",
            "guide/concepts.md",
            "guide/saving_loading.md",
            "guide/tfi.md",
            "guide/tables.md",
            "guide/duckdb.md",
            "guide/extending.md",
        ],
        "API Reference" => "api.md",
    ],
)

deploydocs(
    repo = "github.com/elenev/OutputVault.jl.git",
)
