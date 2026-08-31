# BRElections.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://dantebertuzzi.github.io/BRElections.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://dantebertuzzi.github.io/BRElections.jl/dev)
[![CI](https://github.com/dantebertuzzi/BRElections.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/dantebertuzzi/BRElections.jl/actions/workflows/CI.yml)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.22182707.svg)](https://doi.org/10.5281/zenodo.22182707)

<img src="logo.png" alt="BRElections logo" width="200" align="right">

Julia interface for **public electoral data from Brazil's TSE (Tribunal Superior
Eleitoral)**, inspired by the R package
[`electionsBR`](https://github.com/silvadenisson/electionsBR), but following
Julia ecosystem conventions (DataFrames.jl, CSV.jl, Scratch.jl).

The package uses only the open data files published at
`https://cdn.tse.jus.br/estatistica/sead/odsele/` — no private API or
authorisation is required.

## Features

- Automatic download of TSE ZIPs, with retry logic and atomic writes;
- Portable local cache (Windows/Linux/macOS) via Scratch.jl, configurable through
  the `BRElections_CACHE` environment variable or `set_cache_dir!`;
- Discovery of published files by year (`available_files`);
- ZIP decompression with on-the-fly ISO-8859-1 → UTF-8 transcoding;
- Efficient import of large CSVs (CSV.jl, multithreaded, chunk-based reading);
- Automatic type conversion: `dd/mm/yyyy` dates → `Date`, sentinels
  `#NULO#`/`#NE#` → `missing`, identifier columns (`NR_CPF_*`, `NR_TITULO_*`)
  preserved as `String` (leading zeros intact);
- Column name normalisation (lowercase, optional);
- **Column** and **row** filters applied during import to minimise memory usage;
- Automated test suite (offline by default; optional network tests).

## Installation

```julia
pkg> add BRElections
```

Requires Julia 1.9 or later.

## Quick start

```julia
using BRElections

# Available datasets
available_datasets()

# What has the TSE already published for 2022?
available_files(2022)

# Candidates in 2022 (whole country)
cand = candidates(2022)

# Nominal votes in PE, 1st round, only the columns of interest.
# The filter is applied during reading (chunks) — only matching rows
# are kept in memory.
pe = candidate_votes(2022; uf = "PE",
        columns = ["NR_TURNO", "NM_MUNICIPIO", "NM_URNA_CANDIDATO",
                   "SG_PARTIDO", "QT_VOTOS_NOMINAIS"],
        filter  = row -> row.NR_TURNO == 1)

# Votes by electoral section (the TSE publishes one ZIP per state)
sec = section_votes(2022; uf = "PE")

# Generic interface equivalent to the above
df = elections(2020; type = :assets, uf = "PE")
```

### Supported datasets

| `type`                   | TSE repository             | Description                                  |
|--------------------------|----------------------------|----------------------------------------------|
| `:candidates`            | `consulta_cand`            | Registered candidates                         |
| `:candidate_votes`       | `votacao_candidato_munzona`| Nominal votes by candidate/municipality/zone  |
| `:party_votes`           | `votacao_partido_munzona`  | Votes by party/municipality/zone              |
| `:vote_details`          | `detalhe_votacao_munzona`  | Vote count details by municipality/zone       |
| `:section_votes`†        | `votacao_secao`            | Votes by electoral section                    |
| `:section_vote_details`  | `detalhe_votacao_secao`    | Vote count details by section                 |
| `:assets`                | `bem_candidato`            | Candidate asset declarations                  |
| `:coalitions`            | `consulta_coligacao`       | Coalitions and party legends                  |
| `:vacancies`             | `consulta_vagas`           | Number of seats in dispute                    |
| `:voter_profile`         | `perfil_eleitorado`        | Electorate profile                            |

† Partitioned by state on the TSE CDN — the `uf` argument is mandatory.

### Cache

```julia
cache_dir()          # where ZIPs and CSVs are stored
set_cache_dir!(dir)  # change cache directory at runtime
clear_cache!()       # wipe all cached data
```

The `BRElections_CACHE` environment variable sets the directory at package load
time.

## Tests

```julia
pkg> test BRElections                     # offline suite (synthetic fixtures)
```

```bash
BRElections_TEST_NETWORK=true julia --project -e 'using Pkg; Pkg.test()'  # includes smoke tests against the TSE CDN
```

## Scope and limitations

- Covers elections from 1998 onward, in the current CDN format (files with
  headers). Very old years may have divergent schemas.
- Campaign finance reports (`prestacao_de_contas`) use a different URL structure
  on the TSE CDN and are on the roadmap.
- Official variable dictionaries come with each ZIP (`leiame.pdf`) and remain
  in the cache for reference.

## How to cite

If BRElections.jl was part of your analysis pipeline, cite **two things
separately**: the software and the data. They are distinct objects with
distinct responsibilities — the package answers for downloading, decoding and
typing, the TSE answers for the content.

### 1. The software

The repository ships a [`CITATION.cff`](CITATION.cff), which GitHub reads
natively: the **"Cite this repository"** button in the sidebar generates ready
APA and BibTeX. A [`CITATION.bib`](CITATION.bib) is also provided:

```bibtex
@software{bertuzzi_brelections_2026,
  author  = {Bertuzzi, Dante},
  title   = {{BRElections.jl}: a {Julia} interface to {Brazilian} electoral
             open data ({TSE})},
  year    = {2026},
  version = {0.1.1},
  doi     = {10.5281/zenodo.22182707},
  url     = {https://github.com/dantebertuzzi/BRElections.jl},
  note    = {Julia package}
}
```

**Cite the version you used**, not "the latest". The import layer is part of
the result: which columns are kept as `String`, which sentinels become
`missing` and how a schema change on the TSE side is absorbed can differ
between releases. Run `pkg> status BRElections` and use the number it prints.

### 2. The TSE data

The TSE is the primary source and must be cited as such, **with the download
date** — the open-data files are regenerated as results are totalled and
candidacies are judged, so the same query run on different dates can return
different numbers:

> BRASIL. Tribunal Superior Eleitoral. *Repositório de dados eleitorais*:
> dados abertos. Brasília: TSE, 2026. Available at:
> https://cdn.tse.jus.br/estatistica/sead/odsele/. Accessed: 31 Aug. 2026.

State the **year and the dataset** you used (`candidates`, `candidate_votes`,
`section_votes`, …), since each is a separate published file with its own
layout. Variable meanings come from the `leiame.pdf` shipped inside each ZIP,
which stays in the cache for reference.

### 3. Reproducibility

So that someone else reaches your number, record in the paper or supplementary
material: the **BRElections.jl and Julia versions**; the `Project.toml` and
`Manifest.toml` of the environment (the `Manifest.toml` pins the whole
dependency tree and is what makes the environment reconstructible with
`Pkg.instantiate()`); the **download date** of the TSE files (and whether you
worked from an older cache — `cache_dir` shows where it lives); and the year,
dataset and any `filter`/`columns` you applied during import, since rows and
columns dropped at read time never reach the table you analysed.

### The standards behind this

| Standard | What it establishes |
|---|---|
| [FORCE11 — Software Citation Principles](https://force11.org/info/software-citation-principles-published-2016/) | Software is a citable research product. Six principles: importance, credit, unique identification, persistence, accessibility and **specificity** (cite the exact version). |
| [Citation File Format (CFF) 1.2.0](https://citation-file-format.github.io/) | Machine-readable citation metadata. What GitHub and Zenodo consume. |
| ABNT NBR 6023:2018 | References in Brazilian publications; requires `Disponível em` + `Acesso em` for electronic documents. |
| [Zenodo + GitHub](https://docs.github.com/en/repositories/archiving-a-github-repository/referencing-and-citing-content) | Mints a persistent DOI per release, plus a *concept DOI* always pointing at the newest version. |

**The DOIs of this project**: the repository is connected to
[Zenodo](https://zenodo.org), so every release is archived and gets a
persistent identifier — the citation no longer depends on the GitHub URL
surviving a rename or a transfer. Two DOIs coexist, and they are not
interchangeable:

| DOI | What it identifies |
|---|---|
| [10.5281/zenodo.22182707](https://doi.org/10.5281/zenodo.22182707) | *Concept DOI* — the project as a whole. Always resolves to the newest version; it is what the badge at the top of this README points at. |
| one per release | Each archived version gets its own — 0.1.1 is [10.5281/zenodo.22182708](https://doi.org/10.5281/zenodo.22182708). All of them are listed on the [Zenodo page](https://doi.org/10.5281/zenodo.22182707). |

The BibTeX above carries the concept DOI, so it keeps working across releases.
**In a paper, swap it for the DOI of the version you used**: the concept DOI
says which project you used, the version DOI says which code actually ran.

## License

MIT. The data belongs to the TSE and is publicly available.