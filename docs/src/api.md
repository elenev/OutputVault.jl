# API Reference

```@docs
OutputVault
```

## Runs and configuration

```@docs
RunHandle
RunPattern
current_branch
OutputVault.run_path
Config
OutputVault.AbstractConfig
OutputVault.output_root
OutputVault.table_format
OutputVault.native
OutputVault.staging_root
set_config!
with_config
OutputVault.global_config
```

## Saving and loading

```@docs
save_solution
save_result_item
load_result_item
move_result_item
delete_result_item
list_run
OutputVault.RunContents
find_runs
write_object_file
read_object_file
```

## Storage hooks

```@docs
to_storage
from_storage
write_jld2
read_jld2
```

## Querying

```@docs
QueryShape
query_results
vault_connection
OutputVault.sql_path
OutputVault.sql_statements
```

## Globs

```@docs
OutputVault.matches
OutputVault.glob_match
OutputVault.isglob
```

## Table formats

```@docs
OutputVault.Formats
OutputVault.Formats.AbstractTableFormat
OutputVault.Formats.ParquetFormat
OutputVault.Formats.StoredTable
OutputVault.Formats.extension
OutputVault.Formats.format_from_extension
OutputVault.Formats.write_table
OutputVault.Formats.read_table
Base.iswritable(::OutputVault.Formats.AbstractTableFormat)
OutputVault.Formats.RESERVED_PREFIX
OutputVault.Formats.table_metadata
OutputVault.Formats.atomic_write
```
