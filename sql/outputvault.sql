-- OutputVault: DuckDB macros over an output root.
--
-- Load this file into a DuckDB connection (OutputVault.vault_connection() does it in Julia), then
-- query with the output root of the project's configuration, for example
--   SELECT * FROM vault_runs('/path/to/output_root', branch_glob := '**');
--   SELECT * FROM vault_objects('/path/to/output_root', experdef_glob := 'v1') WHERE format = 'parquet';
--   SELECT * FROM vault_table_parquet(['/path/.../stats/uncond.parquet', ...]);
-- Statements are separated by ';' at the end of a line; clients that run one statement per call
-- run them one by one (OutputVault.sql_statements() returns them).
--
-- Layout: <root>/<branch>/res-<experdef>-<variant>/<item path>.<ext>. A branch with '/' is nested
-- folders, and none of its levels starts with 'res-', so the first level that does is the run.
-- experdef contains no '-', so the run folder splits at its first hyphen after 'res-'. Item paths
-- are levels without '.', so the extension is everything after the first '.' of the last level.
-- Names that start with '.' (staging and temporary files) are not runs or items. Paths are
-- normalized to '/' (Windows).
--
-- Globs: '*' matches within one level, '**' across levels (branch_glob := '**' includes nested
-- branches). DuckDB lists folders to expand a glob and opens only the files that match, so in a
-- synced folder with online-only files, narrow globs download only what is read.

-- a path relative to the root, with '/' separators
CREATE OR REPLACE MACRO vault_relpath(root, path) AS
    ltrim(replace(path, '\', '/')[length(rtrim(replace(root, '\', '/'), '/')) + 1:], '/');

-- the run and item of a file: branch, experdef, variant, path (the item path) and format (the
-- extension); empty strings if the file is not an item of a run
CREATE OR REPLACE MACRO vault_path_keys(root, path) AS
    regexp_extract(vault_relpath(root, path),
                   '^((?:[^./][^/]*/)*?[^./][^/]*)/res-([^-/]+)-([^/]+)/([^./][^/.]*(?:/[^./][^/.]*)*)\.([^/]+)$',
                   ['branch', 'experdef', 'variant', 'path', 'format']);

-- the saved runs (folders with a provenance record; in runs saved with OutputVault 0.3 it is in
-- solution/)
CREATE OR REPLACE MACRO vault_runs(root, branch_glob := '*', experdef_glob := '*', variant_glob := '*') AS TABLE
    SELECT DISTINCT k.branch, k.experdef, k.variant
    FROM (
        SELECT vault_path_keys(root, file) AS k
        FROM glob(root || '/' || branch_glob || '/res-' || experdef_glob || '-' || variant_glob || '/*/git_commit.txt')
    )
    WHERE k.branch <> '' AND k.path IN ('provenance/git_commit', 'solution/git_commit')
    ORDER BY ALL;

-- the items of the saved runs: one row per table or .jld2 file, with its run, item path, format
-- and file; the provenance and the native copy are not items
CREATE OR REPLACE MACRO vault_objects(root, branch_glob := '*', experdef_glob := '*', variant_glob := '*',
                                      path_glob := '**') AS TABLE
    SELECT k.branch, k.experdef, k.variant, k.path, k.format, file
    FROM (
        SELECT vault_path_keys(root, file) AS k, file
        FROM glob(root || '/' || branch_glob || '/res-' || experdef_glob || '-' || variant_glob || '/' || path_glob || '/*.*')
    )
    WHERE k.branch <> '' AND k.format NOT IN ('txt', 'diff') AND k.path NOT LIKE 'provenance/%'
          AND k.path <> 'native' AND k.path <> 'solution/res'
    ORDER BY ALL;

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
