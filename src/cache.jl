# ---------------------------------------------------------------------------
# Cache local
# ---------------------------------------------------------------------------

const _CACHE = Ref{String}("")

function __init__()
    dir = get(ENV, "BRElections_CACHE", "")
    _CACHE[] = isempty(dir) ? @get_scratch!("tse_data") : abspath(dir)
    mkpath(_CACHE[])
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

Remove todo o conteúdo do cache local (ZIPs e CSVs extraídos). Os dados
serão baixados novamente na próxima chamada.
"""
function clear_cache!()
    isdir(_CACHE[]) && rm(_CACHE[]; force = true, recursive = true)
    mkpath(_CACHE[])
    return nothing
end

# Caminho local do ZIP correspondente a uma URL do TSE.
_zip_path(type::Symbol, url::AbstractString) =
    joinpath(cache_dir(), DATASETS[type].dir, basename(url))

# Diretório de extração associado a um ZIP.
_extract_dir(zippath::AbstractString) =
    joinpath(dirname(zippath), first(splitext(basename(zippath))))
