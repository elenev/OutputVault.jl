# Runs and the Layout

## What a run is

A *run* is the saved results of one economy: one solved model with its simulation and statistics. It
is identified by three names, held in a [`RunHandle`](@ref):

| Field | Meaning | Default |
|:--|:--|:--|
| `branch` | the git branch of the code that produced it | the current branch of the working directory |
| `experdef` | the experiment definition: a named set of economies (calibration, version of the model) | `"default"` |
| `economy` | the economy within the experiment, e.g. `base` or `alt` | required |

```julia
rf = RunHandle("base"; experdef = "v1")      # branch: current_branch()
rf = RunHandle("base"; experdef = "v1", branch = "feature-x")
```

A run lives in a folder of the project's output root:

```
<output_root>/<branch>/res-<experdef>-<economy>/
```

`experdef` must not contain `-`, because readers split the folder name at the first hyphen after
`res-`; `economy` may contain anything (including hyphens). A branch with a `/` (`feature/x`) is a
nested folder. The names can be anything else: OutputVault imposes no convention on economy names, and
the DuckDB macros can split them into parts with a regular expression
([Querying with DuckDB](@ref)).

## Components and objects

Inside the run folder, results are grouped into *components*, one folder each, with one file per
*object* (property). Where each object goes is fixed for every project and every user of
OutputVault, so that tools can find an object in any run. [`LAYOUT`](@ref) is the table:

| Component | Objects | Holds |
|:--|:--|:--|
| `solution` | `obj`, `stv` | the solved model and its steady state; the git commit and diffs |
| `stats` | `stats` | moments of the simulation; one table per sample, `stats/<sample>.<ext>` |
| `errstats` | `errstats` | equation-error statistics |
| `simulation` | `simseries`, `errs` | the simulated panel and its equation errors |
| `irf` | `irf` | impulse responses (statistics and raw paths) |
| `params` | `params` | the model's scalar parameters |
| `recursions` | `claims`, `welfare` | interpolants computed at the solution's policies |

```
res-v1-base/
├── solution/     obj.jld2  stv.jld2  res.jld2  git_commit.txt  [git_staged.diff  git_unstaged.diff]
├── stats/        uncond.parquet
├── errstats/     errstats.parquet
├── simulation/   simseries.parquet  errs.parquet
├── irf/          irf.parquet  irf_paths.parquet
├── params/       params.parquet
└── recursions/   claims.jld2  welfare.jld2
```

Which objects a run has is the caller's choice: each [`save_result`](@ref) saves the objects it is
given, so a run can be built in steps (the recursions are often computed after the simulation).

## One folder, one solution

The `solution` component is special. A save that includes `obj` or `stv` first deletes the whole run
folder, then writes the new solution, so everything in a run folder was computed from the solution
in it. Saves without solution objects add to the folder, and replace an object saved before.
The reasons are practical: stale diffs and simulations next to a new solution are the usual way to
mislead yourself about which results belong to which code.

## Provenance

The solution folder records the code:

- `git_commit.txt`: the commit id of the repository in the working directory;
- if the repository is dirty, `git_staged.diff` and `git_unstaged.diff` (the latter including
  untracked files), unless a diff exceeds 1 MB. The diffs are computed without touching the
  repository's index.

[`save_result`](@ref) warns about a dirty repository by default, or fails with
`dirty_repo_check = :error`. TFI's simulations and IRFs record in their own metadata the id of the
solution they were computed from, so a simulation can be traced to its solution.

## Two copies of the solution

The solution is saved twice by default (`solution_format = (:portable, :native)`):

- **portable**: one file per object (`obj.jld2`, `stv.jld2`) in a documented layout of plain arrays
  and metadata, readable without the code that wrote it. This is the copy for long-term storage,
  for other languages and for loading with a rebuilt model ([TransitionFunctionIteration Objects](@ref)).
- **native**: `res.jld2`, the objects exactly as they are in Julia. Quick to load, but it needs code
  compatible with the code that wrote it, so it is meant for work done soon after the solve.

Every other component is always portable.
