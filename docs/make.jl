using Documenter
using OutputVault
# the extension's package, so that its methods are loaded when the docs are built
using Parquet2

# the walkthrough pages run their code in a throwaway git repository, made the active project so
# that saved solutions record its commit (see walkthroughs.jl)
include("walkthroughs.jl")
const WORKDIR = walkthrough_repo()
activate_walkthrough(WORKDIR)

makedocs(
    sitename = "OutputVault.jl",
    workdir = WORKDIR,
    modules = [OutputVault],
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "guide/quickstart.md",
            "guide/concepts.md",
            "guide/saving_loading.md",
            "guide/tables.md",
            "guide/queries.md",
        ],
        "Extending" => [
            "guide/frontends.md",
            "guide/adding_formats.md",
        ],
        "API Reference" => "api.md",
    ],
)

deploydocs(
    repo = "github.com/elenev/OutputVault.jl.git",
)
