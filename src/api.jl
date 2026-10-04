# ---------------------------------------------------------------------------
# API pública de alto nível
# ---------------------------------------------------------------------------

"""
    elections(year; type = :candidates, uf = nothing, kwargs...) -> DataFrame

Baixa (com cache), descompacta e importa um dataset eleitoral público do TSE.

# Argumentos

- `year`: ano eleitoral (par, ≥ $(FIRST_YEAR)).
- `type`: dataset — uma das chaves de `available_datasets()`:
  `:candidates`, `:candidates_complementary`, `:candidate_social_media`,
  `:cassation_reasons`, `:candidate_votes`, `:party_votes`, `:vote_details`,
  `:section_votes`, `:section_vote_details`, `:assets`, `:coalitions`,
  `:vacancies`, `:voter_profile`, `:voter_profile_section` e as tabelas de
  prestação de contas (veja [`campaign_finance`](@ref)).
- `uf`: sigla da UF (`"PE"`, `"SP"`, ...). Opcional para datasets nacionais
  (nesse caso importa o Brasil inteiro); **obrigatória** para
  `:section_votes` e `:voter_profile_section`, que o TSE publica em um ZIP
  por UF.

# Importação (repassados a [`read_tse_csv`](@ref))

- `columns = nothing`: importa apenas as colunas listadas.
- `filter = nothing`: predicado `row -> Bool` aplicado durante a leitura
  (processamento em *chunks* — só as linhas aprovadas ficam em memória).
- `normalize_names = true`: nomes de colunas em minúsculas.

# Download/cache

- `force = false`: rebaixa o ZIP e reextrai mesmo com cache presente.
- `check_updates = true`: com o ZIP em cache, faz um `HEAD` no TSE e baixa de
  novo só se o arquivo publicado mudou (o TSE regera os arquivos com
  frequência, inclusive de eleições antigas). Sem rede, usa o cache. Use
  `false` para trabalhar offline sem consultar o servidor, ou para fixar a
  versão já baixada.
- `verbose = true`: mensagens de progresso.

# Exemplos

```julia
# Todas as candidaturas de 2022
cand = elections(2022; type = :candidates)

# Votos nominais em PE, 1º turno, só as colunas de interesse
pe = elections(2022; type = :candidate_votes, uf = "PE",
               columns = ["nr_turno", "nm_municipio", "nm_urna_candidato",
                          "sg_partido", "qt_votos_nominais"],
               filter = row -> row.nr_turno == 1)

# Votação por seção (particionada por UF no TSE)
sec = elections(2022; type = :section_votes, uf = "PE")
```
"""
function elections(year::Integer;
                   type::Symbol = :candidates,
                   uf::Union{Nothing,AbstractString} = nothing,
                   columns = nothing,
                   filter::Union{Nothing,Function} = nothing,
                   normalize_names::Bool = true,
                   force::Bool = false,
                   check_updates::Bool = true,
                   verbose::Bool = true,
                   ntasks::Int = max(Threads.nthreads(), 1))
    y = validate_year(year)
    t = validate_type(type)
    ds = DATASETS[t]

    url = ds.by_uf ? dataset_url(t, y; uf) : dataset_url(t, y)
    zippath = _zip_path(t, url)
    download_file(url, zippath; force, check_updates, verbose)
    # Em ZIPs nacionais, já restringe a extração aos arquivos da UF pedida
    # (ou ao _BRASIL): evita descompactar/transcodificar dados que não serão
    # usados, o que para alguns datasets chega a vários GB desnecessários.
    csvs = extract_csvs(zippath; uf = ds.by_uf ? nothing : uf, member = ds.member, force)
    files = ds.by_uf ? csvs : select_csvs(csvs; uf)
    verbose && @info "Importando $(length(files)) arquivo(s)" basename.(files)

    read_tse_csvs(files; columns, filter, normalize_names, ntasks)
end

# --- Funções de conveniência --------------------------------------------

for (fname, dtype) in (
        (:candidates, :candidates),
        (:candidate_votes, :candidate_votes),
        (:party_votes, :party_votes),
        (:vote_details, :vote_details),
        (:section_votes, :section_votes),
        (:section_vote_details, :section_vote_details),
        (:assets, :assets),
        (:coalitions, :coalitions),
        (:vacancies, :vacancies),
        (:voter_profile, :voter_profile),
        (:voter_profile_section, :voter_profile_section),
        (:candidates_complementary, :candidates_complementary),
        (:candidate_social_media, :candidate_social_media),
        (:cassation_reasons, :cassation_reasons),
    )
    desc = DATASETS[dtype].desc
    @eval begin
        """
            $($fname)(year; kwargs...) -> DataFrame

        $($desc). Atalho para `elections(year; type = :$($dtype), kwargs...)`.
        """
        $fname(year::Integer; kwargs...) = elections(year; type = $(QuoteNode(dtype)), kwargs...)
    end
end

# --- Prestação de contas ------------------------------------------------

const _FINANCE_TYPES = Dict(
    (:candidates, :revenue)                 => :candidate_revenue,
    (:candidates, :revenue_original_donor)  => :candidate_revenue_original_donor,
    (:candidates, :expenses_contracted)     => :candidate_expenses_contracted,
    (:candidates, :expenses_paid)           => :candidate_expenses_paid,
    (:parties, :revenue)                    => :party_revenue,
    (:parties, :revenue_original_donor)     => :party_revenue_original_donor,
    (:parties, :expenses_contracted)        => :party_expenses_contracted,
    (:parties, :expenses_paid)              => :party_expenses_paid,
)

"""
    campaign_finance(year; table = :revenue, filer = :candidates, uf = nothing, kwargs...) -> DataFrame

Prestação de contas eleitorais: receitas e despesas de campanha declaradas ao
TSE. Disponível a partir de $(FINANCE_FIRST_YEAR), quando os arquivos passaram a
ter formato padronizado.

# Argumentos

- `table`: `:revenue` (receitas), `:revenue_original_donor` (receitas pelo
  doador originário — quem doou ao partido que repassou ao candidato, por
  exemplo), `:expenses_contracted` (despesas contratadas) ou
  `:expenses_paid` (despesas pagas).
- `filer`: quem prestou contas — `:candidates` ou `:parties` (órgãos
  partidários).
- `uf`: restringe a uma UF. **Recomendado**: os arquivos nacionais têm de
  centenas de MB a alguns GB (o ZIP de candidatos de 2024 tem 1,3 GB). Em
  eleições gerais, `uf = "BR"` traz as contas de quem disputou cargo nacional
  (Presidente).

Os demais argumentos são os de [`elections`](@ref) (`columns`, `filter`,
`check_updates`...). As quatro tabelas de cada prestador vêm do mesmo ZIP,
baixado uma vez só.

Equivale a `elections(year; type = ...)` com `:candidate_revenue`,
`:candidate_expenses_paid`, `:party_revenue` etc.

# Exemplo

```julia
rec = campaign_finance(2022; uf = "PE")
desp = campaign_finance(2022; table = :expenses_paid, uf = "PE",
                        columns = [:sq_candidato, :nm_candidato, :ds_origem_despesa, :vr_pagto_despesa])
```
"""
function campaign_finance(year::Integer; table::Symbol = :revenue, filer::Symbol = :candidates, kwargs...)
    key = (filer, table)
    haskey(_FINANCE_TYPES, key) || throw(ArgumentError(
        "Combinação inválida: filer = :$filer, table = :$table. `filer`: :candidates ou :parties; " *
        "`table`: :revenue, :revenue_original_donor, :expenses_contracted ou :expenses_paid."))
    elections(year; type = _FINANCE_TYPES[key], kwargs...)
end
