# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Provenance metadata on every `DataFrame` returned by `elections` and its
  shortcuts: `metadata(df, "fontes")` records, per TSE ZIP, the URL, the CSVs
  read, the published version (`Last-Modified`, `ETag`), when it was
  downloaded and last checked against the TSE, and the `columns`/`filter` used
  at import; plus `versao_brelections` and `versao_julia`. Stacking several
  years keeps one entry per year. The metadata follows `df` through `select`,
  `subset`, `transform` and so on.
- `uf` takes several states (`uf = ["PE", "PB"]`) or `:all`. In national
  datasets only those states' files are extracted from the ZIP; in datasets
  partitioned by state (`section_votes`, `voter_profile_section`) one ZIP per
  state is downloaded and stacked, and `:all` asks the TSE which ZIPs exist for
  the year (no `DF` in municipal elections, `ZZ` only in some).
- `section_votes(year; uf = "BR")`: presidential votes by section. The TSE does
  not include them in the state ZIPs, only in this national file (general
  elections), which `dataset_url` used to refuse.
- `polling_places` (`:polling_places`): polling places from 2010 on, one row per
  section and round, with address, CEP, latitude/longitude and voters. The TSE
  ships it as a single national CSV up to 2024 and per state from 2026; with a
  single CSV, `uf` filters rows by `SG_UF` while reading. Coordinates are
  `Float64` whether written with a decimal point or comma, and `missing` where
  the TSE writes `-1`.
- `sources(df)` shows that provenance as a table, and `cite(df; style)` turns it
  into references for the TSE files and for the package version that imported
  them, in ABNT (NBR 6023), APA 7 or BibTeX.

- Support for CSV.jl 1.x (compat `"0.10, 1"`), which reads TSE files about
  5× faster (93 MB file: 0.73 s → 0.14 s; with `filter`, 0.83 s → 0.27 s). On
  Julia 1.9, where CSV.jl 1.x is not available, 0.10 is used as before. Results
  are the same under both versions: checked on ten real datasets (names,
  types, values and pooling identical). CSV.jl 1.0 no longer takes functions in
  `types`/`select`, so the columns to keep as `String` and the `columns`
  selection are resolved against the file header first; it also reads a quoted
  empty field (`""`, which the TSE uses for every empty field) as present empty
  text, so those are turned into `missing` and the affected columns get the
  type CSV.jl 0.10 inferred (integer, float or `dd/mm/yyyy` date).

### Changed

- `filter` is about twice as fast end to end on large files (`section_votes`
  for PE, 2.7 million rows: 2.6 s → 1.4 s): the predicate itself runs ~13×
  faster, since `row.nr_turno` is now resolved to its column at compile time
  instead of on every row. A predicate that returns `missing` (a comparison
  on a column with missing values) now raises an error explaining how to
  handle it.
- The warning for years after the last consolidated election (2026, today) now
  says what is actually the case: files may be missing, and the published ones
  are regenerated during the count. It is shown once per session instead of
  on every call (`uf = :all` used to print it dozens of times).
- `NR_CEP*` and `NR_TELEFONE*` columns are kept as `String`, like the other
  identifiers: CEPs starting with zero (all of São Paulo state, for instance)
  lost it when read as integers.

## [0.2.0] - 2026-10-05

Live vote counting, campaign finance, a TSE ↔ IBGE municipality crosswalk,
several years per call, cache revalidation and much faster extraction.

### Upgrading from 0.1

- Money columns (`vr_*`, e.g. `vr_bem_candidato`) are now `Float64`; they were
  `String` with a decimal comma. Code that parsed them by hand should drop that
  step.
- With a ZIP already cached, a call may make one `HEAD` request to the TSE (at
  most once an hour per file) and download the file again if the TSE
  republished it. Pass `check_updates = false` to keep the cached version
  without touching the network.
- DataFrames 1.4 or later is required.

### Added

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
- `municipalities()`: crosswalk between the TSE municipality code
  (`cd_municipio`, used in every TSE file) and the IBGE code, with name, state,
  capital flag and electoral zones. It comes from the TSE's results system
  (`resultados.tse.jus.br`) for the latest general election, which covers every
  municipality (Brasília and Fernando de Noronha included, unlike municipal
  elections) and the cities abroad. Cached and revalidated like the other files.
  Adds JSON.jl as a dependency.
- Several years at once: `elections`, the shortcuts and `campaign_finance`
  accept a range or vector of years (`candidates(2014:4:2022)`) and stack them
  with an `ano` column. All years are validated before any download. Columns
  present only in some years are `missing` in the others, columns whose type
  differs between years become text (numbers of different types are
  promoted), and columns renamed by the TSE are unified (`COLUMN_ALIASES`;
  `NM_EMAIL` → `DS_EMAIL`). Checked on real 2014/2018/2022 candidates: no
  column ends up as `Any`.
- `OFFICES`: the TSE office codes (`cd_cargo`), from `president = 1` to
  `councillor = 13`, vice and alternate offices included, for filters like
  `row.cd_cargo == OFFICES.federal_deputy`. Checked against the 2014, 2022 and
  2024 candidate files; the same codes are used by `live_results`, which now
  explains that vice and alternate offices have no separate count.
- Cache revalidation. The TSE regenerates its files often, past elections
  included, without changing their URLs, and a cached ZIP used to be reused
  forever. Each download now stores the file's `ETag`, `Last-Modified` and
  `Content-Length` in `<zip>.meta`; on later calls a `HEAD` request checks
  whether the TSE published a new version and downloads it only then. Without
  network access the cached copy is used, with a warning. Caches created by
  earlier versions (no `.meta`) are checked by `Last-Modified`. The new
  `check_updates = false` keyword skips the check.
- `cache_info()`: what is in the local cache, one row per ZIP, with the
  datasets it serves, year, state, ZIP and extracted sizes, and when it was
  last checked against the TSE.
- `clear_cache!(type; year, extracted_only)`: frees one dataset (all years or
  some) instead of wiping the whole cache; `extracted_only = true` keeps the
  ZIPs and drops the extracted CSVs, which are rebuilt without downloading.
  Returns the bytes freed.
- `available_datasets()` has a `first_year` column, and asking for a dataset
  before its first year raises an `ArgumentError` instead of a 404.
  `available_files` skips datasets that did not exist yet in that year.

### Changed

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
- Cache revalidation runs at most once an hour per file instead of on every
  call: the `HEAD` request cost ~0.3 s against ~0.001 s for a cached read. The
  `.meta` file's mtime marks the last successful check (a failed one doesn't
  count). Configurable with `BRElections_REVALIDATE_HOURS` or
  `BRElections.REVALIDATE_INTERVAL[]`.
- The `filter` predicate accepts column names in either case: `row.nr_turno`,
  matching the returned `DataFrame`, or `row.NR_TURNO`, matching the TSE file.
  Before, only the uppercase names worked, even though the result comes with
  lowercase names. Examples in the docs now use the lowercase names.
- DataFrames compat raised to 1.4, the first version with metadata, used by
  `live_results`. Adds the `Unicode` stdlib as a dependency.

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

[Unreleased]: https://github.com/dantebertuzzi/BRElections.jl/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/dantebertuzzi/BRElections.jl/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/dantebertuzzi/BRElections.jl/releases/tag/v0.1.1
[0.1.0]: https://github.com/dantebertuzzi/BRElections.jl/releases/tag/v0.1.0
