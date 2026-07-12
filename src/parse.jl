# ---------------------------------------------------------------------------
# Importação de CSVs do TSE
# ---------------------------------------------------------------------------

"Valores sentinela do TSE tratados como `missing`."
const TSE_MISSING = ["#NULO#", "#NE#", "#NULO", "#NE", ""]

"Formato de data usado nos arquivos do TSE."
const TSE_DATEFORMAT = dateformat"dd/mm/yyyy"

# Colunas que devem permanecer como String para preservar zeros à esquerda
# ou por serem identificadores, não quantidades.
const STRING_PREFIXES = ("NR_CPF", "NR_TITULO", "NR_PROCESSO", "NR_PROTOCOLO")

_force_string(name::AbstractString) = any(p -> startswith(uppercase(name), p), STRING_PREFIXES)

# Função `types` passada ao CSV.jl: força String nas colunas de identificadores.
_tse_types(i, name) = _force_string(String(name)) ? String : nothing

# Constrói o `select` do CSV.jl a partir de uma lista de colunas,
# com correspondência insensível a maiúsculas/minúsculas.
function _column_selector(columns)
    wanted = Set(lowercase(String(c)) for c in columns)
    (i, name) -> lowercase(String(name)) in wanted
end

_common_csv_kwargs(; columns) = (
    delim = ';',
    quotechar = '"',
    missingstring = TSE_MISSING,
    dateformat = TSE_DATEFORMAT,
    stringtype = String,
    types = _tse_types,
    select = columns === nothing ? nothing : _column_selector(columns),
    validate = false,
)

"""
    read_tse_csv(path; kwargs...) -> DataFrame

Lê um CSV do TSE (já em UTF-8, como os produzidos por `extract_csvs`) com as
convenções do órgão: separador `;`, aspas `"`, datas `dd/mm/yyyy`,
sentinelas `#NULO#`/`#NE#` convertidas em `missing` e identificadores
(`NR_CPF_*`, `NR_TITULO_*`, ...) preservados como `String`.

# Argumentos nomeados

- `columns = nothing`: vetor de nomes (String/Symbol, sem distinção de
  maiúsculas) a importar — as demais colunas nem são materializadas.
- `filter = nothing`: predicado `row -> Bool` aplicado durante a importação.
  Quando fornecido, o arquivo é lido em *chunks* (`CSV.Chunks`), de modo que
  apenas as linhas aprovadas ocupam memória.
- `normalize_names = true`: converte os nomes das colunas para minúsculas.
- `ntasks = Threads.nthreads()`: paralelismo de leitura/chunks.

# Exemplo

```julia
df = read_tse_csv("consulta_cand_2022_PE.csv";
                  columns = [:NR_TURNO, :NM_URNA_CANDIDATO, :SG_PARTIDO],
                  filter  = row -> row.NR_TURNO == 1)
```
"""
function read_tse_csv(path::AbstractString;
                      columns = nothing,
                      filter::Union{Nothing,Function} = nothing,
                      normalize_names::Bool = true,
                      ntasks::Int = max(Threads.nthreads(), 1))
    isfile(path) || throw(ArgumentError("Arquivo não encontrado: $path"))
    kw = _common_csv_kwargs(; columns)

    df = if filter === nothing
        CSV.read(path, DataFrame; ntasks, kw...)
    else
        _read_tse_csv_with_filter(path, filter, ntasks, kw)
    end

    normalize_names && rename!(lowercase, df)
    df
end

# Leitura com filtro: tenta CSV.Chunks para evitar carregar tudo em memória;
# cai para leitura completa + filter se o arquivo for pequeno demais.
function _read_tse_csv_with_filter(path, filter, ntasks, kw)
    parts = DataFrame[]
    chunk_ntasks = clamp(ntasks, 2, 4)
    try
        for chunk in CSV.Chunks(path; ntasks = chunk_ntasks, kw...)
            part = Base.filter(filter, DataFrame(chunk))
            nrow(part) > 0 && push!(parts, part)
        end
    catch e
        if e isa ArgumentError
            @warn "Falha ao dividir arquivo em chunks; lendo inteiro e filtrando em memória." path
            df_full = CSV.read(path, DataFrame; ntasks = 1, kw...)
            parts = [Base.filter(filter, df_full)]
        else
            rethrow(e)
        end
    end
    isempty(parts) ? _empty_like(path, kw) : reduce(vcat, parts; cols = :union)
end

# DataFrame vazio com o esquema do arquivo (usado quando o filtro elimina tudo).
function _empty_like(path, kw)
    df = CSV.read(path, DataFrame; limit = 0, kw...)
    empty!(df)
    df
end

"""
    read_tse_csvs(paths; kwargs...) -> DataFrame

Lê e concatena verticalmente (`cols = :union`) vários CSVs do TSE — por
exemplo, os arquivos por UF de um mesmo dataset. Aceita os mesmos argumentos
nomeados de [`read_tse_csv`](@ref).
"""
function read_tse_csvs(paths::AbstractVector{<:AbstractString}; kwargs...)
    isempty(paths) && throw(ArgumentError("Lista de arquivos vazia."))
    dfs = [read_tse_csv(p; kwargs...) for p in paths]
    length(dfs) == 1 ? only(dfs) : reduce(vcat, dfs; cols = :union)
end
