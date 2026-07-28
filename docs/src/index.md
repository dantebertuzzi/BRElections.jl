# BRElections.jl

Interface em Julia para os dados públicos do Tribunal Superior Eleitoral
(TSE), inspirada no pacote R `BRElections`.

## Fluxo interno

Uma chamada como `candidates(2022; uf = "PE")` executa:

1. **Validação** — ano (par, ≥ 1998), dataset e UF;
2. **URL** — construção determinística da URL pública no CDN do TSE;
3. **Download com cache** — o ZIP é baixado uma única vez para o diretório
   de `cache_dir()` (escrita atômica, *retry* com *backoff*);
4. **Extração** — os CSVs são extraídos e transcodificados de ISO-8859-1
   para UTF-8 *na extração* (as leituras seguintes usam arquivos UTF-8
   mapeáveis em memória);
5. **Seleção** — para ZIPs nacionais, usa o arquivo `_BRASIL` quando existe
   (evita dupla contagem) ou apenas os arquivos da UF pedida;
6. **Importação tipada** — CSV.jl com `;`, sentinelas `#NULO#`/`#NE#` como
   `missing`, datas `dd/mm/yyyy` como `Date`, identificadores como `String`;
7. **Filtros** — `columns` restringe a materialização de colunas; `filter`
   processa o arquivo em *chunks*, mantendo em memória apenas as linhas
   aprovadas;
8. **Padronização** — nomes de colunas em minúsculas (opcional).

## Instalação

```julia
pkg> add https://github.com/dantebertuzzi/BRElections.jl
```

## Exemplo completo

```julia
using BRElections, DataFrames

# Vagas em disputa em 2022 (dataset pequeno, ótimo para experimentar)
vagas = vacancies(2022)

# Votação nominal de deputado federal em PE, 1º turno
df = candidate_votes(2022; uf = "PE",
        columns = ["NR_TURNO", "CD_CARGO", "NM_URNA_CANDIDATO",
                   "SG_PARTIDO", "QT_VOTOS_NOMINAIS"],
        filter  = row -> row.NR_TURNO == 1 && row.CD_CARGO == 6)

combine(groupby(df, :sg_partido), :qt_votos_nominais => sum => :votos)
```

## Cache

Os arquivos ficam em um *scratch space* portável (Scratch.jl). Controle:

```julia
cache_dir()
set_cache_dir!("/dados/tse")
clear_cache!()
```

Ou defina `BRElections_CACHE` antes de carregar o pacote.
