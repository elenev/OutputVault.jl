# A tiny frontend that is not TFI: its types describe their storage, OutputVault does the I/O.
module TinyFrontend

using OutputVault, Tables, DataAPI
import OutputVault: to_storage, from_storage, write_jld2, read_jld2

# a panel: a table with a label kept in the file metadata
struct Panel
    label::String
    t::Vector{Int}
    y::Vector{Float64}
end
Tables.istable(::Type{Panel}) = true
Tables.columnaccess(::Type{Panel}) = true
Tables.columns(p::Panel) = (t = p.t, y = p.y)
DataAPI.metadatasupport(::Type{Panel}) = (read = true, write = false)
DataAPI.metadatakeys(::Panel) = ("label",)
DataAPI.metadata(p::Panel, ::AbstractString; style = false) = p.label
from_storage(::Type{Panel}, data; context = nothing) = Panel(DataAPI.metadata(data, "label"), Tables.columns(data).t, Tables.columns(data).y)

# an economy: parameters (a one-row table), a panel and settings with strings and booleans
struct Economy
    params::NamedTuple{(:beta, :sigma), Tuple{Float64, Float64}}
    panel::Panel
    distro::String
    mit::Bool
end
to_storage(e::Economy) = (params = (beta = [e.params.beta], sigma = [e.params.sigma]), panel = e.panel,
                          settings = (; e.distro, e.mit))
function from_storage(::Type{Economy}, data; context = nothing)
    params = Tables.columns(data.params)
    return Economy((beta = only(params.beta), sigma = only(params.sigma)),
                   from_storage(Panel, data.panel), data.settings.distro["value"], data.settings.mit["value"])
end

# a solution with a portable layout inside its .jld2 file; the model comes from `context`
struct Solution
    model::Symbol
    coefs::Vector{Float64}
end
function write_jld2(io, s::Solution)
    io["coefs"] = s.coefs
    io["model_name"] = string(s.model)
end
function read_jld2(::Type{Solution}, io; context = nothing)
    if string(context) != io["model_name"]
        error("the solution was saved for $(io["model_name"])")
    end
    return Solution(context, io["coefs"])
end

end # module

@testset "a frontend that is not TFI" begin
    T = TinyFrontend
    rf = RunHandle("calib"; branch = "main", experdef = "e20260125")
    panel = T.Panel("baseline", [1, 2, 3], [0.1, 0.2, 0.3])
    econ = T.Economy((beta = 0.99, sigma = 2.0), panel, "Beta", true)
    with_vault() do root, repo
        dir = save_solution(rf, (; obj = T.Solution(:dsge, [1.0, 2.0])))
        @test haskey(JLD2.load(joinpath(dir, "solution", "obj.jld2")), "coefs")      # the portable layout
        @test load_result_item(rf, "solution/obj", T.Solution; context = :dsge).coefs == [1.0, 2.0]
        @test_throws ErrorException load_result_item(rf, "solution/obj", T.Solution; context = :other)
        @test load_result_item(rf, "solution"; native = true).obj.coefs == [1.0, 2.0]

        save_result_item(rf, "panel", panel)
        save_result_item(rf, "economy", econ)
        @test isfile(joinpath(dir, "panel.parquet"))
        @test isfile(joinpath(dir, "economy", "params.parquet")) && isfile(joinpath(dir, "economy", "settings", "mit.jld2"))
        p = load_result_item(rf, "panel", T.Panel)
        @test (p.label, p.t, p.y) == ("baseline", [1, 2, 3], [0.1, 0.2, 0.3])
        e = load_result_item(rf, "economy", T.Economy)
        @test e.params == econ.params && e.distro == "Beta" && e.mit === true && e.panel.y == panel.y

        path = joinpath(root, "solution.jld2")
        write_object_file(path, T.Solution(:dsge, [3.0]))
        @test read_object_file(path, T.Solution; context = :dsge).coefs == [3.0]
    end
end
