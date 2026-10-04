"""
    BRElections

Interface em Julia para os dados públicos do Tribunal Superior Eleitoral (TSE).

O pacote baixa, armazena em cache, descompacta e importa os repositórios
públicos do TSE (`https://cdn.tse.jus.br/estatistica/sead/odsele/`) como
`DataFrame`s tipados, com tratamento de codificação (ISO-8859-1 → UTF-8),
valores sentinela (`#NULO#`, `#NE#`), datas e nomes de colunas.

Ponto de entrada principal: [`elections`](@ref). Funções de conveniência:
[`candidates`](@ref), [`candidate_votes`](@ref), [`party_votes`](@ref),
[`vote_details`](@ref), [`section_votes`](@ref), [`section_vote_details`](@ref),
[`assets`](@ref), [`coalitions`](@ref), [`vacancies`](@ref),
[`voter_profile`](@ref), [`voter_profile_section`](@ref),
[`candidates_complementary`](@ref), [`candidate_social_media`](@ref),
[`cassation_reasons`](@ref). Prestação de contas: [`campaign_finance`](@ref).
Para cruzar com dados do IBGE:
[`municipalities`](@ref). Apuração ao vivo: [`live_results`](@ref).

```julia
using BRElections

# Candidaturas de 2022 (Brasil inteiro)
cand = candidates(2022)

# Votação por candidato/município/zona apenas em PE, com filtro na importação
df = candidate_votes(2022; uf = "PE",
                     columns = ["nr_turno", "nm_municipio", "nm_candidato", "qt_votos_nominais"],
                     filter  = row -> row.nr_turno == 1)
```

O pacote usa apenas arquivos públicos; nenhuma API privada ou autorização
do TSE é necessária.
"""
module BRElections

using CSV
using DataFrames
using Dates
using Downloads
using JSON
using Logging
using Scratch
using StringEncodings
using Unicode
using ZipFile

export elections,
       candidates, candidate_votes, party_votes, vote_details,
       section_votes, section_vote_details,
       assets, coalitions, vacancies, voter_profile, voter_profile_section,
       candidates_complementary, candidate_social_media, cassation_reasons,
       campaign_finance,
       municipalities, live_results,
       available_datasets, available_files, dataset_url,
       cache_dir, set_cache_dir!, clear_cache!,
       read_tse_csv

include("constants.jl")
include("cache.jl")
include("download.jl")
include("extract.jl")
include("parse.jl")
include("api.jl")
include("municipalities.jl")
include("live.jl")

end # module
