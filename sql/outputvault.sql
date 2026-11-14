-- OutputVault: DuckDB interface to an output root.
--
-- Load this file into a DuckDB connection, then query the table macros with the output root
-- (the `output_root` of the project's OutputVault Config), for example
--   SELECT * FROM vault_stats('/path/to/output_root') WHERE economy = 'frm';
-- Statements are separated by ';' at the end of a line; clients that run one statement per call
-- (DuckDB.jl) run them one by one (OutputVault.duckdb_statements() returns them).
--
-- Layout read: <root>/<branch>/res-<experdef>-<economy>/<component>/<file>.parquet (a branch
-- with '/' is nested folders; its name is everything between the root and res-).
-- experdef contains no '-' (RunHandle enforces it), so the folder name splits at the first hyphen
-- after "res-"; economy may contain anything. Paths are normalized to '/' (Windows).
--
-- Macros (each also takes economy_regex and economy_names, see below):
--   long form throughout; stat is the statistic's name and value a DOUBLE
--   vault_stats(root)       moments by sample: branch, experdef, economy, sample, variable, stat, value
--   vault_errstats(root)    error statistics:  branch, experdef, economy, variable, stat, value
--   vault_simulation(root)  simulation panels: branch, experdef, economy, then the panel's columns
--   vault_runs(root)        saved runs:        branch, experdef, economy
--
-- Splitting economy: pass a regex with one capture group per part and the names of the parts
-- (positional arguments),
--   SELECT * FROM vault_stats('/root', '^([^_]+)(?:_(.+))?$', ['model', 'scheme']);
-- adds the columns model and scheme after economy ('' where a group or the regex does not match).
-- OutputVault imposes no naming convention on economy; the regex is the project's.

-- a path relative to the root, with '/' separators
CREATE OR REPLACE MACRO vault_relpath(root, path) AS
    ltrim(replace(path, '\', '/')[length(rtrim(replace(root, '\', '/'), '/')) + 1:], '/');

-- run identity and file stem of a parquet file path; branch is everything above res-..., so
-- branches with '/' (nested folders) keep their full name
CREATE OR REPLACE MACRO vault_path_keys(root, path) AS
    regexp_extract(vault_relpath(root, path),
                   '^(.+)/res-([^-/]+)-([^/]+)/[^/]+/([^/]+)\.parquet$',
                   ['branch', 'experdef', 'economy', 'file']);

-- a moment table (__row plus one column per statistic) in long form, with its file keys
CREATE OR REPLACE MACRO vault_moments_long(root, pattern) AS TABLE
    WITH long AS (
        UNPIVOT (SELECT * FROM read_parquet(pattern, filename = true, union_by_name = true))
        ON COLUMNS(* EXCLUDE (__row, filename))
        INTO NAME stat VALUE value
    )
    SELECT vault_path_keys(root, filename) AS k, __row AS variable, stat, CAST(value AS DOUBLE) AS value
    FROM long;

-- a simulation panel with its file keys
CREATE OR REPLACE MACRO vault_panel(root, pattern) AS TABLE
    SELECT vault_path_keys(root, filename) AS k, * EXCLUDE (filename)
    FROM read_parquet(pattern, filename = true, union_by_name = true);

-- the runs under a root, from their solution folders
CREATE OR REPLACE MACRO vault_run_keys(root) AS TABLE
    SELECT DISTINCT regexp_extract(vault_relpath(root, file),
                                   '^(.+)/res-([^-/]+)-([^/]+)/solution/[^/]+$',
                                   ['branch', 'experdef', 'economy']) AS k
    FROM glob(root || '/**/res-*/solution/*');

CREATE OR REPLACE MACRO vault_stats
    (root) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, k.file AS sample, variable, stat, value
        FROM vault_moments_long(root, root || '/**/res-*/stats/*.parquet')
    ),
    (root, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy,
               UNNEST(regexp_extract(k.economy, economy_regex, economy_names)),
               k.file AS sample, variable, stat, value
        FROM vault_moments_long(root, root || '/**/res-*/stats/*.parquet')
    );

CREATE OR REPLACE MACRO vault_errstats
    (root) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, variable, stat, value
        FROM vault_moments_long(root, root || '/**/res-*/errstats/errstats.parquet')
    ),
    (root, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy,
               UNNEST(regexp_extract(k.economy, economy_regex, economy_names)),
               variable, stat, value
        FROM vault_moments_long(root, root || '/**/res-*/errstats/errstats.parquet')
    );

CREATE OR REPLACE MACRO vault_simulation
    (root) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, * EXCLUDE (k)
        FROM vault_panel(root, root || '/**/res-*/simulation/simseries.parquet')
    ),
    (root, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy,
               UNNEST(regexp_extract(k.economy, economy_regex, economy_names)), * EXCLUDE (k)
        FROM vault_panel(root, root || '/**/res-*/simulation/simseries.parquet')
    );

CREATE OR REPLACE MACRO vault_runs
    (root) AS TABLE (
        SELECT k.branch, k.experdef, k.economy FROM vault_run_keys(root)
    ),
    (root, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy,
               UNNEST(regexp_extract(k.economy, economy_regex, economy_names))
        FROM vault_run_keys(root)
    );
