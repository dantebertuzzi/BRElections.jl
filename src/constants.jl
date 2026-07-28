# ---------------------------------------------------------------------------
# Constantes e validações
# ---------------------------------------------------------------------------

"URL base do repositório de dados abertos do TSE."
const TSE_BASE = "https://cdn.tse.jus.br/estatistica/sead/odsele"

"""
Descrição de cada dataset suportado.

- `dir`    : subdiretório no CDN do TSE
- `prefix` : prefixo dos arquivos (`prefix_ANO.zip` ou `prefix_ANO_UF.zip`)
- `by_uf`  : `true` quando o próprio ZIP é particionado por UF
- `desc`   : descrição curta (pt-BR)
"""
const DATASETS = Dict{Symbol,NamedTuple{(:dir, :prefix, :by_uf, :desc),Tuple{String,String,Bool,String}}}(
    :candidates => (dir = "consulta_cand", prefix = "consulta_cand", by_uf = false,
                    desc = "Candidaturas registradas (consulta_cand)"),
    :candidate_votes => (dir = "votacao_candidato_munzona", prefix = "votacao_candidato_munzona", by_uf = false,
                    desc = "Votação nominal por candidato, município e zona"),
    :party_votes => (dir = "votacao_partido_munzona", prefix = "votacao_partido_munzona", by_uf = false,
                    desc = "Votação por partido, município e zona"),
    :vote_details => (dir = "detalhe_votacao_munzona", prefix = "detalhe_votacao_munzona", by_uf = false,
                    desc = "Detalhe da apuração por município e zona"),
    :section_votes => (dir = "votacao_secao", prefix = "votacao_secao", by_uf = true,
                    desc = "Votação por seção eleitoral (um ZIP por UF)"),
    :section_vote_details => (dir = "detalhe_votacao_secao", prefix = "detalhe_votacao_secao", by_uf = false,
                    desc = "Detalhe da apuração por seção eleitoral"),
    :assets => (dir = "bem_candidato", prefix = "bem_candidato", by_uf = false,
                    desc = "Bens declarados pelos candidatos"),
    :coalitions => (dir = "consulta_coligacao", prefix = "consulta_coligacao", by_uf = false,
                    desc = "Coligações e legendas"),
    :vacancies => (dir = "consulta_vagas", prefix = "consulta_vagas", by_uf = false,
                    desc = "Número de vagas em disputa"),
    :voter_profile => (dir = "perfil_eleitorado", prefix = "perfil_eleitorado", by_uf = false,
                    desc = "Perfil do eleitorado"),
)

"Unidades federativas aceitas (`BR` = arquivo nacional, `ZZ` = exterior)."
const UFS = ["AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA",
             "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN",
             "RO", "RR", "RS", "SC", "SE", "SP", "TO", "ZZ", "BR"]

"Último ano eleitoral com arquivos consolidados conhecidos pelo pacote."
const LAST_KNOWN_YEAR = 2024

"Primeiro ano com arquivos no formato atual do CDN."
const FIRST_YEAR = 1998

"""
    validate_year(year) -> Int

Valida um ano eleitoral (par, ≥ $(FIRST_YEAR)). Emite `@warn` para anos
posteriores a $(LAST_KNOWN_YEAR), cujos arquivos podem ainda não existir.
"""
function validate_year(year::Integer)
    iseven(year) || throw(ArgumentError(
        "Ano eleitoral inválido: $year. Eleições brasileiras ocorrem em anos pares."))
    year >= FIRST_YEAR || throw(ArgumentError(
        "Ano $year não suportado. O pacote cobre eleições a partir de $(FIRST_YEAR)."))
    year > LAST_KNOWN_YEAR && @warn "Ano $year é posterior à última eleição consolidada " *
        "conhecida ($(LAST_KNOWN_YEAR)); os arquivos podem ainda não estar publicados."
    Int(year)
end

"""
    validate_type(type) -> Symbol

Valida o identificador de dataset contra as chaves de `DATASETS`.
"""
function validate_type(type::Symbol)
    haskey(DATASETS, type) || throw(ArgumentError(
        "Dataset desconhecido: :$type. Opções: " *
        join(sort!(collect(keys(DATASETS))), ", ", " e ") *
        ". Veja `available_datasets()`."))
    type
end

"""
    validate_uf(uf) -> String

Normaliza (maiúsculas) e valida uma sigla de UF.
"""
function validate_uf(uf::AbstractString)
    u = uppercase(strip(uf))
    u in UFS || throw(ArgumentError("UF inválida: $uf. Opções: " * join(UFS, ", ") * "."))
    u
end

"""
    dataset_url(type, year; uf = nothing) -> String

Constrói a URL pública do ZIP no CDN do TSE para o dataset `type` e o ano
`year`. Para datasets particionados por UF no CDN (`:section_votes`) o
argumento `uf` é obrigatório.

```julia
julia> dataset_url(:candidates, 2022)
"https://cdn.tse.jus.br/estatistica/sead/odsele/consulta_cand/consulta_cand_2022.zip"

julia> dataset_url(:section_votes, 2022; uf = "PE")
"https://cdn.tse.jus.br/estatistica/sead/odsele/votacao_secao/votacao_secao_2022_PE.zip"
```
"""
function dataset_url(type::Symbol, year::Integer; uf::Union{Nothing,AbstractString} = nothing)
    validate_type(type)
    y = validate_year(year)
    ds = DATASETS[type]
    if ds.by_uf
        uf === nothing && throw(ArgumentError(
            "O dataset :$type é particionado por UF; informe `uf`, por exemplo uf = \"PE\"."))
        u = validate_uf(uf)
        u == "BR" && throw(ArgumentError(
            "O dataset :$type não possui arquivo nacional; informe uma UF específica."))
        return "$(TSE_BASE)/$(ds.dir)/$(ds.prefix)_$(y)_$(u).zip"
    end
    "$(TSE_BASE)/$(ds.dir)/$(ds.prefix)_$(y).zip"
end

"""
    available_datasets() -> DataFrame

Tabela com os datasets suportados, o subdiretório no CDN do TSE, se são
particionados por UF e uma descrição curta.
"""
function available_datasets()
    ks = sort!(collect(keys(DATASETS)))
    DataFrame(
        dataset = ks,
        tse_dir = [DATASETS[k].dir for k in ks],
        by_uf = [DATASETS[k].by_uf for k in ks],
        description = [DATASETS[k].desc for k in ks],
    )
end
