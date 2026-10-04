# ---------------------------------------------------------------------------
# Municípios: correspondência entre os códigos do TSE e do IBGE
#
# Os arquivos do TSE identificam o município pelo código próprio do tribunal
# (`cd_municipio`), não pelo do IBGE — o que impede cruzar os dados eleitorais
# com Censo, PIB municipal etc. sem uma tabela de correspondência. A fonte é a
# lista de municípios da Divulgação de Resultados (resultados.tse.jus.br) da
# eleição geral (federal) mais recente: ela cobre todos os municípios, inclusive
# Brasília e Fernando de Noronha, que ficam de fora das eleições municipais, e
# as cidades do exterior onde há votação.
# ---------------------------------------------------------------------------

"URL base da Divulgação de Resultados do TSE."
const RESULTADOS_BASE = "https://resultados.tse.jus.br/oficial"

"Arquivo de configuração com o catálogo de eleições da Divulgação de Resultados."
const RESULTADOS_CONFIG_URL = "$(RESULTADOS_BASE)/comum/config/ele-c.json"

"Código do cargo de Presidente na Divulgação de Resultados."
const CARGO_PRESIDENTE = 1

_resultados_path(url::AbstractString) =
    joinpath(cache_dir(), "resultados", replace(url, RESULTADOS_BASE * "/" => ""))

function _fetch_resultados_json(url; force, check_updates, verbose)
    path = download_file(url, _resultados_path(url); force, check_updates, verbose)
    JSON.parse(read(path, String))
end

# Uma eleição do catálogo `ele-c.json`, já com a data convertida.
_election_entry(pl, e) = (ciclo = pl["c"], ele = e["cd"], nome = get(e, "nm", ""),
                          dt = Date(pl["dt"], dateformat"dd/mm/yyyy"), abr = e["abr"])

_has_office(abr, cargo::Int) = any(cp -> parse(Int, cp["cd"]) == cargo, get(abr, "cp", ()))

"""
    _find_election(config, cargo; uf = nothing, municipality = nothing, today = today()) -> NamedTuple

Escolhe, no catálogo `ele-c.json`, a eleição mais recente que tenha o cargo
`cargo` e cubra o local pedido. Uma abrangência cobre o local se for `br`, ou
a própria UF; quando ela lista municípios (2º turno municipal, eleições
suplementares), o município (código TSE) precisa estar na lista — e, sem
município, ela não serve.

Eleições com data posterior a `today` só são escolhidas se não houver
nenhuma já realizada (evita trocar o 1º turno por um 2º turno ainda zerado).
Devolve `(ciclo, ele, nome, dt, abr)`.
"""
function _find_election(config, cargo::Int;
                        uf::Union{Nothing,AbstractString} = nothing,
                        municipality::Union{Nothing,Integer} = nothing,
                        today::Date = Dates.today())
    u = uf === nothing ? nothing : lowercase(uf)
    covers(abr) = begin
        _has_office(abr, cargo) || return false
        abr["cd"] == "br" && return true
        (u === nothing || abr["cd"] != u) && return false
        muns = get(abr, "mu", ())
        isempty(muns) && return true
        municipality !== nothing && any(m -> parse(Int, m["cd"]) == municipality, muns)
    end
    found = [_election_entry(pl, e) for pl in config["pl"] for e in pl["e"] if any(covers, e["abr"])]
    isempty(found) && throw(ArgumentError(
        "Nenhuma eleição com o cargo $cargo" *
        (u === nothing ? "" : " em $(uppercase(u))") *
        (municipality === nothing ? "" : " (município $municipality)") *
        " no catálogo da Divulgação de Resultados do TSE ($(RESULTADOS_CONFIG_URL))."))
    past = filter(x -> x.dt <= today, found)
    isempty(past) ? argmin(x -> x.dt, found) : argmax(x -> x.dt, past)
end

"""
    _latest_general_election(config) -> (ciclo, cd_eleicao)

A eleição geral (federal) mais recente: a que tem o cargo de Presidente.
"""
function _latest_general_election(config)
    e = try
        _find_election(config, CARGO_PRESIDENTE; today = typemax(Date))
    catch err
        err isa ArgumentError || rethrow()
        error("Nenhuma eleição geral encontrada no catálogo da Divulgação de Resultados " *
              "do TSE ($(RESULTADOS_CONFIG_URL)); o formato do arquivo pode ter mudado.")
    end
    (e.ciclo, e.ele)
end

_municipalities_url(ciclo, ele) =
    "$(RESULTADOS_BASE)/$(ciclo)/$(ele)/config/mun-e$(lpad(ele, 6, '0'))-cm.json"

"""
    _parse_municipalities(data) -> DataFrame

Converte o JSON de municípios (`mun-e*-cm.json`) num `DataFrame`.
"""
function _parse_municipalities(data)
    sg_uf = String[]
    cd_municipio = Int[]
    cd_municipio_ibge = Union{Missing,Int}[]
    nm_municipio = String[]
    capital = Bool[]
    zonas = Vector{Int}[]
    for abr in data["abr"], mu in abr["mu"]
        push!(sg_uf, uppercase(abr["cd"]))
        push!(cd_municipio, parse(Int, mu["cd"]))
        # Cidades do exterior (UF "ZZ") não têm código IBGE.
        cdi = get(mu, "cdi", "")
        push!(cd_municipio_ibge, isempty(cdi) ? missing : parse(Int, cdi))
        push!(nm_municipio, mu["nm"])
        push!(capital, get(mu, "c", "n") == "s")
        push!(zonas, sort!([parse(Int, z) for z in get(mu, "z", ())]))
    end
    df = DataFrame(; sg_uf, cd_municipio, cd_municipio_ibge, nm_municipio, capital, zonas)
    sort!(df, [:sg_uf, :nm_municipio])
end

"""
    municipalities(; uf = nothing, force = false, check_updates = true, verbose = true) -> DataFrame

Tabela de municípios com a correspondência entre o código do TSE e o do IBGE.

Os arquivos do TSE identificam o município pela coluna `cd_municipio`, um
código próprio do tribunal. Para cruzar os dados eleitorais com bases que usam
o código do IBGE (Censo, PIB municipal, IDH…), junte por essa coluna e use
`cd_municipio_ibge`.

# Colunas

- `sg_uf`: sigla da UF (`"ZZ"` para o exterior).
- `cd_municipio`: código do município no TSE.
- `cd_municipio_ibge`: código de 7 dígitos do IBGE (`missing` no exterior).
- `nm_municipio`: nome, em maiúsculas, como nos arquivos do TSE.
- `capital`: se é capital da UF.
- `zonas`: números das zonas eleitorais do município.

A lista vem da Divulgação de Resultados do TSE (`resultados.tse.jus.br`),
referente à eleição geral mais recente, e fica em cache como os demais
arquivos (`force`, `check_updates` e `verbose` funcionam como em
[`elections`](@ref)).

# Argumentos

- `uf = nothing`: restringe a uma UF (`"PE"`, `"ZZ"`, ...).

# Exemplo

```julia
mun = municipalities()

votos = candidate_votes(2022; uf = "PE")
votos = leftjoin(votos, select(mun, :cd_municipio, :cd_municipio_ibge); on = :cd_municipio)
```
"""
function municipalities(; uf::Union{Nothing,AbstractString} = nothing,
                        force::Bool = false, check_updates::Bool = true, verbose::Bool = true)
    u = uf === nothing ? nothing : validate_uf(uf)
    u == "BR" && throw(ArgumentError("Use `uf = nothing` para todos os municípios do país."))

    config = _fetch_resultados_json(RESULTADOS_CONFIG_URL; force, check_updates, verbose)
    ciclo, ele = _latest_general_election(config)
    data = _fetch_resultados_json(_municipalities_url(ciclo, ele); force, check_updates, verbose)

    df = _parse_municipalities(data)
    u === nothing ? df : subset(df, :sg_uf => ByRow(==(u)))
end

_normalize_name(s) = Unicode.normalize(strip(s); stripmark = true, casefold = true)

"""
    _resolve_municipality(mun, query) -> DataFrameRow

Acha `query` na tabela `mun` (de [`municipalities`](@ref), já restrita a uma
UF). `query` pode ser o código TSE, o código IBGE (7 dígitos) ou o nome —
sem distinção de acentos e maiúsculas; um trecho do nome basta se for único.
"""
function _resolve_municipality(mun::AbstractDataFrame, query::Union{Integer,AbstractString})
    uf = isempty(mun) ? "?" : first(mun.sg_uf)
    q = query isa AbstractString ? strip(query) : query
    hits = if q isa Integer || all(isdigit, q)
        code = q isa Integer ? q : parse(Int, q)
        findall(r -> r.cd_municipio == code || isequal(r.cd_municipio_ibge, code), eachrow(mun))
    else
        name = _normalize_name(q)
        names = _normalize_name.(mun.nm_municipio)
        exact = findall(==(name), names)
        isempty(exact) ? findall(n -> occursin(name, n), names) : exact
    end
    isempty(hits) && throw(ArgumentError("Município \"$query\" não encontrado em $uf."))
    if length(hits) > 1
        options = join(("  $(r.cd_municipio)  $(r.nm_municipio)" for r in eachrow(mun[first(hits, 15), :])), "\n")
        throw(ArgumentError("\"$query\" é ambíguo em $uf ($(length(hits)) municípios). " *
                            "Use o nome completo ou o código:\n$options"))
    end
    mun[only(hits), :]
end
