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

# Nomes das colunas, lidos da primeira linha. O CSV.jl 1.x não aceita funções
# em `types` nem em `select` (a 0.10 aceitava), então as duas coisas são
# resolvidas contra o cabeçalho antes da leitura, com listas e dicionários que
# as duas versões entendem.
function _read_header(path::AbstractString)
    line = open(readline, path)
    Symbol[Symbol(strip(strip(f), '"')) for f in split(line, ';')]
end

# `types`: força String nas colunas de identificadores.
function _string_types(header)
    forced = Dict{Symbol,Type}(n => String for n in header if _force_string(String(n)))
    isempty(forced) ? nothing : forced
end

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

# Campos vazios entre aspas (`""`), que o TSE usa para todo campo vazio. A 0.10
# do CSV.jl os lia como `missing` (pelo `missingstring`); a 1.x os lê como
# texto vazio presente, e um único `""` faz uma coluna de datas ou números
# virar texto. Com a 1.x, troca `""` por `missing` nas colunas de texto e, nas
# que só eram texto por causa deles, refaz a inferência da 0.10: Int, Float64
# ou data `dd/mm/yyyy`. Identificadores forçados como String não são retipados.
const _QUOTED_EMPTY_IS_TEXT = pkgversion(CSV) >= v"1"

function _retype(col::AbstractVector)
    vals = collect(skipmissing(col))
    isempty(vals) && return Vector{Missing}(missing, length(col))
    for parser in (s -> tryparse(Int, s), s -> tryparse(Float64, s),
                   s -> tryparse(Date, s, TSE_DATEFORMAT))
        parsed = map(x -> ismissing(x) ? missing : parser(x), col)
        any(isnothing, parsed) && continue
        T = typeof(parser(first(vals)))
        return any(ismissing, parsed) ? Vector{Union{Missing,T}}(parsed) : Vector{T}(parsed)
    end
    col
end

function _quoted_empty_to_missing!(df::DataFrame)
    _QUOTED_EMPTY_IS_TEXT || return df
    for name in names(df)
        col = df[!, name]
        nonmissingtype(eltype(col)) <: AbstractString || continue
        any(x -> !ismissing(x) && isempty(x), col) || continue
        cleaned = Union{Missing,String}[ismissing(x) || isempty(x) ? missing : String(x) for x in col]
        df[!, name] = _force_string(name) ? cleaned : _retype(cleaned)
    end
    df
end

# Ajustes depois da leitura, antes de qualquer `filter`.
_postprocess!(df::DataFrame) = _convert_money_columns!(_quoted_empty_to_missing!(df))

# `select`: as colunas pedidas que existem no arquivo, sem distinguir
# maiúsculas. Nomes ausentes são ignorados (o CSV.jl 1.x daria erro), o que
# importa ao ler vários anos, em que nem toda coluna existe em todos.
function _select_columns(header, columns)
    wanted = Set(lowercase(String(c)) for c in columns)
    Symbol[n for n in header if lowercase(String(n)) in wanted]
end

function _common_csv_kwargs(path; columns)
    header = _read_header(path)
    (
        delim = ';',
        quotechar = '"',
        missingstring = TSE_MISSING,
        dateformat = TSE_DATEFORMAT,
        stringtype = String,
        pool = (0.2, 500),      # padrão da 0.10; a 1.x passou a não agrupar
        types = _string_types(header),
        select = columns === nothing ? nothing : _select_columns(header, columns),
        validate = false,
    )
end

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
  (`row.NR_TURNO`). Se o arquivo couber com folga na memória livre, é lido
  inteiro e filtrado (mais rápido); senão, é lido em *chunks* (`CSV.Chunks`),
  de modo que apenas as linhas aprovadas ocupam memória.
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
    kw = _common_csv_kwargs(path; columns)

    df = if filter === nothing
        # Em arquivos pequenos, paralelizar não ajuda e o CSV.jl emite aviso.
        _postprocess!(
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
    Base.filter(row -> filter(_AnyCaseRow(row)), _postprocess!(df))

# Com `filter`, ler o arquivo inteiro e filtrar depois é bem mais rápido que
# CSV.Chunks (medido: 0,8 s contra 2,5 s num CSV de 93 MB); os chunks só valem
# para não estourar a memória. Então o arquivo é lido de uma vez se for pequeno
# (o CSV.jl nem consegue particionar arquivos com poucas linhas) ou se couber
# com folga na memória livre: a leitura aloca algumas vezes o tamanho do CSV,
# e o resultado filtrado é mais uma cópia. (`Ref`s para os testes exercitarem
# os dois caminhos.)
const CHUNK_MIN_BYTES = Ref(64 * 2^20)
const FILTER_MEMORY_FACTOR = Ref(6.0)

function _filter_in_memory(path)
    sz = filesize(path)
    sz < CHUNK_MIN_BYTES[] || sz * FILTER_MEMORY_FACTOR[] < Sys.free_memory()
end

# Leitura com filtro: lê inteiro e filtra quando cabe na memória; senão usa
# CSV.Chunks, de modo que só as linhas aprovadas ficam em memória.
function _read_tse_csv_with_filter(path, filter, ntasks, kw)
    if _filter_in_memory(path)
        nt = filesize(path) < PARALLEL_MIN_BYTES ? 1 : ntasks
        return _apply_filter(filter, CSV.read(path, DataFrame; ntasks = nt, kw...))
    end

    # Só a construção do CSV.Chunks fica no `try`: se o CSV.jl não conseguir
    # particionar o arquivo, lê inteiro. Erros durante a iteração — inclusive
    # um ArgumentError do predicado do usuário — são propagados.
    chunks = try
        CSV.Chunks(path; ntasks = clamp(ntasks, 2, 4), kw...)
    catch e
        e isa ArgumentError || rethrow()
        @warn "Falha ao dividir arquivo em chunks; lendo inteiro e filtrando em memória." path exception = e
        nothing
    end
    chunks === nothing &&
        return _apply_filter(filter, CSV.read(path, DataFrame; ntasks = 1, kw...))
    parts = DataFrame[]
    for chunk in chunks
        part = _apply_filter(filter, DataFrame(chunk))
        nrow(part) > 0 && push!(parts, part)
    end
    isempty(parts) ? _empty_like(path, kw) : reduce(vcat, parts; cols = :union)
end

# DataFrame vazio com o esquema do arquivo (usado quando o filtro elimina tudo).
function _empty_like(path, kw)
    df = CSV.read(path, DataFrame; limit = 0, kw...)
    empty!(df)
    _postprocess!(df)
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
