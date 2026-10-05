# ---------------------------------------------------------------------------
# API pública de alto nível
# ---------------------------------------------------------------------------

"""
    elections(year; type = :candidates, uf = nothing, kwargs...) -> DataFrame

Baixa (com cache), descompacta e importa um dataset eleitoral público do TSE.

# Argumentos

- `year`: ano eleitoral (par, ≥ $(FIRST_YEAR)), ou vários anos (`2014:4:2022`,
  `[2018, 2022]`) — veja "Vários anos" abaixo.
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

# Vários anos

Com um vetor ou intervalo de anos, cada ano é importado como acima e os
resultados são empilhados, com uma coluna `ano` na frente. Todos os anos são
validados antes de qualquer download.

- Colunas que só existem em alguns anos (o TSE acrescenta e remove campos
  com o tempo) vêm como `missing` nos demais.
- Uma coluna com tipos incompatíveis entre os anos (texto num, número
  noutro) vira texto; números de tipos diferentes são promovidos.
- Colunas renomeadas pelo TSE são unificadas pelo nome atual (veja
  `COLUMN_ALIASES`; hoje, `NM_EMAIL` → `DS_EMAIL`). Pedir o nome atual em
  `columns` traz também o antigo.

```julia
cand = candidates(2014:4:2022; uf = "PE", columns = [:nr_turno, :ds_cargo, :sg_partido])
combine(groupby(cand, [:ano, :sg_partido]), nrow => :candidaturas)
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

    df = read_tse_csvs(files; columns, filter, normalize_names, ntasks)
    _set_provenance!(df, [_source_record(t, y, uf, url, zippath, files;
                                         columns, filtered = filter !== nothing)])
end

# --- Vários anos --------------------------------------------------------

"""
Colunas renomeadas pelo TSE entre os anos: nome antigo => nome atual (em
maiúsculas, como nos arquivos). Ao empilhar vários anos, o nome antigo é
trocado pelo atual.
"""
const COLUMN_ALIASES = Dict(
    "NM_EMAIL" => "DS_EMAIL",          # consulta_cand até 2016
)

# Nomes antigos que também devem ser lidos quando `columns` pede o atual.
function _expand_aliases(columns)
    columns === nothing && return nothing
    wanted = Set(uppercase(String(c)) for c in columns)
    extra = [old for (old, new) in COLUMN_ALIASES if new in wanted && !(old in wanted)]
    isempty(extra) ? columns : vcat(collect(columns), extra)
end

function _apply_aliases!(df::DataFrame)
    for (old, new) in COLUMN_ALIASES, (o, n) in ((old, new), (lowercase(old), lowercase(new)))
        o in names(df) && !(n in names(df)) && rename!(df, o => n)
    end
    df
end

# Colunas com tipos incompatíveis entre os anos viram texto, para o `vcat`
# não produzir uma coluna `Any`. Números de tipos diferentes ficam como estão
# (o `vcat` os promove).
function _harmonize_types!(dfs::AbstractVector{DataFrame})
    for name in unique(Iterators.flatten(names.(dfs)))
        types = unique(nonmissingtype(eltype(df[!, name])) for df in dfs if name in names(df))
        types = Base.filter(!=(Union{}), types)          # colunas só com `missing`
        (length(types) <= 1 || all(T -> T <: Real, types)) && continue
        for df in dfs
            name in names(df) || continue
            col = df[!, name]
            nonmissingtype(eltype(col)) <: AbstractString && continue
            df[!, name] = [ismissing(x) ? missing : string(x) for x in col]
        end
    end
    dfs
end

function elections(years::AbstractVector{<:Integer};
                   type::Symbol = :candidates,
                   uf::Union{Nothing,AbstractString} = nothing,
                   columns = nothing,
                   normalize_names::Bool = true,
                   verbose::Bool = true,
                   kwargs...)
    isempty(years) && throw(ArgumentError("Informe ao menos um ano."))
    ys = sort!(unique(Int.(years)))
    t = validate_type(type)
    # Valida tudo antes de baixar qualquer coisa: um ano inválido no fim da
    # lista não deve desperdiçar os downloads dos anteriores.
    for y in ys
        DATASETS[t].by_uf ? dataset_url(t, y; uf) : dataset_url(t, y)
    end
    uf === nothing || validate_uf(uf)

    cols = _expand_aliases(columns)
    dfs = DataFrame[]
    records = NamedTuple[]
    for y in ys
        verbose && @info "Ano $y ($(findfirst(==(y), ys)) de $(length(ys)))"
        df = elections(y; type = t, uf, columns = cols, normalize_names, verbose, kwargs...)
        append!(records, metadata(df, "fontes"))
        _apply_aliases!(df)
        insertcols!(df, 1, (normalize_names ? "ano" : "ANO") => fill(y, nrow(df)))
        push!(dfs, df)
    end
    # O `vcat` descarta metadados que diferem entre as tabelas, como as fontes.
    _set_provenance!(reduce(vcat, _harmonize_types!(dfs); cols = :union), records)
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

        $($desc). Atalho para `elections(year; type = :$($dtype), kwargs...)`;
        `year` pode ser um ano ou vários (`2014:4:2022`).
        """
        $fname(year::Union{Integer,AbstractVector{<:Integer}}; kwargs...) =
            elections(year; type = $(QuoteNode(dtype)), kwargs...)
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
function campaign_finance(year::Union{Integer,AbstractVector{<:Integer}}; table::Symbol = :revenue, filer::Symbol = :candidates, kwargs...)
    key = (filer, table)
    haskey(_FINANCE_TYPES, key) || throw(ArgumentError(
        "Combinação inválida: filer = :$filer, table = :$table. `filer`: :candidates ou :parties; " *
        "`table`: :revenue, :revenue_original_donor, :expenses_contracted ou :expenses_paid."))
    elections(year; type = _FINANCE_TYPES[key], kwargs...)
end
