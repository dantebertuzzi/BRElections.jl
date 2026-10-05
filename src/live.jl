# ---------------------------------------------------------------------------
# Apuração ao vivo (Divulgação de Resultados do TSE)
#
# Durante a apuração, o TSE publica em resultados.tse.jus.br — a fonte do site e
# do app "Resultados" — um JSON por cargo e local, atualizado a cada poucos
# minutos. Depois da totalização esses arquivos continuam no ar, então a mesma
# função serve para consultar o resultado de eleições recentes por município,
# antes de os arquivos consolidados saírem no Portal de Dados Abertos.
# ---------------------------------------------------------------------------

# Cargos com apuração própria: vices e suplentes são eleitos com o titular.
const LIVE_OFFICES = (:president, :governor, :senator, :federal_deputy, :state_deputy,
                      :district_deputy, :mayor, :councillor)

const MUNICIPAL_OFFICES = (OFFICES.mayor, OFFICES.councillor)

function _office_code(office::Symbol)
    if !(office in LIVE_OFFICES)
        haskey(OFFICES, office) && throw(ArgumentError(
            ":$office não tem apuração própria (é eleito junto com o titular); " *
            "consulte o cargo do titular."))
        throw(ArgumentError("Cargo desconhecido: :$office. Opções: " *
                            join((":$k" for k in LIVE_OFFICES), ", ") * "."))
    end
    OFFICES[office]
end
_office_code(office::Integer) = Int(office)

_live_results_url(ciclo, ele, cargo, uf, mun) =
    "$(RESULTADOS_BASE)/$(ciclo)/$(ele)/dados/$(uf)/$(uf)" *
    (mun === nothing ? "" : lpad(mun, 5, '0')) *
    "-c$(lpad(cargo, 4, '0'))-e$(lpad(ele, 6, '0'))-u.json"

# Resultados mudam a cada minuto durante a apuração: nunca vão para o cache.
function _fetch_live_json(url)
    buf = IOBuffer()
    try
        Downloads.download(url, buf; timeout = 60)
    catch e
        if e isa Downloads.RequestError && e.response.status in (403, 404)
            throw(ArgumentError(
                "Sem resultado publicado no TSE para esta consulta (HTTP $(e.response.status)): $url. " *
                "Confira se o cargo está em disputa nesse local e nessa eleição."))
        end
        rethrow()
    end
    JSON.parse(String(take!(buf)))
end

_toint(x) = x === nothing || isempty(x) ? 0 : parse(Int, x)
_tofloat(x) = x === nothing || isempty(x) ? 0.0 : parse(Float64, replace(x, ',' => '.'))
_nonempty(x) = x === nothing || isempty(x) ? missing : String(x)

"""
    _parse_live_results(data) -> DataFrame

Converte o JSON de resultados (`*-u.json`) num `DataFrame` de candidatos, com
o resumo da apuração nos metadados.
"""
function _parse_live_results(data)
    # Esquema fixo: inferir os tipos dos valores daria `Missing` puro, por
    # exemplo, em `ds_situacao` enquanto nenhum candidato tem situação definida.
    df = _empty_live_results()
    for carg in data["carg"], agr in carg["agr"], par in agr["par"], c in par["cand"]
        push!(df, (
            nr_candidato       = _toint(c["n"]),
            nm_urna_candidato  = String(c["nmu"]),
            nm_candidato       = String(c["nm"]),
            sg_partido         = String(par["sg"]),
            nm_agremiacao      = _nonempty(get(agr, "nm", nothing)),
            qt_votos           = _toint(c["vap"]),
            pc_votos           = _tofloat(get(c, "pvapn", c["pvap"])),
            eleito             = get(c, "e", "n") == "s",
            ds_situacao        = _nonempty(get(c, "st", nothing)),
            ds_destinacao_voto = _nonempty(get(c, "dvt", nothing)),
            sq_candidato       = String(c["sqcand"]),
        ))
    end
    sort!(df, :qt_votos; rev = true)

    s, e, v = data["s"], data["e"], data["v"]
    carg = first(data["carg"])
    total = _toint(v["tv"])
    meta = (
        "cargo"                 => String(carg["nmn"]),
        "vagas"                 => _toint(carg["nv"]),
        "abrangencia"           => uppercase(data["cdabr"]),
        "atualizado_em"         => DateTime("$(data["dg"]) $(data["hg"])", dateformat"dd/mm/yyyy HH:MM:SS"),
        "totalizacao_final"     => data["tf"] == "s",
        "secoes"                => _toint(s["ts"]),
        "secoes_totalizadas"    => _toint(s["st"]),
        "pc_secoes_totalizadas" => _tofloat(s["pst"]),
        "eleitorado"            => _toint(e["te"]),
        # Comparecimento e abstenção são relativos ao eleitorado das seções já
        # totalizadas (`est`), não ao eleitorado total — senão o comparecimento
        # pareceria baixo durante toda a apuração.
        "eleitorado_apurado"    => _toint(get(e, "est", "0")),
        "comparecimento"        => _toint(get(e, "c", "0")),
        "abstencao"             => _toint(get(e, "a", "0")),
        "pc_comparecimento"     => _tofloat(get(e, "pc", "0")),
        "pc_abstencao"          => _tofloat(get(e, "pa", "0")),
        "votos"                 => total,
        "votos_validos"         => _toint(v["vv"]),
        "votos_brancos"         => _toint(v["vb"]),
        "votos_nulos"           => _toint(v["tvn"]),
        # O `pvv` do TSE é relativo aos válidos computados (dá 100% durante a
        # apuração); brancos e nulos vêm sobre o total, então usamos essa base.
        "pc_votos_validos"      => total == 0 ? 0.0 : 100 * _toint(v["vv"]) / total,
        "pc_votos_brancos"      => _tofloat(v["pvb"]),
        "pc_votos_nulos"        => _tofloat(v["ptvn"]),
    )
    for (k, val) in meta
        metadata!(df, k, val; style = :note)
    end
    df
end

_empty_live_results() = DataFrame(
    nr_candidato = Int[], nm_urna_candidato = String[], nm_candidato = String[],
    sg_partido = String[], nm_agremiacao = Union{Missing,String}[], qt_votos = Int[],
    pc_votos = Float64[], eleito = Bool[], ds_situacao = Union{Missing,String}[],
    ds_destinacao_voto = Union{Missing,String}[], sq_candidato = String[])

"""
    live_results(office; uf = nothing, municipality = nothing, election = nothing, verbose = true) -> DataFrame

Resultado da apuração direto da Divulgação de Resultados do TSE
(`resultados.tse.jus.br`), a fonte do site e do app "Resultados". Durante a
apuração os números mudam a cada poucos minutos, e cada chamada busca a
versão mais recente — nada é guardado em cache. Depois da totalização, a
função continua servindo para consultar eleições recentes.

# Argumentos

- `office`: o cargo — `:president`, `:governor`, `:senator`,
  `:federal_deputy`, `:state_deputy`, `:district_deputy`, `:mayor`,
  `:councillor` (ou o código numérico do TSE).
- `uf`: sigla da UF. Opcional só para `:president` (nesse caso, o Brasil);
  `"ZZ"` é o exterior.
- `municipality`: restringe a um município — o nome (sem distinção de acentos
  e maiúsculas; um trecho basta se for único na UF), o código TSE ou o código
  IBGE. Obrigatório para `:mayor` e `:councillor`; exige `uf`.
- `election`: código da eleição no TSE, para escolher uma específica. Por
  padrão, usa a eleição mais recente (já realizada) que tenha o cargo e cubra
  o local — então o 2º turno é escolhido automaticamente depois de ocorrer.

# Retorno

Um `DataFrame` com uma linha por candidato, em ordem decrescente de votos:
`nr_candidato`, `nm_urna_candidato`, `nm_candidato`, `sg_partido`,
`nm_agremiacao` (coligação/federação), `qt_votos`, `pc_votos` (% dos votos
válidos), `eleito`, `ds_situacao` (`"Eleito"`, `"2º turno"`, ... — `missing`
enquanto a apuração não define), `ds_destinacao_voto` e `sq_candidato`.

O resumo da apuração fica nos metadados (`metadata(df)`): `eleicao`,
`cd_eleicao`, `cargo`, `vagas`, `abrangencia`, `atualizado_em`,
`totalizacao_final`, `secoes`, `secoes_totalizadas`,
`pc_secoes_totalizadas`, `eleitorado`, `eleitorado_apurado`,
`comparecimento`, `abstencao`, `pc_comparecimento`, `pc_abstencao`,
`votos`, `votos_validos`, `votos_brancos`, `votos_nulos`,
`pc_votos_validos`, `pc_votos_brancos`, `pc_votos_nulos` e `url`.
Comparecimento e abstenção são relativos a `eleitorado_apurado` (o eleitorado
das seções já totalizadas); válidos, brancos e nulos, ao total de votos.

# Exemplos

```julia
pres = live_results(:president)
metadata(pres, "pc_secoes_totalizadas")

live_results(:governor; uf = "PE")
live_results(:president; uf = "SP", municipality = "São Paulo")
live_results(:mayor; uf = "PE", municipality = 2611606)   # código IBGE de Recife
```
"""
function live_results(office::Union{Symbol,Integer};
                      uf::Union{Nothing,AbstractString} = nothing,
                      municipality::Union{Nothing,Integer,AbstractString} = nothing,
                      election::Union{Nothing,Integer,AbstractString} = nothing,
                      verbose::Bool = true)
    cargo = _office_code(office)
    u = uf === nothing ? (cargo == OFFICES.president ? "BR" : nothing) : validate_uf(uf)
    u === nothing && throw(ArgumentError(
        "Informe `uf` para este cargo, por exemplo uf = \"PE\"; sem UF, só :president (Brasil)."))
    if municipality !== nothing && u == "BR"
        throw(ArgumentError("Para filtrar por município, informe a UF, por exemplo uf = \"SP\"."))
    end
    if cargo in MUNICIPAL_OFFICES && municipality === nothing
        throw(ArgumentError("Para :mayor e :councillor, informe `municipality` (e `uf`)."))
    end

    # Município: resolvido pela lista da eleição geral, que tem todos.
    mun = municipality === nothing ? nothing :
        _resolve_municipality(municipalities(; uf = u, verbose = false), municipality)

    config = _fetch_resultados_json(RESULTADOS_CONFIG_URL; force = false, check_updates = true, verbose = false)
    ele = if election === nothing
        _find_election(config, cargo; uf = u,
                       municipality = mun === nothing ? nothing : mun.cd_municipio)
    else
        code = string(election)
        found = [_election_entry(pl, e) for pl in config["pl"] for e in pl["e"] if e["cd"] == code]
        isempty(found) && throw(ArgumentError(
            "Eleição $code não está no catálogo da Divulgação de Resultados do TSE."))
        only(found)
    end

    url = _live_results_url(ele.ciclo, ele.ele, cargo, lowercase(u),
                            mun === nothing ? nothing : mun.cd_municipio)
    verbose && @info "Consultando a Divulgação de Resultados do TSE" eleicao = ele.nome url
    df = _parse_live_results(_fetch_live_json(url))

    metadata!(df, "eleicao", ele.nome; style = :note)
    metadata!(df, "cd_eleicao", parse(Int, ele.ele); style = :note)
    metadata!(df, "url", url; style = :note)
    mun === nothing ||
        metadata!(df, "abrangencia", "$(mun.nm_municipio) - $(mun.sg_uf)"; style = :note)
    df
end
