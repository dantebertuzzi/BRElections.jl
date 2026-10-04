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

# Abaixo deste tamanho a leitura sem filtro é feita com uma única task.
const PARALLEL_MIN_BYTES = 2^20

_force_string(name::AbstractString) = any(p -> startswith(uppercase(name), p), STRING_PREFIXES)

# Função `types` passada ao CSV.jl: força String nas colunas de identificadores.
_tse_types(i, name) = _force_string(String(name)) ? String : nothing

# Valores monetários (colunas `VR_*`): o TSE usa vírgula decimal em alguns
# arquivos ("1500,00", prestação de contas e bens) e ponto em outros
# ("1270629.01", dados complementares), então não dá para fixar `decimal` na
# leitura. Colunas `VR_*` que o CSV.jl deixou como texto são convertidas para
# Float64 se todos os valores forem numéricos com um dos dois separadores;
# senão, ficam como estão.
_is_money_column(name) = startswith(lowercase(String(name)), "vr_")

function _parse_money(s::AbstractString)
    t = strip(s)
    tryparse(Float64, count(==(','), t) == 1 && !occursin('.', t) ? replace(t, ',' => '.') : t)
end

function _convert_money_columns!(df::DataFrame)
    for name in names(df)
        _is_money_column(name) || continue
        col = df[!, name]
        nonmissingtype(eltype(col)) <: AbstractString || continue
        parsed = Vector{Union{Missing,Float64}}(undef, length(col))
        ok = true
        for (i, x) in enumerate(col)
            ismissing(x) && (parsed[i] = missing; continue)
            v = _parse_money(x)
            v === nothing && (ok = false; break)
            parsed[i] = v
        end
        ok || continue
        df[!, name] = any(ismissing, parsed) ? parsed : Vector{Float64}(parsed)
    end
    df
end

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
  As colunas podem ser acessadas tanto pelo nome normalizado (`row.nr_turno`,
  o mesmo do `DataFrame` devolvido) quanto pelo original do TSE
  (`row.NR_TURNO`). Em arquivos grandes, a leitura é feita em *chunks*
  (`CSV.Chunks`), de modo que apenas as linhas aprovadas ocupam memória.
- `normalize_names = true`: converte os nomes das colunas para minúsculas.
- `ntasks = Threads.nthreads()`: paralelismo de leitura/chunks.

# Exemplo

```julia
df = read_tse_csv("consulta_cand_2022_PE.csv";
                  columns = [:nr_turno, :nm_urna_candidato, :sg_partido],
                  filter  = row -> row.nr_turno == 1)
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
        # Em arquivos pequenos, paralelizar não ajuda e o CSV.jl emite aviso.
        _convert_money_columns!(
            CSV.read(path, DataFrame; ntasks = filesize(path) < PARALLEL_MIN_BYTES ? 1 : ntasks, kw...))
    else
        _read_tse_csv_with_filter(path, filter, ntasks, kw)
    end

    normalize_names && rename!(lowercase, df)
    df
end

# Linha vista pelo predicado de `filter`: aceita o nome da coluna em qualquer
# caixa (`row.nr_turno` ou `row.NR_TURNO`), já que o DataFrame devolvido usa
# nomes em minúsculas mas o arquivo do TSE os traz em maiúsculas.
struct _AnyCaseRow{R}
    row::R
end

function _column_name(r::_AnyCaseRow, name)
    row = getfield(r, :row)
    s = Symbol(name)
    hasproperty(row, s) && return s
    for alt in (Symbol(lowercase(String(s))), Symbol(uppercase(String(s))))
        hasproperty(row, alt) && return alt
    end
    s  # deixa o DataFrameRow produzir o erro de coluna inexistente
end

Base.getproperty(r::_AnyCaseRow, name::Symbol) = getproperty(getfield(r, :row), _column_name(r, name))
Base.getindex(r::_AnyCaseRow, name::Union{Symbol,AbstractString}) = getfield(r, :row)[_column_name(r, name)]
Base.hasproperty(r::_AnyCaseRow, name::Symbol) = hasproperty(getfield(r, :row), _column_name(r, name))
Base.propertynames(r::_AnyCaseRow) = propertynames(getfield(r, :row))

# Converte os valores monetários antes, para o predicado já ver números.
_apply_filter(filter, df::DataFrame) =
    Base.filter(row -> filter(_AnyCaseRow(row)), _convert_money_columns!(df))

# Abaixo deste tamanho o arquivo é lido de uma vez e filtrado em memória:
# dividi-lo em chunks não economiza nada, e o CSV.jl não consegue particionar
# arquivos com poucas linhas. (`Ref` para os testes exercitarem os dois caminhos.)
const CHUNK_MIN_BYTES = Ref(64 * 2^20)

# Leitura com filtro: em arquivos grandes, usa CSV.Chunks para evitar carregar
# tudo em memória; nos pequenos, lê inteiro e filtra.
function _read_tse_csv_with_filter(path, filter, ntasks, kw)
    filesize(path) < CHUNK_MIN_BYTES[] &&
        return _apply_filter(filter, CSV.read(path, DataFrame; ntasks = 1, kw...))

    parts = DataFrame[]
    try
        for chunk in CSV.Chunks(path; ntasks = clamp(ntasks, 2, 4), kw...)
            part = _apply_filter(filter, DataFrame(chunk))
            nrow(part) > 0 && push!(parts, part)
        end
    catch e
        # Só o caso "não deu para particionar" tem alternativa; qualquer outro
        # ArgumentError (inclusive vindo do predicado do usuário) é propagado.
        e isa ArgumentError && occursin("unable to iterate chunks", e.msg) || rethrow()
        @warn "Falha ao dividir arquivo em chunks; lendo inteiro e filtrando em memória." path
        parts = [_apply_filter(filter, CSV.read(path, DataFrame; ntasks = 1, kw...))]
    end
    isempty(parts) ? _empty_like(path, kw) : reduce(vcat, parts; cols = :union)
end

# DataFrame vazio com o esquema do arquivo (usado quando o filtro elimina tudo).
function _empty_like(path, kw)
    df = CSV.read(path, DataFrame; limit = 0, kw...)
    empty!(df)
    _convert_money_columns!(df)
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
