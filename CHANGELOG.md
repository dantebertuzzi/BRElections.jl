# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Several years at once: `elections`, the shortcuts and `campaign_finance`
  accept a range or vector of years (`candidates(2014:4:2022)`) and stack them
  with an `ano` column. All years are validated before any download. Columns
  present only in some years are `missing` in the others, columns whose type
  differs between years become text (numbers of different types are
  promoted), and columns renamed by the TSE are unified (`COLUMN_ALIASES`;
  `NM_EMAIL` → `DS_EMAIL`). Checked on real 2014/2018/2022 candidates: no
  column ends up as `Any`.

- Campaign finance, 2018 onward: `campaign_finance(year; table, filer)` returns
  candidates' or party bodies' revenue (also by original donor) and contracted
  or paid expenses. The eight tables are also `elections` types
  (`:candidate_revenue`, `:party_expenses_paid`, ...). The TSE packs four
  tables in each ZIP; only the requested one is extracted, and the ZIP is
  downloaded once for all of them. Earlier years are rejected with a pointer to
  the raw files, since each election before 2018 has its own layout.
- New datasets: `:candidates_complementary` (nationality, birthplace,
  re-election, spending cap…), `:candidate_social_media`, `:cassation_reasons`
  and `:voter_profile_section` (electorate profile by section, one ZIP per
  state), each with a shortcut function of the same name.
- `available_datasets()` has a `first_year` column, and asking for a dataset
  before its first year raises an `ArgumentError` instead of a 404.
  `available_files` skips datasets that did not exist yet in that year.

- `live_results(office; uf, municipality, election)`: vote counting straight
  from the TSE's results system (`resultados.tse.jus.br`), updated every few
  minutes on election night and never cached. Covers every office, from
  president to councillor, for Brazil, a state, a municipality (by name, TSE or
  IBGE code) or abroad. The election is picked automatically: the latest one
  already held that has the office and covers the place, which handles runoffs
  and supplementary elections. Returns one row per candidate; the count summary
  (polling stations counted, turnout, valid/blank/null votes, update time) is in
  the `DataFrame` metadata.
- `examples/live_results.jl`: a terminal dashboard for election night, built on
  `live_results` and PrettyTables, with `--watch` to refresh it.

- `municipalities()`: crosswalk between the TSE municipality code
  (`cd_municipio`, used in every TSE file) and the IBGE code, with name, state,
  capital flag and electoral zones. It comes from the TSE's results system
  (`resultados.tse.jus.br`) for the latest general election, which covers every
  municipality (Brasília and Fernando de Noronha included, unlike municipal
  elections) and the cities abroad. Cached and revalidated like the other files.
  Adds JSON.jl as a dependency.

- Cache revalidation. The TSE regenerates its files often, past elections
  included, without changing their URLs, and a cached ZIP used to be reused
  forever. Each download now stores the file's `ETag`, `Last-Modified` and
  `Content-Length` in `<zip>.meta`; on later calls a `HEAD` request checks
  whether the TSE published a new version and downloads it only then. Without
  network access the cached copy is used, with a warning. Caches created by
  earlier versions (no `.meta`) are checked by `Last-Modified`. The new
  `check_updates = false` keyword skips the check.

### Changed

- Cache revalidation runs at most once an hour per file instead of on every
  call: the `HEAD` request cost ~0.3 s against ~0.001 s for a cached read. The
  `.meta` file's mtime marks the last successful check (a failed one doesn't
  count). Configurable with `BRElections_REVALIDATE_HOURS` or
  `BRElections.REVALIDATE_INTERVAL[]`.
- ZIP extraction is ~5× faster and runs in constant memory. Entries are copied
  in 8 MB blocks instead of being read whole, and Latin-1 → UTF-8 conversion is
  done in plain Julia instead of iconv (10× faster, identical output). For the
  1.2 GB `votacao_candidato_munzona_2022_SP.csv`: 11.8 s and 12.9 GB allocated
  before, 2.3 s and 142 MB now. Large files (campaign finance tables reach
  2.5 GB) no longer risk running out of memory. StringEncodings is no longer a
  dependency (it stays as a test-only reference for the converter).
- With `filter`, files that fit comfortably in free memory are read whole and
  then filtered, which is faster than `CSV.Chunks` (0.9 s vs 2.5 s on a 93 MB
  file); chunked reading is kept for files that don't fit.
- DataFrames compat raised to 1.4, the first version with metadata, used by
  `live_results`. Adds the `Unicode` stdlib as a dependency.
- The `filter` predicate accepts column names in either case: `row.nr_turno`,
  matching the returned `DataFrame`, or `row.NR_TURNO`, matching the TSE file.
  Before, only the uppercase names worked, even though the result comes with
  lowercase names. Examples in the docs now use the lowercase names.

### Fixed

- Money columns (`vr_*`) written with a decimal comma (`"1500,00"`) were read
  as `String`, e.g. `vr_bem_candidato` in `assets`. They are now `Float64`.
  The TSE uses a decimal point in some files, so the conversion is per column
  and accepts either; a column with any non-numeric value is left as text.

- CSVs extracted from an older version of a ZIP are re-extracted when the ZIP
  is updated, instead of being reused.
- Reading small files no longer logs a spurious `Falha ao dividir arquivo em
  chunks` warning (nor CSV.jl's `ntasks > 1` warning): files under 64 MiB are
  filtered in memory, and files under 1 MiB are parsed with a single task.
- An `ArgumentError` thrown by the user's `filter` predicate is propagated
  instead of being mistaken for a chunking failure and silently retried.

## [0.1.1] - 2026-08-31

### Added

- `CITATION.cff`, so GitHub renders the "Cite this repository" button with
  ready APA and BibTeX, and a "How to cite" section in the README asking that
  the software and the TSE data be cited separately.
- `.zenodo.json`, which sets the title, author, MIT license and keywords of the
  Zenodo deposit instead of letting them be inferred from the repository. The
  repository is now connected to Zenodo: from this release on, every tag is
  archived and gets a persistent DOI, plus a concept DOI that always resolves
  to the newest version: [10.5281/zenodo.22182707](https://doi.org/10.5281/zenodo.22182707)
  for the project, [10.5281/zenodo.22182708](https://doi.org/10.5281/zenodo.22182708)
  for this version.

## [0.1.0] - 2026-08-24

First public release.

### Added

- Typed access to ten TSE open datasets, through a generic `elections(year;
  type = ...)` entry point plus one convenience function per dataset:
  `candidates`, `candidate_votes`, `party_votes`, `vote_details`,
  `section_votes`, `section_vote_details`, `assets`, `coalitions`,
  `vacancies` and `voter_profile`.
- Automatic download of TSE ZIP files with retries, exponential backoff and
  atomic writes (a `.part` file is only moved into place once complete).
- Portable local cache (Windows/Linux/macOS) built on Scratch.jl, configurable
  through the `BRElections_CACHE` environment variable or at runtime with
  `set_cache_dir!`; `cache_dir` and `clear_cache!` round out the interface.
- Discovery of what the TSE has actually published for a given year, with
  `available_datasets` and `available_files`.
- ZIP extraction with on-the-fly ISO-8859-1 → UTF-8 transcoding, skipping
  files the request will not use.
- Efficient reading of large CSVs via CSV.jl, multithreaded and chunk-based,
  with `columns` and `filter` applied during import so that non-matching rows
  never reach memory.
- Type conversion tuned to TSE conventions: `dd/mm/yyyy` strings become
  `Date`, the `#NULO#` and `#NE#` sentinels become `missing`, and identifier
  columns (`NR_CPF_*`, `NR_TITULO_*`, `NR_PROCESSO`, `NR_PROTOCOLO`) stay
  `String` so leading zeros survive.
- Optional column name normalisation to lowercase (`normalize_names`).
- Test suite that runs offline by default against synthetic fixtures, with
  network smoke tests against the TSE CDN behind `BRElections_TEST_NETWORK`.

[Unreleased]: https://github.com/dantebertuzzi/BRElections.jl/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/dantebertuzzi/BRElections.jl/releases/tag/v0.1.1
[0.1.0]: https://github.com/dantebertuzzi/BRElections.jl/releases/tag/v0.1.0
