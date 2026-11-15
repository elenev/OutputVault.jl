# API Reference

## Runs and configuration

```@docs
RunHandle
Config
LAYOUT
set_config!
with_config
output_path
```

## Saving and loading

```@docs
save_result
load
save_solution
load_solution
save_steadystate
load_steadystate
```

## Finding runs

```@docs
find_matching_results
get_results_folders
```

## Model hooks

```@docs
model_metadata
model_from_metadata
collect_parameters
```

## Table formats

```@docs
OutputVault.AbstractTableFormat
OutputVault.Formats
OutputVault.Formats.ParquetFormat
TableFormat
OutputVault.table_extension
```

## The producer interface

For extensions that store the types of a package ([Writing an Extension](@ref)).

```@docs
OutputVault.storage_kind
OutputVault.write_object
OutputVault.write_table
OutputVault.write_table_parts
OutputVault.jld2_record
OutputVault.recorded_kind
OutputVault.read_kind
```

## DuckDB

```@docs
duckdb_sql_path
duckdb_statements
assemble_moments
```
