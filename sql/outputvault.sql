-- OutputVault: DuckDB interface to an output root.
--
-- Load this file into a DuckDB connection, then query the table macros with the output root
-- (the `output_root` of the project's OutputVault Config), for example
--   SELECT * FROM vault_stats('/path/to/output_root', experdef_glob := 'v1') WHERE economy = 'base';
-- Statements are separated by ';' at the end of a line; clients that run one statement per call
-- (DuckDB.jl) run them one by one (OutputVault.duckdb_statements() returns them).
--
-- Layout read: <root>/<branch>/res-<experdef>-<economy>/<component>/<file>.parquet (a branch
-- with '/' is nested folders; its name is everything between the root and res-).
-- experdef contains no '-' (RunHandle enforces it), so the folder name splits at the first hyphen
-- after "res-"; economy may contain anything. Paths are normalized to '/' (Windows).
--
-- Macros (each also takes the economy split and the glob filters, see below):
--   long form throughout; stat is the statistic's name and value a DOUBLE
--   vault_stats(root)       moments by sample: branch, experdef, economy, sample, variable, stat, value
--   vault_errstats(root)    error statistics:  branch, experdef, economy, equation, stat, value
--   vault_params(root)      model parameters:  branch, experdef, economy, parameter, value
--   vault_irf(root)         impulse responses: branch, experdef, economy, shock, stat, period, variable, value
--   vault_simulation(root)  simulation panels: branch, experdef, economy, then the panel's columns
--   vault_runs(root)        saved runs:        branch, experdef, economy
--
-- Filtering files: every macro takes the named arguments branch_glob and experdef_glob (glob
-- patterns, default '**' and '*'), which narrow the files that are read, so that only matching runs
-- are opened (this matters when the root is a synced folder with online-only files),
--   SELECT * FROM vault_stats('/root', branch_glob := 'main', experdef_glob := 'v1');
-- vault_stats, vault_errstats, vault_params, vault_irf and vault_simulation also take economies, a
-- list of economy glob patterns (default ['*']); each pattern must match a saved component of some
-- run, or DuckDB reports that no files match,
--   SELECT * FROM vault_stats('/root', economies := ['base', 'alt']);
--
-- Splitting economy: pass the globs (all five arguments are then positional) and a regex with one
-- capture group per part and the names of the parts,
--   SELECT * FROM vault_stats('/root', '**', '*', '^([^_]+)(?:_(.+))?$', ['model', 'scheme']);
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

-- a moment table (a column of row names plus one column per statistic) in long form, with its file
-- keys. TFI's MomentArray names its column of row names itself: `variable` in statistics, `equation`
-- in error statistics, `parameter` in parameters (one macro each, since the column is named in SQL).
CREATE OR REPLACE MACRO vault_moments_long(root, pattern) AS TABLE
    WITH long AS (
        UNPIVOT (SELECT * FROM read_parquet(pattern, filename = true, union_by_name = true))
        ON COLUMNS(* EXCLUDE (variable, filename))
        INTO NAME stat VALUE value
    )
    SELECT vault_path_keys(root, filename) AS k, variable, stat, CAST(value AS DOUBLE) AS value
    FROM long;

CREATE OR REPLACE MACRO vault_equations_long(root, pattern) AS TABLE
    WITH long AS (
        UNPIVOT (SELECT * FROM read_parquet(pattern, filename = true, union_by_name = true))
        ON COLUMNS(* EXCLUDE (equation, filename))
        INTO NAME stat VALUE value
    )
    SELECT vault_path_keys(root, filename) AS k, equation, stat, CAST(value AS DOUBLE) AS value
    FROM long;

CREATE OR REPLACE MACRO vault_parameters_long(root, pattern) AS TABLE
    WITH long AS (
        UNPIVOT (SELECT * FROM read_parquet(pattern, filename = true, union_by_name = true))
        ON COLUMNS(* EXCLUDE (parameter, filename))
        INTO NAME stat VALUE value
    )
    SELECT vault_path_keys(root, filename) AS k, parameter, stat, CAST(value AS DOUBLE) AS value
    FROM long;

-- a simulation panel with its file keys
CREATE OR REPLACE MACRO vault_panel(root, pattern) AS TABLE
    SELECT vault_path_keys(root, filename) AS k, * EXCLUDE (filename)
    FROM read_parquet(pattern, filename = true, union_by_name = true);

-- impulse responses (__shock, __stat, __period plus one column per variable) in long form
CREATE OR REPLACE MACRO vault_irf_long(root, pattern) AS TABLE
    WITH long AS (
        UNPIVOT (SELECT * FROM read_parquet(pattern, filename = true, union_by_name = true))
        ON COLUMNS(* EXCLUDE (__shock, __stat, __period, filename))
        INTO NAME variable VALUE value
    )
    SELECT vault_path_keys(root, filename) AS k, __shock AS shock, __stat AS stat, __period AS period,
           variable, CAST(value AS DOUBLE) AS value
    FROM long;

-- the glob of a component's files: `files` is the path below the run's folder
CREATE OR REPLACE MACRO vault_glob(root, branch_glob, experdef_glob, files) AS
    root || '/' || branch_glob || '/res-' || experdef_glob || '-*/' || files;

-- the globs of a component's files for a list of economy patterns (read_parquet takes a list)
CREATE OR REPLACE MACRO vault_globs(root, branch_glob, experdef_glob, economies, files) AS
    list_transform(economies, lambda e: root || '/' || branch_glob || '/res-' || experdef_glob || '-' || e || '/' || files);

-- the runs under a root, from their solution folders
CREATE OR REPLACE MACRO vault_run_keys(root, branch_glob, experdef_glob) AS TABLE
    SELECT DISTINCT regexp_extract(vault_relpath(root, file),
                                   '^(.+)/res-([^-/]+)-([^/]+)/solution/[^/]+$',
                                   ['branch', 'experdef', 'economy']) AS k
    FROM glob(vault_glob(root, branch_glob, experdef_glob, 'solution/*'));

CREATE OR REPLACE MACRO vault_stats
    (root, branch_glob := '**', experdef_glob := '*', economies := ['*']) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, k.file AS sample, variable, stat, value
        FROM vault_moments_long(root, vault_globs(root, branch_glob, experdef_glob, economies, 'stats/*.parquet'))
    ),
    (root, branch_glob, experdef_glob, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, UNNEST(regexp_extract(k.economy, economy_regex, economy_names)), k.file AS sample, variable, stat, value
        FROM vault_moments_long(root, vault_globs(root, branch_glob, experdef_glob, ['*'], 'stats/*.parquet'))
    );

CREATE OR REPLACE MACRO vault_errstats
    (root, branch_glob := '**', experdef_glob := '*', economies := ['*']) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, equation, stat, value
        FROM vault_equations_long(root, vault_globs(root, branch_glob, experdef_glob, economies, 'errstats/errstats.parquet'))
    ),
    (root, branch_glob, experdef_glob, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, UNNEST(regexp_extract(k.economy, economy_regex, economy_names)), equation, stat, value
        FROM vault_equations_long(root, vault_globs(root, branch_glob, experdef_glob, ['*'], 'errstats/errstats.parquet'))
    );

CREATE OR REPLACE MACRO vault_params
    (root, branch_glob := '**', experdef_glob := '*', economies := ['*']) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, parameter, value
        FROM vault_parameters_long(root, vault_globs(root, branch_glob, experdef_glob, economies, 'params/params.parquet'))
    ),
    (root, branch_glob, experdef_glob, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, UNNEST(regexp_extract(k.economy, economy_regex, economy_names)), parameter, value
        FROM vault_parameters_long(root, vault_globs(root, branch_glob, experdef_glob, ['*'], 'params/params.parquet'))
    );

CREATE OR REPLACE MACRO vault_irf
    (root, branch_glob := '**', experdef_glob := '*', economies := ['*']) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, shock, stat, period, variable, value
        FROM vault_irf_long(root, vault_globs(root, branch_glob, experdef_glob, economies, 'irf/irf.parquet'))
    ),
    (root, branch_glob, experdef_glob, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, UNNEST(regexp_extract(k.economy, economy_regex, economy_names)), shock, stat, period, variable, value
        FROM vault_irf_long(root, vault_globs(root, branch_glob, experdef_glob, ['*'], 'irf/irf.parquet'))
    );

CREATE OR REPLACE MACRO vault_simulation
    (root, branch_glob := '**', experdef_glob := '*', economies := ['*']) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, * EXCLUDE (k)
        FROM vault_panel(root, vault_globs(root, branch_glob, experdef_glob, economies, 'simulation/simseries.parquet'))
    ),
    (root, branch_glob, experdef_glob, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, UNNEST(regexp_extract(k.economy, economy_regex, economy_names)), * EXCLUDE (k)
        FROM vault_panel(root, vault_globs(root, branch_glob, experdef_glob, ['*'], 'simulation/simseries.parquet'))
    );

CREATE OR REPLACE MACRO vault_runs
    (root, branch_glob := '**', experdef_glob := '*') AS TABLE (
        SELECT k.branch, k.experdef, k.economy FROM vault_run_keys(root, branch_glob, experdef_glob)
    ),
    (root, branch_glob, experdef_glob, economy_regex, economy_names) AS TABLE (
        SELECT k.branch, k.experdef, k.economy, UNNEST(regexp_extract(k.economy, economy_regex, economy_names))
        FROM vault_run_keys(root, branch_glob, experdef_glob)
    );
