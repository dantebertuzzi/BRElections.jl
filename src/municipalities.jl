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

"""
    _latest_general_election(config) -> (ciclo, cd_eleicao)

Procura, no catálogo `ele-c.json`, a eleição mais recente com o cargo de
Presidente, isto é, a eleição geral (federal).
"""
function _latest_general_election(config)
    best = nothing
    for pl in config["pl"], e in pl["e"]
        has_president = any(e["abr"]) do abr
            any(cp -> parse(Int, cp["cd"]) == CARGO_PRESIDENTE, get(abr, "cp", ()))
        end
        has_president || continue
        dt = Date(pl["dt"], dateformat"dd/mm/yyyy")
        (best === nothing || dt > best.dt) && (best = (ciclo = pl["c"], ele = e["cd"], dt = dt))
    end
    best === nothing && error(
        "Nenhuma eleição geral encontrada no catálogo da Divulgação de Resultados do TSE " *
        "($(RESULTADOS_CONFIG_URL)); o formato do arquivo pode ter mudado.")
    (best.ciclo, best.ele)
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
