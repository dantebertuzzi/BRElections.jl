# ---------------------------------------------------------------------------
# API pública de alto nível
# ---------------------------------------------------------------------------

"""
    elections(year; type = :candidates, uf = nothing, kwargs...) -> DataFrame

Baixa (com cache), descompacta e importa um dataset eleitoral público do TSE.

# Argumentos

- `year`: ano eleitoral (par, ≥ $(FIRST_YEAR)).
- `type`: dataset — uma das chaves de `available_datasets()`:
  `:candidates`, `:candidate_votes`, `:party_votes`, `:vote_details`,
  `:section_votes`, `:section_vote_details`, `:assets`, `:coalitions`,
  `:vacancies`, `:voter_profile`.
- `uf`: sigla da UF (`"PE"`, `"SP"`, ...). Opcional para datasets nacionais
  (nesse caso importa o Brasil inteiro); **obrigatória** para
  `:section_votes` e `:section_vote_details`, que o TSE publica em um ZIP
  por UF.

# Importação (repassados a [`read_tse_csv`](@ref))

- `columns = nothing`: importa apenas as colunas listadas.
- `filter = nothing`: predicado `row -> Bool` aplicado durante a leitura
  (processamento em *chunks* — só as linhas aprovadas ficam em memória).
- `normalize_names = true`: nomes de colunas em minúsculas.

# Download/cache

- `force = false`: rebaixa o ZIP e reextrai mesmo com cache presente.
- `verbose = true`: mensagens de progresso.

# Exemplos

```julia
# Todas as candidaturas de 2022
cand = elections(2022; type = :candidates)

# Votos nominais em PE, 1º turno, só as colunas de interesse
pe = elections(2022; type = :candidate_votes, uf = "PE",
               columns = ["NR_TURNO", "NM_MUNICIPIO", "NM_URNA_CANDIDATO",
                          "SG_PARTIDO", "QT_VOTOS_NOMINAIS"],
               filter = row -> row.NR_TURNO == 1)

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
                   verbose::Bool = true,
                   ntasks::Int = max(Threads.nthreads(), 1))
    y = validate_year(year)
    t = validate_type(type)
    ds = DATASETS[t]

    url = ds.by_uf ? dataset_url(t, y; uf) : dataset_url(t, y)
    zippath = _zip_path(t, url)
    download_file(url, zippath; force, verbose)
    csvs = extract_csvs(zippath; force)

    # Em ZIPs nacionais, restringe aos arquivos da UF pedida (ou ao _BRASIL).
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
