# BRElections.jl

[![CI](https://github.com/dantebertuzzi/BRElections.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/dantebertuzzi/BRElections.jl/actions/workflows/CI.yml)

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
pkg> add https://github.com/dantebertuzzi/BRElections.jl
```

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
| `:section_vote_details`† | `detalhe_votacao_secao`    | Vote count details by section                 |
| `:assets`                | `bem_candidato`            | Candidate asset declarations                  |
| `:coalitions`            | `consulta_legendas`        | Coalitions and party legends                  |
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

## License

MIT. The data belongs to the TSE and is publicly available.