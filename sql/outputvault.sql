-- OutputVault: DuckDB macros over table files of an output root.
--
-- Load this file into a DuckDB connection (OutputVault.vault_connection() does it in Julia). The
-- macros take a list of files; finding the files of runs is done by the caller (in Julia,
-- find_runs and list_run), for example
--   SELECT * FROM vault_table_parquet(['/path/.../stats/uncond.parquet', ...]);
-- Statements are separated by ';' at the end of a line; clients that run one statement per call
-- run them one by one (OutputVault.sql_statements() returns them).

-- the tables of a list of Parquet files, combined by column name, with the file (__file) and the
-- row's position in it (__row, from 0)
CREATE OR REPLACE MACRO vault_table_parquet(files) AS TABLE
    SELECT * EXCLUDE (file_row_number), file_row_number AS __row
    FROM read_parquet(files, filename = '__file', union_by_name = true, file_row_number = true);

-- the file-level metadata of a list of Parquet files: one row per file and key
CREATE OR REPLACE MACRO vault_metadata_parquet(files) AS TABLE
    SELECT file_name AS file, decode(key) AS key, decode(value) AS value
    FROM parquet_kv_metadata(files)
    WHERE decode(key) <> 'outputvault.symbol_columns';

-- the variant split into named parts by a regex with one capture group per part, as a struct
-- (UNNEST it for columns), e.g. vault_split_variant(variant, '^([a-z]+)(\d*)$', ['scheme', 'level']);
-- '' where a group or the regex does not match. OutputVault imposes no naming convention.
CREATE OR REPLACE MACRO vault_split_variant(variant, regex, names) AS
    regexp_extract(variant, regex, names);
