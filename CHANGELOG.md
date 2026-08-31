# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
