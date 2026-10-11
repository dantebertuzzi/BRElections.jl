#!/usr/bin/env julia
#
# Calibração de `projection` em apurações reconstituídas com dados reais.
#
#   julia -t auto --project=. dev/calibrate_projection.jl            # 2022, parâmetros atuais
#   julia -t auto --project=. dev/calibrate_projection.jl 2022 12    # ano, sementes por cenário
#
# A partir da votação de presidente por zona eleitoral nos dois turnos
# (`candidate_votes`) e do eleitorado apto de cada zona (`vote_details`),
# reconstitui apurações parciais contando zonas reais em ordens diferentes:
# capitais primeiro, capitais por último ou ao acaso, com e sem o Nordeste
# atrasado. Em vários pontos da apuração compara três projeções — a
# extrapolação do total nacional, a por UF e a por UF com o 1º turno (no 2º
# turno) — com o resultado final, e mede erro, cobertura da faixa de 80%,
# largura da faixa e a chance dada ao vencedor real.
#
# Foi com ele que se escolheram os valores de `BRElections.PROJECTION_PARAMS`.
# Baixa os arquivos nacionais do ano (centenas de MB) na primeira vez.
#
using BRElections
using DataFrames
using Dates
using Printf
using Random

const YEAR = parse(Int, get(ARGS, 1, "2022"))
const SEEDS = parse(Int, get(ARGS, 2, "12"))
const NE = Set(["AL", "BA", "CE", "MA", "PB", "PE", "PI", "RN", "SE"])

println("Carregando votos e eleitorado por zona de $YEAR…")
v = candidate_votes(YEAR; columns = [:nr_turno, :sg_uf, :cd_municipio, :nr_zona, :cd_cargo, :nr_candidato, :qt_votos_nominais],
                    filter = r -> r.cd_cargo == OFFICES.president, verbose = false)
d = vote_details(YEAR; columns = [:nr_turno, :sg_uf, :cd_municipio, :nr_zona, :cd_cargo, :qt_aptos],
                 filter = r -> r.cd_cargo == OFFICES.president, verbose = false)
caps = Set(subset(municipalities(verbose = false), :capital => identity).cd_municipio)

key(r) = (r.sg_uf, r.cd_municipio, r.nr_zona)
const ROUNDS = sort(unique(v.nr_turno))
const APTOS = Dict(key(r) => r.qt_aptos for r in eachrow(d) if r.nr_turno == last(ROUNDS))
const ZONES = collect(keys(APTOS))
const UFS = sort(unique(first.(ZONES)))
const BY_UF = Dict(u => [k for k in ZONES if k[1] == u] for u in UFS)
const VOTES = Dict((t, k) => Dict{Int,Int}() for t in ROUNDS for k in ZONES)
for r in eachrow(v)
    k = key(r)
    haskey(APTOS, k) || continue
    z = VOTES[(r.nr_turno, k)]
    z[r.nr_candidato] = get(z, r.nr_candidato, 0) + r.qt_votos_nominais
end
const CANDS = Dict(t => sort(unique(v.nr_candidato[v.nr_turno .== t])) for t in ROUNDS)

function totals(t, zones)
    tot = Dict{Int,Int}()
    for k in zones, (c, x) in VOTES[(t, k)]
        tot[c] = get(tot, c, 0) + x
    end
    tot
end
const FINAL = Dict(t => (tot = totals(t, ZONES); s = sum(values(tot)); Dict(c => 100x / s for (c, x) in tot))
                   for t in ROUNDS)
# O candidato acompanhado: o 1º colocado do último turno.
const WATCH = argmax(FINAL[last(ROUNDS)])
const WINNER_LAST = WATCH

# Resultado no formato de `live_results` para as zonas `counted` de `all_`.
function result(t, counted, all_, abr)
    tot = totals(t, counted)
    cs = CANDS[t]
    vv = [get(tot, c, 0) for c in cs]
    df = DataFrame(nr_candidato = cs, nm_urna_candidato = string.(cs), nm_candidato = string.(cs),
                   sg_partido = string.(cs), nm_agremiacao = Union{Missing,String}[missing for _ in cs],
                   qt_votos = vv, pc_votos = 100 .* vv ./ max(sum(vv), 1), eleito = falses(length(cs)),
                   ds_situacao = Union{Missing,String}[missing for _ in cs],
                   ds_destinacao_voto = Union{Missing,String}["Válido" for _ in cs], sq_candidato = string.(cs))
    sort!(df, :qt_votos; rev = true)
    for (k, x) in ("cd_cargo" => OFFICES.president, "vagas" => 1,
                   "eleicao" => (t == 2 ? "2º Turno" : "1º Turno"), "abrangencia" => abr,
                   "eleitorado" => sum(APTOS[k] for k in all_),
                   "eleitorado_apurado" => isempty(counted) ? 0 : sum(APTOS[k] for k in counted),
                   "votos_validos" => sum(vv))
        metadata!(df, k, x; style = :note)
    end
    df
end

# Ordem de apuração: início e duração por UF, ordem das zonas dentro dela.
function schedule(rng; ne_late, within)
    delay = Dict(u => (ne_late && u in NE ? 0.15 : 0.0) + 0.1rand(rng) for u in UFS)
    span = Dict(u => (ne_late && u in NE ? 0.8 : 0.6) + 0.2rand(rng) for u in UFS)
    order = Dict(u => begin
        zs = BY_UF[u]
        score = [within === :capital_first ? (k[2] in caps ? 0.0 : 1.0) + 0.3rand(rng) :
                 within === :capital_last ? (k[2] in caps ? 1.0 : 0.0) + 0.3rand(rng) : rand(rng) for k in zs]
        zs[sortperm(score)]
    end for u in UFS)
    (delay, span, order)
end

function counted_at((delay, span, order), τ)
    Dict(u => begin
        x = clamp((τ - delay[u]) / span[u], 0, 1)
        f = x * x * (3 - 2x)
        zs = order[u]
        total = sum(APTOS[k] for k in zs)
        acc, n = 0, 0
        for k in zs
            acc + APTOS[k] > f * total + 1 && break
            acc += APTOS[k]
            n += 1
        end
        zs[1:n]
    end for u in UFS)
end

function backtest(t; params = BRElections.PROJECTION_PARAMS, nsims = 800)
    previous = t == 2 ? [result(1, BY_UF[u], BY_UF[u], u) for u in UFS] : nothing
    jobs = vec(collect(Iterators.product(1:SEEDS, (true, false), (:random, :capital_first, :capital_last))))
    rows = Vector{Vector{NamedTuple}}(undef, length(jobs))
    Threads.@threads for j in eachindex(jobs)
        seed, ne_late, within = jobs[j]
        rng = Xoshiro(hash(jobs[j]))
        sch = schedule(rng; ne_late, within)
        out = NamedTuple[]
        for τ in (0.15, 0.3, 0.45, 0.6, 0.75, 0.9)
            counted = counted_at(sch, τ)
            parts = [result(t, counted[u], BY_UF[u], u) for u in UFS]
            nat = result(t, reduce(vcat, values(counted)), ZONES, "BR")
            sum(nat.qt_votos) == 0 && continue
            share = metadata(nat, "eleitorado_apurado") / metadata(nat, "eleitorado")
            models = ("ingênua" => (;), "por UF" => (; strata = parts))
            previous === nothing || (models = (models..., "UF + 1º turno" => (; strata = parts, previous)))
            for (model, kw) in models
                p = projection(nat; nsims, rng, params, kw...)
                r = p[p.nr_candidato .== WATCH, :][1, :]
                truth = FINAL[t][WATCH]
                push!(out, (; model, apurado = share, err = r.pc_projetado - truth,
                            cover = r.pc_min <= truth <= r.pc_max, width = r.pc_max - r.pc_min,
                            p_win = t == 2 ? r.p_vitoria : missing))
            end
        end
        rows[j] = out
    end
    DataFrame(reduce(vcat, rows))
end

mean_(x) = (c = collect(x); isempty(c) ? missing : sum(c) / length(c))
band(a) = a < 0.3 ? "a. <30%" : a < 0.55 ? "b. 30–55%" : a < 0.8 ? "c. 55–80%" : "d. >80%"

function report(df)
    df.faixa = band.(df.apurado)
    g = combine(groupby(df, [:model, :faixa]),
                :err => (e -> mean_(abs.(e))) => :erro_medio_pp, :cover => mean_ => :cobertura_80,
                :width => mean_ => :largura_pp, :p_win => (p -> mean_(skipmissing(p))) => :chance_do_vencedor,
                nrow => :n)
    show(stdout, sort!(g, [:model, :faixa]); allrows = true, summary = false, eltypes = false)
    println()
end

println("Parâmetros: ", BRElections.PROJECTION_PARAMS)
for t in ROUNDS
    println("\n=== $t º turno de $YEAR — candidato acompanhado: nº $WATCH, final ",
            @sprintf("%.2f%%", FINAL[t][WATCH]))
    report(backtest(t))
end
