# OutputVault.Formats: self-contained, so these tests use only Formats, Tables, DataAPI and Parquet2.
using OutputVault.Formats
using OutputVault.Formats: StoredTable
using Tables, DataAPI, Dates, Parquet2

# a table type with its own file-level metadata
struct MetaTable
    cols::NamedTuple
end
Tables.istable(::Type{MetaTable}) = true
Tables.columnaccess(::Type{MetaTable}) = true
Tables.columns(t::MetaTable) = t.cols
DataAPI.metadatasupport(::Type{MetaTable}) = (read = true, write = false)
DataAPI.metadatakeys(::MetaTable) = ("source", "version")
DataAPI.metadata(::MetaTable, k::AbstractString; style = false) = k == "source" ? "model" : 2

struct UnloadedFormat <: AbstractTableFormat end
OutputVault.Formats.format_package(::Type{UnloadedFormat}) = "SomeIOPackage"

@testset "Formats" begin
    fmt = ParquetFormat()
    @test extension(fmt) == "parquet"
    @test format_from_extension(Val(:parquet)) === fmt
    @test isnothing(format_from_extension(Val(:txt)))
    @test iswritable(fmt)

    @testset "column types round-trip" begin
        with_tempdir() do dir
            path = joinpath(dir, "t.parquet")
            t = (f = [1.0, NaN], i = [1, 2], b = [true, false], s = ["a", "b"], y = [:x, :y],
                 d = [Date(2020, 1, 1), Date(2021, 2, 3)], m = [1.5, missing], f32 = Float32[1, 2],
                 i32 = Int32[3, 4], i8 = Int8[5, 6], ym = [:x, missing], dt = [DateTime(2020, 1, 1, 12), DateTime(2020, 1, 2)])
            write_table(fmt, path, t)
            r = read_table(fmt, path)
            @test r isa StoredTable
            @test Tables.istable(r)
            c = Tables.columns(r)
            for k in keys(t)
                @test isequal(Tables.getcolumn(c, k), t[k])
                @test nonmissingtype(eltype(Tables.getcolumn(c, k))) == nonmissingtype(eltype(t[k]))
            end
            @test eltype(c.y) == Symbol
            @test eltype(c.s) == String
            @test isempty(DataAPI.metadatakeys(r))       # the Symbol-column entry is internal
            @test !any(startswith(".tmp"), readdir(dir)) && readdir(dir) == ["t.parquet"]
        end
    end

    @testset "metadata" begin
        with_tempdir() do dir
            path = joinpath(dir, "m.parquet")
            write_table(fmt, path, MetaTable((a = [1, 2],)); metadata = Dict("extra" => "1", "version" => "3"))
            r = read_table(fmt, path)
            @test DataAPI.metadata(r, "source") == "model"
            @test DataAPI.metadata(r, "version") == "3"            # the argument wins
            @test DataAPI.metadata(r, "extra") == "1"
            @test DataAPI.metadata(r, "absent", nothing) === nothing
            @test Set(DataAPI.metadatakeys(r)) == Set(["source", "version", "extra"])
        end
    end

    @testset "unsupported columns and reserved metadata" begin
        with_tempdir() do dir
            path = joinpath(dir, "u.parquet")
            @test_throws Exception write_table(fmt, path, (a = [1 + 2im],))
            @test readdir(dir) == []
            @test_throws ArgumentError write_table(fmt, path, (a = [1],); metadata = Dict("outputvault.x" => "1"))
            @test readdir(dir) == []
        end
    end

    @testset "replacing a file" begin
        with_tempdir() do dir
            path = joinpath(dir, "r.parquet")
            write_table(fmt, path, (a = [1],))
            write_table(fmt, path, (b = [2.0, 3.0],))
            @test Tables.columnnames(Tables.columns(read_table(fmt, path))) == (:b,)
        end
    end

    @testset "missing package hint" begin
        msg = sprint(showerror, try write_table(UnloadedFormat(), "p", (a = [1],)); nothing catch e; e end)
        @test occursin("UnloadedFormat needs its package: `using SomeIOPackage`.", msg)
        msg = sprint(showerror, try read_table(UnloadedFormat(), "p"); nothing catch e; e end)
        @test occursin("`using SomeIOPackage`", msg)
    end
end
