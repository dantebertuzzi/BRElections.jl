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

# Resultados mudam a cada minuto durante a apuração: nunca vão para o cache em
# disco. Em memória fica a última versão de cada URL com o seu ETag, e cada
# consulta pergunta ao TSE se ela mudou (HTTP 304, sem corpo, quando não):
# quem acompanha a apuração consulta a cada poucos segundos sem baixar nada à
# toa, e ainda assim recebe cada versão nova assim que o TSE a publica.
const _LIVE_CACHE = Dict{String,Tuple{String,Any}}()
const _LIVE_LOCK = ReentrantLock()

"Tentativas e espera inicial (s, dobra a cada tentativa) das consultas à Divulgação de Resultados."
const LIVE_RETRIES = Ref(3)
const LIVE_RETRY_DELAY = Ref(0.5)

# Na noite da eleição o CDN do TSE recusa (403, 429) ou falha (5xx, timeout)
# de tempos em tempos: essas respostas são passageiras e valem nova tentativa.
# Arquivo que não existe responde 404 — esse é "não publicado", sem tentar de
# novo.
_transient(status) = status in (403, 408, 429) || status >= 500

function _fetch_live_json(url; retries::Int = LIVE_RETRIES[], timeout = 20)
    cached = lock(() -> get(_LIVE_CACHE, url, nothing), _LIVE_LOCK)
    headers = cached === nothing ? Pair{String,String}[] : ["If-None-Match" => cached[1]]
    err = nothing
    for attempt in 1:retries
        buf = IOBuffer()
        resp = Downloads.request(url; output = buf, headers, timeout, throw = false)
        if resp isa Downloads.Response
            resp.status == 304 && cached !== nothing && return cached[2]
            if 200 <= resp.status < 300
                data = JSON.parse(String(take!(buf)))
                i = findfirst(h -> lowercase(first(h)) == "etag", resp.headers)
                i === nothing || lock(() -> (_LIVE_CACHE[url] = (last(resp.headers[i]), data)), _LIVE_LOCK)
                return data
            end
            resp.status == 404 && throw(ArgumentError(
                "Sem resultado publicado no TSE para esta consulta (HTTP 404): $url. " *
                "Confira se o cargo está em disputa nesse local e nessa eleição."))
            err = ErrorException(
                "A Divulgação de Resultados do TSE respondeu HTTP $(resp.status) após $attempt tentativa(s): $url" *
                (resp.status == 403 ? " (o CDN do TSE recusa requisições de tempos em tempos, " *
                                      "sobretudo nos picos da apuração; tente de novo em instantes)" : ""))
            _transient(resp.status) || throw(err)
        else
            err = resp                                   # falha de rede ou timeout
        end
        attempt < retries && sleep(LIVE_RETRY_DELAY[] * 2.0^(attempt - 1))
    end
    throw(err)
end

# A última versão já baixada de `url`, sem consultar a rede (`nothing` se não há).
_live_cached_json(url) = lock(() -> (c = get(_LIVE_CACHE, url, nothing); c === nothing ? nothing : c[2]), _LIVE_LOCK)

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
            # O TSE marca com "e" = "s" também quem vai ao 2º turno.
            eleito             = get(c, "e", "n") == "s" && !occursin("turno", get(c, "st", "")),
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
        "cd_cargo"              => _toint(carg["cd"]),
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
versão mais recente: nada vai para o cache em disco, e a última versão fica
só em memória, revalidada no TSE a cada chamada (sem baixar de novo o que não
mudou). Depois da totalização, a
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
  Se a eleição dada não tem o cargo no local, vale a do mesmo dia que tenha:
  com o código do 2º turno federal, `:governor` traz o 2º turno estadual.

# Retorno

Um `DataFrame` com uma linha por candidato, em ordem decrescente de votos:
`nr_candidato`, `nm_urna_candidato`, `nm_candidato`, `sg_partido`,
`nm_agremiacao` (coligação/federação), `qt_votos`, `pc_votos` (% dos votos
válidos), `eleito` (só eleitos — quem vai ao 2º turno tem `false`), `ds_situacao` (`"Eleito"`, `"2º turno"`, ... — `missing`
enquanto a apuração não define), `ds_destinacao_voto` e `sq_candidato`.

O resumo da apuração fica nos metadados (`metadata(df)`): `eleicao`,
`cd_eleicao`, `dt_eleicao`, `cargo`, `cd_cargo`, `vagas`, `abrangencia`, `atualizado_em`,
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
    q = _live_query(office; uf, municipality, election)
    verbose && @info "Consultando a Divulgação de Resultados do TSE" eleicao = q.eleicao url = q.url
    _live_fetch(q)
end

# A consulta já resolvida (eleição, município e URL), separada da busca dos
# números: quem acompanha a apuração resolve uma vez — o que consulta o
# catálogo e a lista de municípios — e depois só baixa o JSON de resultados.
function _live_query(office::Union{Symbol,Integer};
                     uf::Union{Nothing,AbstractString} = nothing,
                     municipality::Union{Nothing,Integer,AbstractString} = nothing,
                     election::Union{Nothing,Integer,AbstractString} = nothing)
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
        _explicit_election(config, election, cargo, u, mun === nothing ? nothing : mun.cd_municipio)
    end

    url = _live_results_url(ele.ciclo, ele.ele, cargo, lowercase(u),
                            mun === nothing ? nothing : mun.cd_municipio)
    (url = url, eleicao = ele.nome, cd_eleicao = parse(Int, ele.ele), ciclo = ele.ciclo, dt = ele.dt,
     cargo = cargo, uf = u, cd_municipio = mun === nothing ? nothing : mun.cd_municipio,
     abrangencia = mun === nothing ? nothing : "$(mun.nm_municipio) - $(mun.sg_uf)")
end

# A eleição de código `election` para o cargo e o local. Ela vale como "este
# dia de votação": se não tem o cargo no local, vale a eleição irmã do mesmo
# ciclo e da mesma data que tenha (o 2º turno de governador é uma eleição
# estadual; o de presidente, uma federal).
function _explicit_election(config, election, cargo, u, cd_mun)
    code = string(election)
    found = [(pl, e) for pl in config["pl"] for e in pl["e"] if e["cd"] == code]
    isempty(found) && throw(ArgumentError(
        "Eleição $code não está no catálogo da Divulgação de Resultados do TSE."))
    pl, e = only(found)
    _covers(e, cargo, lowercase(u), cd_mun) && return _election_entry(pl, e)
    siblings = [_election_entry(p2, e2) for p2 in config["pl"] for e2 in p2["e"]
                if p2["c"] == pl["c"] && p2["dt"] == pl["dt"] && _covers(e2, cargo, lowercase(u), cd_mun)]
    isempty(siblings) && throw(ArgumentError(
        "A eleição $code ($(get(e, "nm", ""))) não tem este cargo neste local, nem outra eleição do mesmo dia."))
    first(siblings)
end

_live_fetch(q) = _live_df(q, _fetch_live_json(q.url))

# A última versão já baixada da consulta, marcada com `versao_anterior`
# (`nothing` se nunca foi baixada): o que usar quando uma consulta falha.
function _live_fetch_cached(q)
    data = _live_cached_json(q.url)
    data === nothing && return nothing
    df = _live_df(q, data)
    metadata!(df, "versao_anterior", true; style = :note)
    df
end

function _live_df(q, data)
    df = _parse_live_results(data)
    metadata!(df, "eleicao", q.eleicao; style = :note)
    metadata!(df, "cd_eleicao", q.cd_eleicao; style = :note)
    metadata!(df, "dt_eleicao", q.dt; style = :note)
    metadata!(df, "url", q.url; style = :note)
    q.abrangencia === nothing || metadata!(df, "abrangencia", q.abrangencia; style = :note)
    df
end

"""
    live_dashboard(office = :president; uf = nothing, municipality = nothing,
                   election = nothing, interval = 10, demo = false)

Dashboard no terminal para acompanhar a apuração ao vivo, com os dados de
[`live_results`](@ref) e a tendência de [`projection`](@ref). Duas telas,
alternadas com `Tab`:

- **Apuração** — candidatos com votos, barras, resultado projetado, faixa de
  80% e chance de vitória (no 1º turno e de ir ao 2º, quando há 2º turno);
  quem já está **matematicamente eleito** ou garantido no 2º turno
  ([`clinched`](@ref)); seções totalizadas, comparecimento, válidos,
  brancos, nulos e quanto falta apurar; o andamento por região (quanto já
  foi apurado e quanto do que falta no país está lá); e a diferença entre o
  1º e o 2º ao longo da apuração, com a diferença projetada.
- **Análise** — chance de cada candidato; a distribuição dos cenários
  simulados contra o corte que decide a eleição (50% dos válidos, ou a
  última vaga); de quanto do que falta cada um precisa para virar ou vencer
  no 1º turno; a chance do líder ao longo da apuração; e as UFs ordenadas
  pelo peso do que falta apurar nelas.

Na eleição presidencial do Brasil todo, a tendência é calculada por UF; num
cargo disputado numa UF (Governador, Senador), por município. Num 2º turno,
cada parte parte do seu 1º turno (veja [`live_projection`](@ref)). Os votos
aparecem assim que chegam; a tendência é calculada em seguida, em segundo
plano (na primeira vez num local, baixa o 1º turno de cada parte).

**Tempo real.** O TSE não publica votos um a um: cada urna envia o boletim
da seção inteira, e o TSE republica o resultado agregado conforme os boletins
chegam (com até cerca de um minuto de cache no CDN). O painel consulta a cada
`interval` segundos, só baixando quando há versão nova (ETag); quando ela
chega, os contadores rolam até os números novos (efeito odômetro) em vez de
saltar — sem nunca passar do último número publicado. O cabeçalho mostra o
ritmo da apuração (votos e seções por minuto) e o horário estimado de
término nesse ritmo.

Precisa do [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl), que
não é dependência do pacote: carregue-o antes (`using Tachikoma`).

Os argumentos são os de [`live_results`](@ref); `interval` é o intervalo, em
segundos, entre as consultas ao TSE (no mínimo 5). Depois da totalização
final, o painel deixa de consultar sozinho — `r` ainda força uma consulta.

**Demonstração.** Com `demo = true`, o painel reconstitui a apuração da
eleição presidencial mais recente a partir do resultado final real por UF,
comprimida em cerca de 3 minutos: cada UF começa e avança no seu ritmo (o
Nordeste mais tarde), e o que é apurado primeiro vem enviesado. Os números
intermediários são simulados — o título avisa —; os finais são os do TSE.
Serve para ver o painel funcionando fora do dia da eleição.

# Teclas

| Tecla                 | Ação                                        |
|:----------------------|:--------------------------------------------|
| `Tab` `a`             | alterna entre apuração e análise            |
| `←` `→`               | cargo anterior / seguinte                   |
| `u`                   | trocar a UF (vazio = Brasil)                |
| `m`                   | trocar o município (vazio = a UF inteira)   |
| `r`                   | consultar agora                             |
| `↑` `↓` `PgUp` `PgDn` | rolar a lista de candidatos                 |
| `q` `Esc`             | sair                                        |

# Exemplo

```julia
using BRElections, Tachikoma
live_dashboard()                                  # Presidente, Brasil
live_dashboard(:governor; uf = "SP", interval = 60)
live_dashboard(:mayor; uf = "PE", municipality = "Recife")
live_dashboard(demo = true)                       # apuração simulada, ~3 minutos
```
"""
function live_dashboard(office::Union{Symbol,Integer} = :president;
                        uf::Union{Nothing,AbstractString} = nothing,
                        municipality::Union{Nothing,Integer,AbstractString} = nothing,
                        election::Union{Nothing,Integer,AbstractString} = nothing,
                        interval::Real = 10, demo::Bool = false)
    _office_code(office)                  # erro de uso antes de abrir o painel
    ext = Base.get_extension(@__MODULE__, :BRElectionsTachikomaExt)
    ext === nothing && error("`live_dashboard` precisa do Tachikoma.jl. Carregue-o antes:\n" *
                             "  using Tachikoma\n" *
                             "Se não estiver instalado: using Pkg; Pkg.add(\"Tachikoma\")")
    ext.dashboard(office; uf, municipality, election, interval = max(Float64(interval), 5.0), demo)
end
