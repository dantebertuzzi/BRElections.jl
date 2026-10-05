# ---------------------------------------------------------------------------
# Cache local
# ---------------------------------------------------------------------------

const _CACHE = Ref{String}("")

function __init__()
    dir = get(ENV, "BRElections_CACHE", "")
    _CACHE[] = isempty(dir) ? @get_scratch!("tse_data") : abspath(dir)
    mkpath(_CACHE[])
    hours = tryparse(Float64, get(ENV, "BRElections_REVALIDATE_HOURS", ""))
    hours === nothing || (REVALIDATE_INTERVAL[] = 3600 * hours)
    return nothing
end

"""
    cache_dir() -> String

Diretório de cache local usado para armazenar os ZIPs baixados do TSE e os
CSVs extraídos (já transcodificados para UTF-8).

Por padrão é um *scratch space* gerenciado por `Scratch.jl` (portável entre
Windows, Linux e macOS). Pode ser sobrescrito pela variável de ambiente
`BRElections_CACHE` ou por [`set_cache_dir!`](@ref).
"""
cache_dir() = _CACHE[]

"""
    set_cache_dir!(dir) -> String

Redefine o diretório de cache em tempo de execução (cria o diretório se
necessário) e o retorna.
"""
function set_cache_dir!(dir::AbstractString)
    _CACHE[] = abspath(dir)
    mkpath(_CACHE[])
    _CACHE[]
end

"""
    clear_cache!()
    clear_cache!(type; year = nothing, extracted_only = false)

Sem argumentos, remove todo o conteúdo do cache local (ZIPs, CSVs extraídos e
arquivos da Divulgação de Resultados). Os dados serão baixados novamente na
próxima chamada.

Com um dataset (`:candidates`, `:candidate_votes`...), remove só os arquivos
dele — de todos os anos, ou só de `year` (um ano ou vários). Com
`extracted_only = true`, mantém os ZIPs e apaga apenas os CSVs extraídos, que
são refeitos a partir do ZIP sem novo download: o CSV extraído costuma ocupar
várias vezes o tamanho do ZIP.

As tabelas de prestação de contas de um mesmo prestador vêm do mesmo ZIP:
limpar uma delas (`:candidate_revenue`, por exemplo) limpa as quatro.

Devolve o espaço liberado, em bytes. Veja [`cache_info`](@ref).

```julia
clear_cache!(:section_votes)                               # todos os anos
clear_cache!(:candidate_votes; year = 2018)
clear_cache!(:candidate_revenue; extracted_only = true)    # mantém o ZIP
```
"""
function clear_cache!()
    isdir(_CACHE[]) && rm(_CACHE[]; force = true, recursive = true)
    mkpath(_CACHE[])
    return nothing
end

function clear_cache!(type::Symbol; year = nothing, extracted_only::Bool = false)
    validate_type(type)
    years = year === nothing ? nothing : Set(Int.(year isa Integer ? (year,) : year))
    ds = DATASETS[type]
    freed = 0
    for entry in _cached_zips()
        entry.dir == ds.dir && entry.prefix == ds.prefix || continue
        years === nothing || entry.year in years || continue
        targets = extracted_only ? [entry.extract_dir] :
                  [entry.path, _meta_path(entry.path), entry.extract_dir]
        for t in targets
            ispath(t) || continue
            freed += _disk_usage(t)
            rm(t; force = true, recursive = true)
        end
    end
    freed
end

_disk_usage(path) = isfile(path) ? filesize(path) :
    isdir(path) ? sum((filesize(joinpath(r, f)) for (r, _, fs) in walkdir(path) for f in fs); init = 0) : 0

# ZIPs no cache que correspondem a algum dataset: `<dir>/<prefixo>_<ano>[_UF].zip`.
function _cached_zips()
    specs = unique((ds.dir, ds.prefix) for ds in values(DATASETS))
    out = NamedTuple[]
    for (dir, prefix) in specs
        d = joinpath(cache_dir(), dir)
        isdir(d) || continue
        rx = Regex("^" * prefix * raw"_(\d{4})(?:_([A-Z]{2}))?\.zip$")
        for f in readdir(d)
            m = match(rx, f)
            m === nothing && continue
            path = joinpath(d, f)
            push!(out, (dir = dir, prefix = prefix, year = parse(Int, m[1]),
                        uf = m[2] === nothing ? missing : String(m[2]),
                        path = path, extract_dir = _extract_dir(path)))
        end
    end
    out
end

"""
    cache_info() -> DataFrame

O que está no cache local, um ZIP por linha: `datasets` (os tipos de
[`elections`](@ref) servidos por ele — as quatro tabelas de prestação de
contas de um prestador compartilham o ZIP), `year`, `uf` (`missing` em ZIPs
nacionais), `zip_mb`, `extracted_mb` (CSVs já extraídos), `checked_at` (última
verificação no TSE, no horário local; `missing` se nunca verificado) e
`path`. Ordenado do maior
para o menor.

Os arquivos da Divulgação de Resultados (usados por [`municipalities`](@ref) e
[`live_results`](@ref)) aparecem numa linha com `datasets = [:municipalities]`.

```julia
info = cache_info()
sum(info.zip_mb .+ info.extracted_mb)     # MB ocupados
```

Para liberar espaço, veja [`clear_cache!`](@ref).
"""
function cache_info()
    mb(x) = round(x / 2^20; digits = 1)
    # mtime é UTC; mostra no horário local, como quem lê a tabela espera.
    offset = round(now() - now(UTC), Minute)
    checked(path) = isfile(_meta_path(path)) ?
        floor(unix2datetime(mtime(_meta_path(path))) + offset, Second) : missing
    rows = map(_cached_zips()) do e
        types = sort!([k for (k, ds) in DATASETS if ds.dir == e.dir && ds.prefix == e.prefix])
        (datasets = types, year = e.year, uf = e.uf, zip_mb = mb(filesize(e.path)),
         extracted_mb = mb(_disk_usage(e.extract_dir)), checked_at = checked(e.path), path = e.path)
    end
    res = joinpath(cache_dir(), "resultados")
    if isdir(res)
        push!(rows, (datasets = [:municipalities], year = missing, uf = missing,
                     zip_mb = mb(_disk_usage(res)), extracted_mb = 0.0, checked_at = missing, path = res))
    end
    df = DataFrame(datasets = Vector{Symbol}[], year = Union{Missing,Int}[], uf = Union{Missing,String}[],
                   zip_mb = Float64[], extracted_mb = Float64[], checked_at = Union{Missing,DateTime}[],
                   path = String[])
    foreach(r -> push!(df, r), rows)
    df[sortperm(df.zip_mb .+ df.extracted_mb; rev = true), :]
end

# Caminho local do ZIP correspondente a uma URL do TSE.
_zip_path(type::Symbol, url::AbstractString) =
    joinpath(cache_dir(), DATASETS[type].dir, basename(url))

# Diretório de extração associado a um ZIP.
_extract_dir(zippath::AbstractString) =
    joinpath(dirname(zippath), first(splitext(basename(zippath))))
