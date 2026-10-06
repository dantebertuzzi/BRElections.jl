# ---------------------------------------------------------------------------
# Constantes e validações
# ---------------------------------------------------------------------------

"URL base do repositório de dados abertos do TSE."
const TSE_BASE = "https://cdn.tse.jus.br/estatistica/sead/odsele"

"Primeiro ano com arquivos no formato atual do CDN."
const FIRST_YEAR = 1998

"""
Descrição de um dataset suportado.

- `dir`        : subdiretório no CDN do TSE
- `prefix`     : prefixo do ZIP (`prefix_ANO.zip` ou `prefix_ANO_UF.zip`)
- `by_uf`      : `true` quando o próprio ZIP é particionado por UF
- `member`     : prefixo da tabela dentro do ZIP (`member_ANO_UF.csv`), para
                 ZIPs com mais de uma tabela; `""` usa todos os arquivos
- `first_year` : primeiro ano em que o dataset existe nesse formato
- `desc`       : descrição curta (pt-BR)
"""
const DatasetSpec = NamedTuple{(:dir, :prefix, :by_uf, :member, :first_year, :desc),
                               Tuple{String,String,Bool,String,Int,String}}

_ds(dir, prefix, desc; by_uf = false, member = "", first_year = FIRST_YEAR) =
    DatasetSpec((dir, prefix, by_uf, member, first_year, desc))

# A prestação de contas só tem formato padronizado a partir de 2018: antes,
# cada eleição tem nomes de arquivo, diretórios e colunas próprios.
const FINANCE_FIRST_YEAR = 2018
const _CAND_FINANCE = "prestacao_de_contas_eleitorais_candidatos"
const _PARTY_FINANCE = "prestacao_de_contas_eleitorais_orgaos_partidarios"

"Datasets suportados, indexados pelo identificador usado em `elections(; type)`."
const DATASETS = Dict{Symbol,DatasetSpec}(
    :candidates => _ds("consulta_cand", "consulta_cand",
                       "Candidaturas registradas (consulta_cand)"),
    :candidates_complementary => _ds("consulta_cand_complementar", "consulta_cand_complementar",
                       "Dados complementares das candidaturas (nacionalidade, naturalidade, reeleição, teto de gastos...)";
                       first_year = 2014),
    :candidate_social_media => _ds("consulta_cand", "rede_social_candidato",
                       "Redes sociais declaradas pelos candidatos"; first_year = 2014),
    :cassation_reasons => _ds("motivo_cassacao", "motivo_cassacao",
                       "Motivos de cassação de candidaturas"; first_year = 2012),
    :candidate_votes => _ds("votacao_candidato_munzona", "votacao_candidato_munzona",
                       "Votação nominal por candidato, município e zona"),
    :party_votes => _ds("votacao_partido_munzona", "votacao_partido_munzona",
                       "Votação por partido, município e zona"),
    :vote_details => _ds("detalhe_votacao_munzona", "detalhe_votacao_munzona",
                       "Detalhe da apuração por município e zona"),
    :section_votes => _ds("votacao_secao", "votacao_secao",
                       "Votação por seção eleitoral (um ZIP por UF)"; by_uf = true),
    :section_vote_details => _ds("detalhe_votacao_secao", "detalhe_votacao_secao",
                       "Detalhe da apuração por seção eleitoral"),
    :assets => _ds("bem_candidato", "bem_candidato", "Bens declarados pelos candidatos"),
    :coalitions => _ds("consulta_coligacao", "consulta_coligacao", "Coligações e legendas"),
    :vacancies => _ds("consulta_vagas", "consulta_vagas", "Número de vagas em disputa"),
    :voter_profile => _ds("perfil_eleitorado", "perfil_eleitorado", "Perfil do eleitorado"),
    :polling_places => _ds("eleitorado_locais_votacao", "eleitorado_local_votacao",
                       "Locais de votação: endereço, coordenadas e eleitores por seção";
                       first_year = 2010),
    :voter_profile_section => _ds("perfil_eleitor_secao", "perfil_eleitor_secao",
                       "Perfil do eleitorado por seção eleitoral (um ZIP por UF)";
                       by_uf = true, first_year = 2008),

    # Prestação de contas: cada ZIP traz quatro tabelas.
    :candidate_revenue => _ds("prestacao_contas", _CAND_FINANCE,
                       "Receitas de campanha dos candidatos";
                       member = "receitas_candidatos", first_year = FINANCE_FIRST_YEAR),
    :candidate_revenue_original_donor => _ds("prestacao_contas", _CAND_FINANCE,
                       "Receitas dos candidatos pelo doador originário";
                       member = "receitas_candidatos_doador_originario", first_year = FINANCE_FIRST_YEAR),
    :candidate_expenses_contracted => _ds("prestacao_contas", _CAND_FINANCE,
                       "Despesas contratadas pelos candidatos";
                       member = "despesas_contratadas_candidatos", first_year = FINANCE_FIRST_YEAR),
    :candidate_expenses_paid => _ds("prestacao_contas", _CAND_FINANCE,
                       "Despesas pagas pelos candidatos";
                       member = "despesas_pagas_candidatos", first_year = FINANCE_FIRST_YEAR),
    :party_revenue => _ds("prestacao_contas", _PARTY_FINANCE,
                       "Receitas de campanha dos órgãos partidários";
                       member = "receitas_orgaos_partidarios", first_year = FINANCE_FIRST_YEAR),
    :party_revenue_original_donor => _ds("prestacao_contas", _PARTY_FINANCE,
                       "Receitas dos órgãos partidários pelo doador originário";
                       member = "receitas_orgaos_partidarios_doador_originario", first_year = FINANCE_FIRST_YEAR),
    :party_expenses_contracted => _ds("prestacao_contas", _PARTY_FINANCE,
                       "Despesas contratadas pelos órgãos partidários";
                       member = "despesas_contratadas_orgaos_partidarios", first_year = FINANCE_FIRST_YEAR),
    :party_expenses_paid => _ds("prestacao_contas", _PARTY_FINANCE,
                       "Despesas pagas pelos órgãos partidários";
                       member = "despesas_pagas_orgaos_partidarios", first_year = FINANCE_FIRST_YEAR),
)

"""
Códigos dos cargos eletivos no TSE — os mesmos da coluna `cd_cargo` dos
arquivos e da Divulgação de Resultados ([`live_results`](@ref)). Servem
para filtrar sem decorar números:

```julia
dep = candidate_votes(2022; uf = "PE", filter = row -> row.cd_cargo == OFFICES.federal_deputy)
```

`first_alternate` e `second_alternate` são o 1º e o 2º suplente de senador.
"""
const OFFICES = (
    president        = 1,
    vice_president   = 2,
    governor         = 3,
    vice_governor    = 4,
    senator          = 5,
    federal_deputy   = 6,
    state_deputy     = 7,
    district_deputy  = 8,
    first_alternate  = 9,
    second_alternate = 10,
    mayor            = 11,
    vice_mayor       = 12,
    councillor       = 13,
)

"Unidades federativas aceitas (`BR` = arquivo nacional, `ZZ` = exterior)."
const UFS = ["AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA",
             "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN",
             "RO", "RR", "RS", "SC", "SE", "SP", "TO", "ZZ", "BR"]

"""
Datasets particionados por UF que também têm um ZIP `_BR`, com os votos para
Presidente, cargo que não aparece nos ZIPs das UFs (só em eleições gerais).
"""
const _BR_ZIP = (:section_votes,)

"Último ano eleitoral com arquivos consolidados conhecidos pelo pacote."
const LAST_KNOWN_YEAR = 2024


"""
    validate_year(year) -> Int

Valida um ano eleitoral (par, ≥ $(FIRST_YEAR)). Para anos posteriores a
$(LAST_KNOWN_YEAR), avisa (uma vez por sessão) que os arquivos podem estar
incompletos, ser preliminares ou ainda não existir.
"""
function validate_year(year::Integer)
    iseven(year) || throw(ArgumentError(
        "Ano eleitoral inválido: $year. Eleições brasileiras ocorrem em anos pares."))
    year >= FIRST_YEAR || throw(ArgumentError(
        "Ano $year não suportado. O pacote cobre eleições a partir de $(FIRST_YEAR)."))
    # Uma vez por sessão: `:all` e vários anos validam o mesmo ano dezenas de vezes.
    year > LAST_KNOWN_YEAR && @warn "Os dados de $year ainda não estão consolidados (a última eleição " *
        "consolidada conhecida pelo pacote é $(LAST_KNOWN_YEAR)): alguns arquivos podem não estar " *
        "publicados, e os publicados são regerados pelo TSE durante a apuração e o julgamento das " *
        "candidaturas. Cite a data do download (veja `sources`)." maxlog = 1
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
`year`. Para datasets particionados por UF no CDN (`:section_votes`,
`:voter_profile_section`) o argumento `uf` é obrigatório; em `:section_votes`,
`uf = "BR"` é o arquivo com os votos para Presidente (eleições gerais). Anos anteriores ao
primeiro do dataset (coluna `first_year` de [`available_datasets`](@ref))
são recusados.

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
    y >= ds.first_year || throw(ArgumentError(
        "O dataset :$type só está disponível neste formato a partir de $(ds.first_year). " *
        "Os arquivos brutos de anos anteriores, quando existem, estão em $(TSE_BASE)/$(ds.dir)/."))
    if ds.by_uf
        uf === nothing && throw(ArgumentError(
            "O dataset :$type é particionado por UF; informe `uf`, por exemplo uf = \"PE\"."))
        u = validate_uf(uf)
        if u == "BR"
            type in _BR_ZIP || throw(ArgumentError(
                "O dataset :$type não possui arquivo nacional; informe uma UF específica."))
            iseven(y ÷ 2) && throw(ArgumentError(
                "O arquivo nacional (uf = \"BR\") de :$type traz os votos para Presidente e só " *
                "existe em eleições gerais; $y foi uma eleição municipal."))
        end
        return "$(TSE_BASE)/$(ds.dir)/$(ds.prefix)_$(y)_$(u).zip"
    end
    "$(TSE_BASE)/$(ds.dir)/$(ds.prefix)_$(y).zip"
end

"""
    available_datasets() -> DataFrame

Tabela com os datasets suportados, o subdiretório no CDN do TSE, se são
particionados por UF, o primeiro ano disponível e uma descrição curta.
"""
function available_datasets()
    ks = sort!(collect(keys(DATASETS)))
    DataFrame(
        dataset = ks,
        tse_dir = [DATASETS[k].dir for k in ks],
        by_uf = [DATASETS[k].by_uf for k in ks],
        first_year = [DATASETS[k].first_year for k in ks],
        description = [DATASETS[k].desc for k in ks],
    )
end
