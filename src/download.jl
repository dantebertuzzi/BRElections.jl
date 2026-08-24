# ---------------------------------------------------------------------------
# Download (stdlib Downloads.jl — sem dependências externas de rede)
# ---------------------------------------------------------------------------

"""
    url_status(url) -> Int

Retorna o código HTTP de uma requisição `HEAD` a `url`, ou `0` se a
requisição sequer chegou a receber resposta (URL inválida, DNS, timeout).

Serve para distinguir situações que `url_exists` colapsa em `false`: um `404`
significa que o arquivo de fato não está publicado, enquanto `403` ou `5xx`
indicam que o CDN do TSE está bloqueando/indisponível e nada pode ser
concluído sobre o arquivo.
"""
function url_status(url::AbstractString)
    try
        resp = Downloads.request(url; method = "HEAD", throw = false)
        resp isa Downloads.Response ? resp.status : 0
    catch
        0
    end
end

"""
    url_exists(url) -> Bool

Verifica via requisição `HEAD` se um arquivo existe no CDN do TSE.
Retorna `false` em caso de erro de rede.

Cuidado: também retorna `false` quando o CDN responde `403`/`5xx`, situação em
que o arquivo pode existir e apenas estar inacessível. Use [`url_status`](@ref)
quando essa diferença importar.
"""
url_exists(url::AbstractString) = 200 <= url_status(url) < 300

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
    # Esgotadas as tentativas: um 403 é o WAF do TSE recusando, não arquivo
    # ausente — vale dizer isso em vez de repassar o RequestError cru.
    if err isa Downloads.RequestError && err.response.status == 403
        throw(ErrorException(
            "O CDN do TSE recusou a requisição (HTTP 403) após $retries tentativas: $url. " *
            "Isso não significa que o arquivo não existe — o TSE bloqueia ou fica " *
            "indisponível de tempos em tempos. Tente novamente mais tarde."))
    end
    throw(err)
end

"""
    available_files(year; ufs = ["PE"]) -> DataFrame

Consulta, via requisições `HEAD`, quais datasets estão publicados no CDN do
TSE para o ano `year`. Para datasets particionados por UF, verifica as UFs
em `ufs` (por padrão apenas uma, para limitar o número de requisições).

Retorna um `DataFrame` com colunas `dataset`, `uf` (`missing` para arquivos
nacionais), `url`, `status` (código HTTP; `0` se não houve resposta) e
`exists`.

A coluna `status` distingue "o arquivo não está publicado" (`404`) de "o CDN
recusou/não respondeu" (`403`, `5xx`, `0`) — nesse segundo caso `exists` é
`false` sem que se possa concluir nada sobre o arquivo.
"""
function available_files(year::Integer; ufs::AbstractVector{<:AbstractString} = ["PE"])
    y = validate_year(year)
    rows = NamedTuple[]
    _row(k, uf, url) = begin
        st = url_status(url)
        (dataset = k, uf = uf, url = url, status = st, exists = 200 <= st < 300)
    end
    for k in sort!(collect(keys(DATASETS)))
        ds = DATASETS[k]
        if ds.by_uf
            for uf in ufs
                push!(rows, _row(k, validate_uf(uf), dataset_url(k, y; uf = uf)))
            end
        else
            push!(rows, _row(k, missing, dataset_url(k, y)))
        end
    end
    DataFrame(rows)
end
