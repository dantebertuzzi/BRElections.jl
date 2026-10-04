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

# ---------------------------------------------------------------------------
# Revalidação do cache
#
# O TSE regera os arquivos com frequência (inclusive de eleições antigas), sem
# mudar a URL. Junto de cada ZIP baixado guardamos os validadores HTTP da
# versão obtida (`ETag`, `Last-Modified`, `Content-Length`) num arquivo
# `<zip>.meta`; antes de reaproveitar o cache, um `HEAD` diz se o TSE publicou
# outra versão.
# ---------------------------------------------------------------------------

const _VALIDATORS = ("etag", "last-modified", "content-length")

_meta_path(dest::AbstractString) = dest * ".meta"

"""
    remote_validators(url) -> (status, Dict{String,String})

Faz um `HEAD` em `url` e devolve o código HTTP (`0` se não houve resposta) e
os cabeçalhos de validação presentes (`etag`, `last-modified`,
`content-length`), com nomes em minúsculas.
"""
function remote_validators(url::AbstractString)
    resp = try
        Downloads.request(url; method = "HEAD", throw = false)
    catch
        nothing
    end
    resp isa Downloads.Response || return (0, Dict{String,String}())
    meta = Dict{String,String}()
    for (k, v) in resp.headers
        key = lowercase(k)
        key in _VALIDATORS && (meta[key] = v)
    end
    (resp.status, meta)
end

function _read_meta(dest::AbstractString)
    path = _meta_path(dest)
    meta = Dict{String,String}()
    isfile(path) || return meta
    for line in eachline(path)
        parts = split(line, '\t'; limit = 2)
        length(parts) == 2 && (meta[String(parts[1])] = String(parts[2]))
    end
    meta
end

function _write_meta(dest::AbstractString, meta::AbstractDict)
    isempty(meta) && return rm(_meta_path(dest); force = true)
    open(_meta_path(dest), "w") do io
        for k in _VALIDATORS
            haskey(meta, k) && println(io, k, '\t', meta[k])
        end
    end
end

const _HTTP_DATE = dateformat"e, dd u yyyy HH:MM:SS \G\M\T"

_parse_http_date(s) = try
    DateTime(strip(s), _HTTP_DATE)
catch
    nothing
end

"""
    _cache_is_stale(local_meta, remote_meta, local_mtime) -> Bool

Decide se o arquivo em cache está desatualizado em relação ao publicado.
Compara `ETag` quando ambos os lados o têm; senão `Last-Modified` e
`Content-Length`. Para caches antigos, sem `.meta`, usa o `Last-Modified`
remoto contra o `mtime` local (`local_mtime`, em `DateTime` UTC). Sem
informação suficiente, considera o cache válido.
"""
function _cache_is_stale(local_meta::AbstractDict, remote_meta::AbstractDict, local_mtime::DateTime)
    if haskey(local_meta, "etag") && haskey(remote_meta, "etag")
        return local_meta["etag"] != remote_meta["etag"]
    end
    for k in ("last-modified", "content-length")
        if haskey(local_meta, k) && haskey(remote_meta, k)
            local_meta[k] != remote_meta[k] && return true
        end
    end
    if isempty(local_meta) && haskey(remote_meta, "last-modified")
        remote = _parse_http_date(remote_meta["last-modified"])
        return remote !== nothing && remote > local_mtime
    end
    false
end

"""
    download_file(url, dest; force = false, check_updates = true, retries = 3, verbose = true) -> String

Baixa `url` para `dest` com cache, escrita atômica (arquivo temporário
`.part` movido ao final) e novas tentativas com *backoff* exponencial.

Se `dest` já existe e `force = false`:

- com `check_updates = true` (padrão), faz um `HEAD` e só baixa de novo se o
  TSE publicou outra versão (`ETag`/`Last-Modified`/`Content-Length`
  diferentes dos guardados em `<dest>.meta`). Sem rede ou com o CDN
  recusando, usa o cache e avisa;
- com `check_updates = false`, usa o cache sem consultar a rede.
"""
function download_file(url::AbstractString, dest::AbstractString;
                       force::Bool = false, check_updates::Bool = true,
                       retries::Int = 3, verbose::Bool = true)
    remote_meta = nothing
    if isfile(dest) && !force
        if !check_updates
            verbose && @info "Cache: usando arquivo já baixado" dest
            return dest
        end
        status, remote_meta = remote_validators(url)
        if !(200 <= status < 300)
            what = status == 404 ? "o arquivo não está mais publicado (HTTP 404)" :
                   status == 0   ? "sem resposta do servidor" :
                                   "o CDN respondeu HTTP $status"
            verbose && @warn "Não foi possível verificar se há versão nova no TSE ($what); " *
                             "usando o arquivo em cache." dest
            return dest
        end
        local_mtime = unix2datetime(mtime(dest))
        if !_cache_is_stale(_read_meta(dest), remote_meta, local_mtime)
            # Cache antigo sem `.meta`: registra os validadores agora, para que
            # as próximas verificações comparem por ETag.
            isfile(_meta_path(dest)) || _write_meta(dest, remote_meta)
            verbose && @info "Cache: arquivo em dia com o TSE" dest
            return dest
        end
        verbose && @info "O TSE publicou uma nova versão; baixando novamente." url get(remote_meta, "last-modified", "?")
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
            # Validadores da versão baixada: reaproveita os do HEAD acima, se
            # houve; senão consulta agora (falha aqui não invalida o download).
            meta = remote_meta === nothing ? last(remote_validators(url)) : remote_meta
            _write_meta(dest, meta)
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
