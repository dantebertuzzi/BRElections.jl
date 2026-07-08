# ---------------------------------------------------------------------------
# Download (stdlib Downloads.jl — sem dependências externas de rede)
# ---------------------------------------------------------------------------

"""
    url_exists(url) -> Bool

Verifica via requisição `HEAD` se um arquivo existe no CDN do TSE.
Retorna `false` em caso de erro de rede.
"""
function url_exists(url::AbstractString)
    try
        resp = Downloads.request(url; method = "HEAD", throw = false)
        resp isa Downloads.Response && 200 <= resp.status < 300
    catch
        false
    end
end

# Callback de progresso simples (imprime a cada ~10%).
function _progress_callback()
    last_pct = Ref(-10)
    (total, now) -> begin
        total > 0 || return
        pct = floor(Int, 100 * now / total)
        if pct >= last_pct[] + 10
            last_pct[] = pct
            @info "Download: $(pct)% ($(round(now / 2^20; digits = 1)) MiB de $(round(total / 2^20; digits = 1)) MiB)"
        end
        return
    end
end

"""
    download_file(url, dest; force = false, retries = 3, verbose = true) -> String

Baixa `url` para `dest` com cache (retorna imediatamente se `dest` já existe
e `force = false`), escrita atômica (arquivo temporário `.part` movido ao
final) e novas tentativas com *backoff* exponencial.
"""
function download_file(url::AbstractString, dest::AbstractString;
                       force::Bool = false, retries::Int = 3, verbose::Bool = true)
    if isfile(dest) && !force
        verbose && @info "Cache: usando arquivo já baixado" dest
        return dest
    end
    mkpath(dirname(dest))
    tmp = dest * ".part"
    local err
    for attempt in 1:retries
        try
            verbose && @info "Baixando" url attempt
            Downloads.download(url, tmp;
                progress = verbose ? _progress_callback() : nothing)
            mv(tmp, dest; force = true)
            return dest
        catch e
            err = e
            rm(tmp; force = true)
            if e isa Downloads.RequestError && e.response.status == 404
                throw(ArgumentError(
                    "Arquivo não encontrado no TSE (HTTP 404): $url. " *
                    "Verifique o ano, o dataset e a UF — nem toda combinação existe."))
            end
            attempt < retries && begin
                @warn "Falha no download (tentativa $attempt de $retries); tentando novamente." exception = (e, catch_backtrace())
                sleep(2.0^attempt)
            end
        end
    end
    throw(err)
end

"""
    available_files(year; ufs = ["PE"]) -> DataFrame

Consulta, via requisições `HEAD`, quais datasets estão publicados no CDN do
TSE para o ano `year`. Para datasets particionados por UF, verifica as UFs
em `ufs` (por padrão apenas uma, para limitar o número de requisições).

Retorna um `DataFrame` com colunas `dataset`, `uf` (`missing` para arquivos
nacionais), `url` e `exists`.
"""
function available_files(year::Integer; ufs::AbstractVector{<:AbstractString} = ["PE"])
    y = validate_year(year)
    rows = NamedTuple[]
    for k in sort!(collect(keys(DATASETS)))
        ds = DATASETS[k]
        if ds.by_uf
            for uf in ufs
                url = dataset_url(k, y; uf = uf)
                push!(rows, (dataset = k, uf = validate_uf(uf), url = url, exists = url_exists(url)))
            end
        else
            url = dataset_url(k, y)
            push!(rows, (dataset = k, uf = missing, url = url, exists = url_exists(url)))
        end
    end
    DataFrame(rows)
end
