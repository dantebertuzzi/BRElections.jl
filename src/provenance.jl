# ---------------------------------------------------------------------------
# Proveniência: de onde veio cada DataFrame e como citá-lo
#
# Os arquivos do TSE são regerados sem mudar de URL, então o mesmo
# `candidates(2022)` pode devolver números diferentes em datas diferentes.
# Cada DataFrame de `elections` leva nos metadados (`metadata(df)`) os ZIPs de
# que veio, a versão publicada (ETag/Last-Modified) e quando foi baixada.
# ---------------------------------------------------------------------------

const _PKG_TITLE = "BRElections.jl: a Julia interface to Brazilian electoral open data (TSE)"
const _PKG_DOI = "10.5281/zenodo.22182707"
const _PKG_URL = "https://github.com/dantebertuzzi/BRElections.jl"

_mtime_utc(path) = isfile(path) ? floor(unix2datetime(mtime(path)), Second) : missing

# Um registro por ZIP lido.
function _source_record(type::Symbol, year::Int, uf, url, zippath, files; columns, filtered::Bool)
    meta = _read_meta(zippath)
    lm = get(meta, "last-modified", nothing)
    published = lm === nothing ? nothing : _parse_http_date(lm)
    (dataset = type, ano = year,
     uf = uf === nothing ? missing : validate_uf(uf),
     url = String(url),
     arquivos = String[basename(f) for f in files],
     publicado_em = published === nothing ? missing : published,
     etag = get(meta, "etag", missing),
     baixado_em = _mtime_utc(zippath),
     verificado_em = _mtime_utc(_meta_path(zippath)),
     colunas = columns === nothing ? missing : String[lowercase(String(c)) for c in columns],
     filtrado = filtered)
end

function _set_provenance!(df::DataFrame, records::AbstractVector)
    metadata!(df, "fonte", "Tribunal Superior Eleitoral (TSE) — Repositório de Dados Eleitorais"; style = :note)
    metadata!(df, "fontes", collect(records); style = :note)
    metadata!(df, "dataset", join(unique(string(r.dataset) for r in records), ", "); style = :note)
    metadata!(df, "versao_brelections", string(pkgversion(@__MODULE__)); style = :note)
    metadata!(df, "versao_julia", string(VERSION); style = :note)
    df
end

function _records(df::AbstractDataFrame)
    "fontes" in metadatakeys(df) || throw(ArgumentError(
        "O DataFrame não tem metadados de proveniência do BRElections. Eles são gravados por " *
        "`elections` e pelos atalhos (`candidates`, `campaign_finance`...); algumas operações " *
        "do DataFrames.jl (`vcat` de tabelas de origens diferentes, por exemplo) os descartam."))
    metadata(df, "fontes")
end

"""
    sources(df) -> DataFrame

De onde vieram os dados de `df`, um ZIP do TSE por linha: `dataset`, `ano`,
`uf`, `url`, `arquivos` (CSVs lidos do ZIP), `publicado_em` (o
`Last-Modified` do TSE, ou seja, a versão do arquivo, em UTC), `etag`,
`baixado_em` (quando o ZIP chegou ao cache, em UTC), `verificado_em` (última
vez em que se confirmou que o cache estava igual ao publicado, em UTC),
`colunas` (o `columns` pedido; `missing` se todas) e `filtrado` (se houve
`filter` na importação — linhas descartadas na leitura não estão em `df`).

Tudo vem de `metadata(df, "fontes")`, gravado por [`elections`](@ref) e pelos
atalhos. Os metadados acompanham `df` em `select`, `subset`, `transform`,
`filter` etc. Veja também [`cite`](@ref).

```julia
cand = candidates(2022; uf = "PE")
sources(cand)
metadata(cand)          # também: "versao_brelections", "versao_julia", "dataset"
```
"""
sources(df::AbstractDataFrame) = DataFrame(_records(df))

const _MESES_ABNT = ("jan.", "fev.", "mar.", "abr.", "maio", "jun.",
                     "jul.", "ago.", "set.", "out.", "nov.", "dez.")

_abnt_date(d) = "$(day(d)) $(_MESES_ABNT[month(d)]) $(year(d))"
_apa_date(d) = "$(monthname(d)) $(day(d)), $(year(d))"

# Data de acesso: a última em que o conteúdo em cache foi confirmado igual ao
# publicado pelo TSE (download ou verificação).
function _accessed(r)
    ds = [d for d in (r.baixado_em, r.verificado_em) if !ismissing(d)]
    isempty(ds) ? missing : Date(maximum(ds))
end

_pub_year(r) = ismissing(r.publicado_em) ? (ismissing(_accessed(r)) ? missing : year(_accessed(r))) :
                                           year(r.publicado_em)

function _data_title(r)
    t = "$(DATASETS[r.dataset].desc) — $(r.ano)"
    ismissing(r.uf) ? t : "$t, $(r.uf)"
end

function _cite_data(r, style)
    y = _pub_year(r)
    yy = ismissing(y) ? "[s.d.]" : string(y)
    acc = _accessed(r)
    if style === :abnt
        s = "BRASIL. Tribunal Superior Eleitoral. Repositório de dados eleitorais: $(_data_title(r)). " *
            "Brasília: TSE, $yy. Disponível em: $(r.url)."
        ismissing(acc) ? s : "$s Acesso em: $(_abnt_date(acc))."
    elseif style === :apa
        yy = ismissing(y) ? "n.d." : yy
        ismissing(acc) ? "Tribunal Superior Eleitoral. ($yy). Repositório de dados eleitorais: $(_data_title(r)) [Data set]. $(r.url)" :
            "Tribunal Superior Eleitoral. ($yy). Repositório de dados eleitorais: $(_data_title(r)) [Data set]. " *
            "Retrieved $(_apa_date(acc)), from $(r.url)"
    else
        key = "tse_$(r.dataset)_$(r.ano)" * (ismissing(r.uf) ? "" : "_$(lowercase(r.uf))")
        fields = ["author = {{Tribunal Superior Eleitoral}}",
                  "title = {Repositório de dados eleitorais: $(_data_title(r))}",
                  "publisher = {TSE}", "address = {Brasília}"]
        ismissing(y) || push!(fields, "year = {$y}")
        push!(fields, "url = {$(r.url)}")
        ismissing(acc) || push!(fields, "urldate = {$(acc)}")
        ismissing(r.etag) || push!(fields, "note = {ETag $(replace(r.etag, '"' => ""))}")
        "@misc{$key,\n  " * join(fields, ",\n  ") * "\n}"
    end
end

function _cite_pkg(version, style)
    if style === :abnt
        "BERTUZZI, Dante. BRElections.jl: a Julia interface to Brazilian electoral open data (TSE). " *
        "Versão $version. [S. l.]: Zenodo, $(_pkg_year()). Software. DOI: $(_PKG_DOI). Disponível em: $(_PKG_URL)."
    elseif style === :apa
        "Bertuzzi, D. ($(_pkg_year())). $(_PKG_TITLE) (Version $version) [Computer software]. Zenodo. https://doi.org/$(_PKG_DOI)"
    else
        "@software{bertuzzi_brelections_$(_pkg_year()),\n" *
        "  author = {Bertuzzi, Dante},\n" *
        "  title = {{BRElections.jl}: a {Julia} interface to {Brazilian} electoral open data ({TSE})},\n" *
        "  year = {$(_pkg_year())},\n  version = {$version},\n  doi = {$(_PKG_DOI)},\n" *
        "  url = {$(_PKG_URL)},\n  note = {Julia package}\n}"
    end
end

# Ano de lançamento da versão instalada, lido do CITATION.cff que acompanha o
# pacote (mantido em dia a cada release).
function _pkg_year()
    path = joinpath(pkgdir(@__MODULE__), "CITATION.cff")
    m = isfile(path) ? match(r"date-released:\s*\"?(\d{4})", read(path, String)) : nothing
    m === nothing ? year(today()) : parse(Int, m[1])
end

"""
    cite(df; style = :abnt) -> String

Referências para citar os dados de `df`: uma para cada arquivo do TSE de que
ele veio, com a versão publicada e a data de acesso tiradas de
[`sources`](@ref), e uma para o BRElections.jl, na versão que os importou.

`style` é `:abnt` (NBR 6023), `:apa` (APA 7) ou `:bibtex`.

A data de acesso é a última em que o arquivo em cache foi baixado ou
confirmado igual ao publicado pelo TSE. A referência do pacote traz o DOI do
projeto (*concept DOI*); num artigo, prefira o DOI da versão usada, listado
no Zenodo.

```julia
cand = candidates(2022; uf = "PE")
print(cite(cand))
print(cite(cand; style = :bibtex))
```
"""
function cite(df::AbstractDataFrame; style::Symbol = :abnt)
    style in (:abnt, :apa, :bibtex) || throw(ArgumentError(
        "Estilo desconhecido: :$style. Opções: :abnt, :apa e :bibtex."))
    records = _records(df)
    version = "versao_brelections" in metadatakeys(df) ? metadata(df, "versao_brelections") :
              string(pkgversion(@__MODULE__))
    refs = String[_cite_data(r, style) for r in records]
    push!(refs, _cite_pkg(version, style))
    join(unique(refs), "\n\n") * "\n"
end
