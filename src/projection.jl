# ---------------------------------------------------------------------------
# Projeção da apuração: quem já está matematicamente eleito, e a tendência
# (resultado projetado e chance de vitória) a partir do que já foi apurado.
#
# A apuração não avança por igual: estados e regiões terminam em horas
# diferentes — no Nordeste ela costuma acabar mais tarde —, e o eleitorado que
# falta apurar não vota como o já apurado. Por isso a projeção é feita por
# estrato (UF, na eleição presidencial): os votos que faltam em cada UF são
# distribuídos segundo o perfil daquela UF, pesados pelo eleitorado que falta
# lá. Num 2º turno, a UF que apurou pouco parte do seu resultado no 1º turno,
# corrigido pelo deslocamento já observado nas UFs mais apuradas — a
# transferência dos votos de quem foi eliminado.
# ---------------------------------------------------------------------------

"Região de cada UF (`ZZ`, o exterior, é uma região à parte)."
const REGIONS = Dict(
    "AC" => "Norte", "AM" => "Norte", "AP" => "Norte", "PA" => "Norte", "RO" => "Norte",
    "RR" => "Norte", "TO" => "Norte",
    "AL" => "Nordeste", "BA" => "Nordeste", "CE" => "Nordeste", "MA" => "Nordeste",
    "PB" => "Nordeste", "PE" => "Nordeste", "PI" => "Nordeste", "RN" => "Nordeste",
    "SE" => "Nordeste",
    "DF" => "Centro-Oeste", "GO" => "Centro-Oeste", "MS" => "Centro-Oeste", "MT" => "Centro-Oeste",
    "ES" => "Sudeste", "MG" => "Sudeste", "RJ" => "Sudeste", "SP" => "Sudeste",
    "PR" => "Sul", "RS" => "Sul", "SC" => "Sul",
    "ZZ" => "Exterior",
)

# Cargos com 2º turno possível (prefeito, só acima de 200 mil eleitores) e
# cargos proporcionais, em que a vaga depende do quociente eleitoral.
const _RUNOFF_OFFICES = (OFFICES.president, OFFICES.governor, OFFICES.mayor)
const _PROPORTIONAL_OFFICES = (OFFICES.federal_deputy, OFFICES.state_deputy,
                               OFFICES.district_deputy, OFFICES.councillor)
const RUNOFF_MIN_VOTERS = 200_000

# Regra de decisão do resultado de `live_results`:
#  :majority     — maioria absoluta dos válidos, senão 2º turno;
#  :plurality    — os `vagas` mais votados (senado, prefeito em cidade menor, 2º turno);
#  :proportional — depende do quociente eleitoral (não projetamos vagas).
function _rule(df::AbstractDataFrame)
    cargo = metadata(df, "cd_cargo")
    cargo in _PROPORTIONAL_OFFICES && return :proportional
    runoff_round = occursin(r"2º turno"i, metadata(df, "eleicao", ""))
    small_town = cargo == OFFICES.mayor && metadata(df, "eleitorado") <= RUNOFF_MIN_VOTERS
    cargo in _RUNOFF_OFFICES && !runoff_round && !small_town ? :majority : :plurality
end

# Candidatos cujos votos contam (os "anulados sub judice" não podem vencer).
_eligible(df) = [!occursin("Anulado", coalesce(d, "")) for d in df.ds_destinacao_voto]

# Eleitorado das seções ainda não totalizadas.
_remaining(md) = max(md["eleitorado"] - md["eleitorado_apurado"], 0)

"""
    clinched(df) -> Vector{Symbol}

Para cada candidato de um resultado de [`live_results`](@ref), na mesma
ordem, o que a matemática já garante, supondo o pior caso — todo o eleitorado
das seções ainda não totalizadas comparece e vota contra ele:

- `:elected` — eleito, aconteça o que acontecer no resto da apuração;
- `:runoff` — no mínimo vai ao 2º turno (ainda pode vencer no 1º);
- `:open` — nada garantido ainda.

Em cargos com 2º turno (Presidente, Governador e Prefeito de município com
mais de 200 mil eleitores), está eleito quem tem mais da metade dos votos
válidos possíveis. Nos demais (Senador, Prefeito de cidade menor, 2º turno),
quem não pode mais ser alcançado por candidatos suficientes para tirar-lhe a
vaga. Em cargos proporcionais (deputados, vereador) a vaga depende do
quociente eleitoral, e tudo fica `:open`.

```julia
pres = live_results(:president)
pres[clinched(pres) .== :elected, :nm_urna_candidato]
```
"""
function clinched(df::AbstractDataFrame)
    out = fill(:open, nrow(df))
    rule = _rule(df)
    rule === :proportional && return out
    md = metadata(df)
    R = _remaining(md)
    V = md["votos_validos"]
    seats = md["vagas"]
    v = df.qt_votos
    ok = _eligible(df)
    for i in eachindex(v)
        ok[i] || continue
        # Quantos outros ainda podem chegar aos votos de i.
        rivals = count(j -> j != i && ok[j] && v[j] + R >= v[i], eachindex(v))
        if rule === :plurality
            rivals < seats && (out[i] = :elected)
        elseif 2 * v[i] > V + R
            out[i] = :elected
        elseif rivals < 2 && all(j -> j == i || !ok[j] || 2 * (v[j] + R) <= V + R, eachindex(v))
            out[i] = :runoff        # entre os dois primeiros, e ninguém mais vence no 1º turno
        end
    end
    out
end

# --- Simulação -----------------------------------------------------------

# Gama(α, 1) por Marsaglia–Tsang, para não depender do Distributions.jl.
function _randgamma(rng, α::Float64)
    α < 1 && return _randgamma(rng, α + 1) * rand(rng)^(1 / α)
    d = α - 1 / 3
    c = 1 / sqrt(9d)
    while true
        x = randn(rng)
        v = (1 + c * x)^3
        v <= 0 && continue
        log(rand(rng)) < x^2 / 2 + d - d * v + d * log(v) && return d * v
    end
end

function _randdirichlet!(out, rng, α)
    for i in eachindex(α)
        out[i] = _randgamma(rng, α[i])
    end
    s = sum(out)
    s > 0 ? (out ./= s) : fill!(out, 1 / length(out))
end

_normalize(x) = (s = sum(x); s > 0 ? x ./ s : fill(1 / length(x), length(x)))

"""
Parâmetros da projeção (veja [`projection`](@ref)):

- `prior`: peso, em "seções fictícias", da referência de um estrato quando
  ela é o resultado geral apurado até aqui — quanto maior, mais a projeção
  confia nela contra o que o estrato já apurou;
- `prior_previous`: o mesmo, quando a referência é o turno anterior do
  próprio estrato (bem mais informativa);
- `observed`: peso do que o estrato já apurou, quando ele está 100% apurado
  (cresce com a fração apurada);
- `shift`, `shift_previous`: desvio comum a todos os estratos, em escala
  logarítmica — o erro que não se cancela entre estados (o eleitorado que
  falta é diferente do já apurado em todo lugar ao mesmo tempo). Com o turno
  anterior, o deslocamento comum já é medido, e sobra menos.

Calibrados em apurações reconstituídas com os dados reais de 2022 por zona
eleitoral (`dev/calibrate_projection.jl`): zonas reais contadas em ordens
diferentes (capitais primeiro, por último, ao acaso; Nordeste atrasado ou
não). Nesses cenários, a faixa de 80% contém o resultado final em 81% a 96%
das vezes em cada fase da apuração. No 2º turno, com o 1º turno de cada UF, o
erro médio do resultado projetado é de 0,9 ponto com menos de 30% apurado e
de 0,1 acima de 80%, e a chance dada ao vencedor real fica acima de 50% desde
o início; a extrapolação do total nacional erra 4 pontos no começo e aponta o
perdedor até 80% da apuração. Uma eleição só é pouca base: os valores
erram para o lado da cautela.
"""
const PROJECTION_PARAMS = (prior = 5.0, prior_previous = 150.0, observed = 160.0, shift = 0.12, shift_previous = 0.08)

"""
    projection(df; strata = nothing, previous = nothing, nsims = 4000, rng) -> DataFrame

Tendência da apuração: o resultado projetado de cada candidato e a chance de
vitória, por simulação (`nsims` cenários) dos votos que faltam apurar.

- `df`: o resultado de [`live_results`](@ref) do local todo.
- `strata`: resultados da mesma eleição por partes do local (as UFs, na
  eleição presidencial), que juntas formam `df`. Os votos que faltam em cada
  parte seguem o perfil dela e o eleitorado que falta lá: é o que capta o
  atraso de estados e regiões. Sem `strata`, o local é um bloco só.
- `previous`: os resultados do 1º turno nas mesmas partes (na mesma ordem de
  `strata`, ou só o do local todo sem `strata`). Num 2º turno, a parte que
  apurou pouco parte do seu 1º turno, corrigido pelo deslocamento já
  observado nas partes mais apuradas.

Devolve, por candidato, ordenado pelo resultado projetado: `nr_candidato`,
`nm_urna_candidato`, `sg_partido`, `pc_votos` (atual), `pc_projetado`
(mediana dos cenários, % dos válidos), `pc_min` e `pc_max` (faixa de 80%
dos cenários), `p_vitoria` (chance de ser eleito — no 1º turno, se houver 2º),
`p_segundo_turno` (chance de ir ao 2º turno; `missing` se não houver) e
`garantido` (de [`clinched`](@ref)). Nos metadados: `regra` (`"majority"`,
`"plurality"` ou `"proportional"`), `estratos`, `usa_turno_anterior`,
`validos_restantes` (votos válidos que se espera ainda apurar) e `cenarios`
(os cenários simulados: `nr_candidato` e a matriz `pc`, cenários × candidatos). Em cargos proporcionais, as chances
são `missing`: a vaga depende do quociente eleitoral.

É um modelo simples, transparente e sem pesquisas: diz para onde aponta a
apuração, não o que vai acontecer. Os parâmetros estão em
[`PROJECTION_PARAMS`](@ref BRElections.PROJECTION_PARAMS). Veja também
[`live_projection`](@ref), que busca tudo isso no TSE.
"""
function projection(df::AbstractDataFrame;
                    strata::Union{Nothing,AbstractVector} = nothing,
                    previous::Union{Nothing,AbstractDataFrame,AbstractVector} = nothing,
                    nsims::Integer = 4000,
                    rng::AbstractRNG = Random.default_rng(),
                    params = PROJECTION_PARAMS)
    ok = _eligible(df)
    cands = df[ok, :]
    n = nrow(cands)
    index = Dict(nr => i for (i, nr) in enumerate(cands.nr_candidato))
    strata = strata === nothing ? [df] : strata
    previous isa AbstractDataFrame && (previous = [previous])
    previous === nothing || length(previous) == length(strata) || throw(ArgumentError(
        "`previous` deve ter um resultado para cada estrato ($(length(strata))), na mesma ordem."))

    votes_of(d) = begin
        v = zeros(n)
        for (nr, q, e) in zip(d.nr_candidato, d.qt_votos, _eligible(d))
            i = get(index, nr, 0)
            e && i > 0 && (v[i] += q)
        end
        v
    end

    # Por estrato: votos apurados, fração apurada, eleitorado que falta e
    # quantos votos válidos ele deve render.
    obs = [votes_of(s) for s in strata]
    mds = [metadata(s) for s in strata]
    frac = [md["eleitorado"] > 0 ? md["eleitorado_apurado"] / md["eleitorado"] : 0.0 for md in mds]
    counted = sum(md["eleitorado_apurado"] for md in mds)
    overall_rate = counted > 0 ? sum(sum, obs) / counted : 0.75
    prior_votes = previous === nothing ? nothing : [votes_of(p) for p in previous]
    rate = map(eachindex(strata)) do s
        apurado = mds[s]["eleitorado_apurado"]
        apurado > 0 && sum(obs[s]) > 0 && return sum(obs[s]) / apurado
        if previous !== nothing
            # Todos os válidos do turno anterior, não só os dos candidatos de
            # agora: no 2º turno, os eleitores dos eliminados também votam.
            pmd = metadata(previous[s])
            pmd["eleitorado_apurado"] > 0 && return pmd["votos_validos"] / pmd["eleitorado_apurado"]
        end
        overall_rate
    end
    expected = [_remaining(md) * r for (md, r) in zip(mds, rate)]

    sum(sum, obs) > 0 || prior_votes !== nothing || throw(ArgumentError(
        "Nada apurado ainda: sem votos nem turno anterior, não há base para a projeção."))

    # Referência de cada estrato: o 1º turno, deslocado pelo que a apuração
    # já mostrou; sem 1º turno, o resultado geral apurado até aqui.
    national = _normalize(sum(obs))
    ref = if prior_votes === nothing
        fill(national, length(strata))
    else
        ε = 1e-4
        p1 = [_normalize(v) for v in prior_votes]
        weights = [sum(o) for o in obs]
        δ = sum(weights) > 0 ?
            sum(w .* (log.(_normalize(o) .+ ε) .- log.(p .+ ε)) for (w, o, p) in zip(weights, obs, p1) if w > 0) ./
            sum(weights) : zeros(n)
        [sum(v) > 0 ? _normalize(p .* exp.(δ)) : national for (p, v) in zip(p1, prior_votes)]
    end
    # O turno anterior do próprio estrato é uma referência bem melhor que o
    # resultado geral, e pesa mais (`prior_previous`).
    κ0 = [prior_votes !== nothing && sum(prior_votes[s]) > 0 ? params.prior_previous : params.prior
          for s in eachindex(strata)]
    weight = [sum(obs[s]) > 0 ? params.observed * frac[s] : 0.0 for s in eachindex(strata)]
    center = map(eachindex(strata)) do s
        observed = weight[s] > 0 ? _normalize(obs[s]) : ref[s]
        (κ0[s] .* ref[s] .+ weight[s] .* observed) ./ (κ0[s] + weight[s])
    end
    concentration = κ0 .+ weight

    rule = _rule(df)
    seats = metadata(df, "vagas")
    base = sum(obs)
    shares = Matrix{Float64}(undef, nsims, n)
    wins = zeros(n)
    runoffs = zeros(n)
    total = similar(base)
    draw = zeros(n)
    # Com o turno anterior, o deslocamento comum já é medido (δ): sobra menos
    # incerteza comum a todos os estratos.
    shift = prior_votes === nothing ? params.shift : params.shift_previous
    for k in 1:nsims
        z = exp.(shift .* randn(rng, n))
        total .= base
        for s in eachindex(strata)
            expected[s] > 0 || continue
            _randdirichlet!(draw, rng, concentration[s] .* _normalize(center[s] .* z) .+ 1e-3)
            total .+= expected[s] .* draw
        end
        shares[k, :] .= 100 .* _normalize(total)
        n == 0 && continue
        order = sortperm(total; rev = true)
        if rule === :majority
            top = order[1]
            if 2 * total[top] > sum(total)
                wins[top] += 1
            else
                foreach(i -> runoffs[i] += 1, order[1:min(2, n)])
            end
        else
            foreach(i -> wins[i] += 1, order[1:min(seats, n)])
        end
    end

    q(i, p) = n == 0 ? 0.0 : quantile_sorted(sort(shares[:, i]), p)
    proportional = rule === :proportional
    out = DataFrame(
        nr_candidato = cands.nr_candidato,
        nm_urna_candidato = cands.nm_urna_candidato,
        sg_partido = cands.sg_partido,
        pc_votos = cands.pc_votos,
        pc_projetado = [q(i, 0.5) for i in 1:n],
        pc_min = [q(i, 0.1) for i in 1:n],
        pc_max = [q(i, 0.9) for i in 1:n],
        p_vitoria = Union{Missing,Float64}[proportional ? missing : wins[i] / nsims for i in 1:n],
        p_segundo_turno = Union{Missing,Float64}[rule === :majority ? runoffs[i] / nsims : missing for i in 1:n],
        garantido = clinched(df)[ok],
    )
    # O que a matemática garante vale mais que a simulação.
    for (i, g) in enumerate(out.garantido)
        g === :elected && !proportional && (out.p_vitoria[i] = 1.0)
    end
    metadata!(out, "regra", String(rule); style = :note)
    # Os cenários simulados (% dos válidos; uma coluna por candidato, na ordem
    # de `nr_candidato`) e os válidos que se espera ainda apurar, para quem
    # quiser analisar a distribuição.
    metadata!(out, "cenarios", (nr_candidato = cands.nr_candidato, pc = shares); style = :note)
    metadata!(out, "validos_restantes", sum(expected); style = :note)
    metadata!(out, "estratos", length(strata); style = :note)
    metadata!(out, "usa_turno_anterior", previous !== nothing; style = :note)
    sort!(out, :pc_projetado; rev = true)
end

# Quantil de um vetor já ordenado, com interpolação linear (sem Statistics).
function quantile_sorted(v::AbstractVector, p::Real)
    isempty(v) && return NaN
    h = (length(v) - 1) * p + 1
    lo = floor(Int, h)
    lo >= length(v) ? v[end] : v[lo] + (h - lo) * (v[lo+1] - v[lo])
end

# --- Busca no TSE ---------------------------------------------------------

# Estratos de uma consulta: as UFs, na eleição presidencial do Brasil todo.
# Devolve as consultas de cada uma (mesma eleição, outra abrangência).
function _strata_queries(q)
    (q.cargo == OFFICES.president && q.uf == "BR") || return nothing
    [merge(q, (uf = u, cd_municipio = nothing, abrangencia = nothing,
               url = _live_results_url(q.ciclo, q.cd_eleicao, q.cargo, lowercase(u), nothing)))
     for u in UFS if u != "BR"]
end

# O turno anterior da mesma eleição (mesmo ciclo, mesmo cargo e local, data
# anterior), ou `nothing` se esta já é a primeira.
function _previous_round(q; config = nothing)
    config === nothing &&
        (config = _fetch_resultados_json(RESULTADOS_CONFIG_URL; force = false, check_updates = true, verbose = false))
    prev = try
        _find_election(config, q.cargo; uf = q.uf == "BR" ? nothing : q.uf,
                       municipality = q.cd_municipio, today = q.dt - Day(1))
    catch e
        e isa ArgumentError || rethrow()
        return nothing
    end
    (prev.ciclo == q.ciclo && prev.dt < q.dt) || return nothing
    ele = parse(Int, prev.ele)
    u = q.uf
    merge(q, (eleicao = prev.nome, cd_eleicao = ele, dt = prev.dt,
              url = _live_results_url(prev.ciclo, ele, q.cargo, lowercase(u), q.cd_municipio)))
end

# Busca várias consultas ao mesmo tempo. Uma que falhe (o CDN recusando no
# pico da apuração) usa a última versão já baixada dela, marcada com
# `versao_anterior` em vez de desmontar a projeção por UF; só sem nenhuma
# versão de alguma delas devolve `nothing` (a projeção então trata o local
# como um bloco só).
function _fetch_all(queries; fetch = _live_fetch, fallback = _live_fetch_cached)
    results = asyncmap(queries; ntasks = 8) do q
        try
            fetch(q)
        catch e
            e isa InterruptException && rethrow()
            try fallback(q) catch; nothing end
        end
    end
    any(isnothing, results) ? nothing : results
end

"""
    _projection_setup(q; fetch) -> (strata, previous)

O que a projeção de uma consulta precisa além do resultado em si, e que não
muda durante a apuração: as consultas dos estratos e os resultados do turno
anterior (já finais) nos mesmos estratos. Feito uma vez por local.
"""
function _projection_setup(q; fetch = _live_fetch, config = nothing)
    strata = _strata_queries(q)
    prev = _previous_round(q; config)
    previous = if prev === nothing
        nothing
    elseif strata === nothing
        _fetch_all([prev]; fetch)
    else
        _fetch_all([merge(s, (url = _live_results_url(prev.ciclo, prev.cd_eleicao, q.cargo, lowercase(s.uf), nothing),))
                    for s in strata]; fetch)
    end
    (strata = strata, previous = previous)
end

"""
    live_projection(office = :president; uf, municipality, election, nsims = 4000, verbose = true) -> DataFrame

Busca o resultado atual na Divulgação de Resultados do TSE (como
[`live_results`](@ref)) e devolve a sua [`projection`](@ref): resultado
projetado, chance de vitória e o que já está matematicamente garantido.

Na eleição presidencial do Brasil todo, a projeção é feita por UF (são 28
consultas a mais), e num 2º turno usa o 1º turno de cada UF como
referência. Nos demais casos, o local é um bloco só (com o 1º turno do local,
num 2º turno).

```julia
live_projection()                        # Presidente
live_projection(:governor; uf = "PE")
```
"""
function live_projection(office::Union{Symbol,Integer} = :president;
                         uf::Union{Nothing,AbstractString} = nothing,
                         municipality::Union{Nothing,Integer,AbstractString} = nothing,
                         election::Union{Nothing,Integer,AbstractString} = nothing,
                         nsims::Integer = 4000, verbose::Bool = true)
    q = _live_query(office; uf, municipality, election)
    verbose && @info "Consultando a Divulgação de Resultados do TSE" eleicao = q.eleicao url = q.url
    df = _live_fetch(q)
    setup = _projection_setup(q)
    strata = setup.strata === nothing ? nothing : _fetch_all(setup.strata)
    previous = setup.previous
    # Sem estratos (ou se algum falhou), o 1º turno do local todo.
    if strata === nothing && setup.strata !== nothing
        previous = nothing
    end
    projection(df; strata, previous, nsims)
end
