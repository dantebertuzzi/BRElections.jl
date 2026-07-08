# BRElections.jl

[![CI](https://github.com/SEU_USUARIO/BRElections.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/SEU_USUARIO/BRElections.jl/actions/workflows/CI.yml)

Interface em Julia para os **dados públicos do Tribunal Superior Eleitoral (TSE)**,
inspirada no pacote R [`BRElections`](https://github.com/silvadenisson/BRElections),
mas seguindo as convenções do ecossistema Julia (DataFrames.jl, CSV.jl, Scratch.jl).

O pacote usa exclusivamente os arquivos abertos publicados em
`https://cdn.tse.jus.br/estatistica/sead/odsele/` — nenhuma API privada ou
autorização é necessária.

## Funcionalidades

- Download automático dos ZIPs do TSE, com novas tentativas e escrita atômica;
- Cache local portável (Windows/Linux/macOS) via Scratch.jl, configurável por
  `BRElections_CACHE` ou `set_cache_dir!`;
- Descoberta dos arquivos publicados por ano (`available_files`);
- Descompactação dos ZIPs com transcodificação ISO-8859-1 → UTF-8 na extração;
- Importação eficiente de CSVs grandes (CSV.jl, multithread, leitura em *chunks*);
- Conversão automática de tipos: datas `dd/mm/yyyy` → `Date`, sentinelas
  `#NULO#`/`#NE#` → `missing`, identificadores (`NR_CPF_*`, `NR_TITULO_*`)
  preservados como `String` (zeros à esquerda intactos);
- Padronização de nomes de colunas (minúsculas, opcional);
- Filtros de **colunas** e de **linhas** aplicados durante a importação;
- Testes automatizados (offline por padrão; testes de rede opcionais).

## Instalação

```julia
pkg> add https://github.com/SEU_USUARIO/BRElections.jl
```

## Uso rápido

```julia
using BRElections

# Datasets disponíveis
available_datasets()

# O que o TSE já publicou para 2022?
available_files(2022)

# Candidaturas de 2022 (Brasil inteiro)
cand = candidates(2022)

# Votação nominal em PE, 1º turno, só as colunas de interesse.
# O filtro é aplicado durante a leitura (chunks) — só as linhas
# aprovadas ocupam memória.
pe = candidate_votes(2022; uf = "PE",
        columns = ["NR_TURNO", "NM_MUNICIPIO", "NM_URNA_CANDIDATO",
                   "SG_PARTIDO", "QT_VOTOS_NOMINAIS"],
        filter  = row -> row.NR_TURNO == 1)

# Votação por seção eleitoral (o TSE publica um ZIP por UF)
sec = section_votes(2022; uf = "PE")

# Interface genérica equivalente
df = elections(2020; type = :assets, uf = "PE")
```

### Datasets suportados

| `type`                   | Repositório TSE            | Descrição                                   |
|--------------------------|----------------------------|---------------------------------------------|
| `:candidates`            | `consulta_cand`            | Candidaturas registradas                     |
| `:candidate_votes`       | `votacao_candidato_munzona`| Votação nominal por candidato/município/zona |
| `:party_votes`           | `votacao_partido_munzona`  | Votação por partido/município/zona           |
| `:vote_details`          | `detalhe_votacao_munzona`  | Detalhe da apuração por município/zona       |
| `:section_votes`†        | `votacao_secao`            | Votação por seção eleitoral                  |
| `:section_vote_details`† | `detalhe_votacao_secao`    | Detalhe da apuração por seção                |
| `:assets`                | `bem_candidato`            | Bens declarados pelos candidatos             |
| `:coalitions`            | `consulta_legendas`        | Coligações e legendas                        |
| `:vacancies`             | `consulta_vagas`           | Vagas em disputa                             |
| `:voter_profile`         | `perfil_eleitorado`        | Perfil do eleitorado                         |

† Particionados por UF no TSE — o argumento `uf` é obrigatório.

### Cache

```julia
cache_dir()          # onde os ZIPs/CSVs ficam
set_cache_dir!(dir)  # redefinir em tempo de execução
clear_cache!()       # limpar tudo
```

A variável de ambiente `BRElections_CACHE` define o diretório no carregamento
do pacote.

## Testes

```julia
pkg> test BRElections                     # suíte offline (fixtures sintéticas)
```

```bash
BRElections_TEST_NETWORK=true julia --project -e 'using Pkg; Pkg.test()'  # inclui smoke tests contra o CDN do TSE
```

## Escopo e limitações

- Cobre eleições de 1998 em diante, no formato atual do CDN (arquivos com
  cabeçalho). Anos muito antigos podem ter esquemas divergentes.
- Prestação de contas de campanha (`prestacao_de_contas`) usa outra estrutura
  de URLs no TSE e está no roadmap.
- Os dicionários de variáveis oficiais acompanham cada ZIP (`leiame.pdf`) e
  permanecem no cache para consulta.

## Licença

MIT. Os dados pertencem ao TSE e são públicos.
