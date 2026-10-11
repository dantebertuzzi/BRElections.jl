#!/usr/bin/env julia
#
# Projeção de governador por município × estado como bloco só, nos 2º turnos
# estaduais reais (2022 por padrão).
#
#   julia -t auto --project=. dev/calibrate_governor.jl            # 2022, 4 sementes por cenário
#   julia -t auto --project=. dev/calibrate_governor.jl 2022 8
#
# Como `dev/calibrate_projection.jl`, mas dentro de cada UF com 2º turno:
# zonas reais contadas em ordens diferentes (capital primeiro, por último, ao
# acaso). Compara o estado como um bloco só, com o 1º turno do estado, e a
# projeção por município (os `MAX_MUNICIPAL_STRATA` maiores e o resto), com o
# 1º turno de cada município — como `live_projection(:governor; uf)` faz.
#
using BRElections
using DataFrames
using Printf
using Random

const YEAR = parse(Int, get(ARGS, 1, "2022"))
const SEEDS = parse(Int, get(ARGS, 2, "4"))
const GOV = OFFICES.governor

println("Carregando votos e eleitorado de governador por zona de $YEAR…")
v = candidate_votes(YEAR; columns = [:nr_turno, :sg_uf, :cd_municipio, :nr_zona, :cd_cargo, :nr_candidato, :qt_votos_nominais],
                    filter = r -> r.cd_cargo == GOV, verbose = false)
d = vote_details(YEAR; columns = [:nr_turno, :sg_uf, :cd_municipio, :nr_zona, :cd_cargo, :qt_aptos],
                 filter = r -> r.cd_cargo == GOV, verbose = false)
caps = Set(subset(municipalities(verbose = false), :capital => identity).cd_municipio)

key(r) = (r.cd_municipio, r.nr_zona)
const RUNOFF = sort(unique(v.sg_uf[v.nr_turno .== 2]))
println("UFs com 2º turno: ", join(RUNOFF, ", "))

# Por UF: zonas, eleitorado, votos por turno.
function state_data(u)
    vu = v[v.sg_uf .== u, :]
    aptos = Dict(key(r) => r.qt_aptos for r in eachrow(d) if r.sg_uf == u && r.nr_turno == 2)
    votes = Dict((t, k) => Dict{Int,Int}() for t in 1:2 for k in keys(aptos))
    for r in eachrow(vu)
        k = key(r)
        haskey(aptos, k) || continue
        z = votes[(r.nr_turno, k)]
        z[r.nr_candidato] = get(z, r.nr_candidato, 0) + r.qt_votos_nominais
    end
    cands = Dict(t => sort(unique(vu.nr_candidato[vu.nr_turno .== t])) for t in 1:2)
    (; aptos, votes, cands, zones = collect(keys(aptos)))
end

function result(S, t, counted, all_, abr)
    tot = Dict{Int,Int}()
    for k in counted, (c, x) in S.votes[(t, k)]
        tot[c] = get(tot, c, 0) + x
    end
    cs = S.cands[t]
    vv = [get(tot, c, 0) for c in cs]
    df = DataFrame(nr_candidato = cs, nm_urna_candidato = string.(cs), nm_candidato = string.(cs),
                   sg_partido = string.(cs), nm_agremiacao = Union{Missing,String}[missing for _ in cs],
                   qt_votos = vv, pc_votos = 100 .* vv ./ max(sum(vv), 1), eleito = falses(length(cs)),
                   ds_situacao = Union{Missing,String}[missing for _ in cs],
                   ds_destinacao_voto = Union{Missing,String}["Válido" for _ in cs], sq_candidato = string.(cs))
    sort!(df, :qt_votos; rev = true)
    for (k, x) in ("cd_cargo" => GOV, "vagas" => 1, "eleicao" => (t == 2 ? "2º Turno" : "1º Turno"),
                   "abrangencia" => abr, "eleitorado" => sum(S.aptos[k] for k in all_; init = 0),
                   "eleitorado_apurado" => sum(S.aptos[k] for k in counted; init = 0), "votos_validos" => sum(vv))
        metadata!(df, k, x; style = :note)
    end
    df
end

function backtest_state(u; nsims = 600)
    S = state_data(u)
    final = (tot = Dict{Int,Int}(); for k in S.zones, (c, x) in S.votes[(2, k)]; tot[c] = get(tot, c, 0) + x; end; tot)
    winner = argmax(final)
    truth = 100 * final[winner] / sum(values(final))
    # Municípios: os maiores viram estratos; o resto, um bloco.
    muns = unique(first.(S.zones))
    zones_of = Dict(m => [k for k in S.zones if k[1] == m] for m in muns)
    size_of(m) = sum(S.aptos[k] for k in zones_of[m])
    chosen = sort(muns; by = size_of, rev = true)[1:min(BRElections.MAX_MUNICIPAL_STRATA[], length(muns))]
    rest = setdiff(muns, chosen)
    rest_zones = reduce(vcat, (zones_of[m] for m in rest); init = Tuple{Int,Int}[])
    prev_total = result(S, 1, S.zones, S.zones, u)
    prev_parts = [result(S, 1, zones_of[m], zones_of[m], string(m)) for m in chosen]
    isempty(rest) || push!(prev_parts, result(S, 1, rest_zones, rest_zones, "resto"))
    rows = NamedTuple[]
    for seed in 1:SEEDS, within in (:random, :capital_first, :capital_last)
        rng = Xoshiro(hash((u, seed, within)))
        score = [within === :capital_first ? (k[1] in caps ? 0.0 : 1.0) + 0.3rand(rng) :
                 within === :capital_last ? (k[1] in caps ? 1.0 : 0.0) + 0.3rand(rng) : rand(rng) for k in S.zones]
        order = S.zones[sortperm(score)]
        cum = cumsum([S.aptos[k] for k in order])
        for f in (0.1, 0.25, 0.4, 0.55, 0.7, 0.85)
            counted = Set(order[1:searchsortedlast(cum, f * cum[end])])
            nat = result(S, 2, collect(counted), S.zones, u)
            sum(nat.qt_votos) == 0 && continue
            parts = [result(S, 2, [k for k in zones_of[m] if k in counted], zones_of[m], string(m)) for m in chosen]
            isempty(rest) || push!(parts, result(S, 2, [k for k in rest_zones if k in counted], rest_zones, "resto"))
            for (model, kw) in ("estado inteiro" => (; previous = [prev_total]),
                                "por município" => (; strata = parts, previous = prev_parts,
                                                     params = BRElections.PROJECTION_PARAMS_MUNICIPAL))
                p = projection(nat; nsims, rng, kw...)
                r = p[p.nr_candidato .== winner, :][1, :]
                push!(rows, (; uf = u, model, apurado = f, err = r.pc_projetado - truth,
                             cover = r.pc_min <= truth <= r.pc_max, p_win = r.p_vitoria,
                             right = r.p_vitoria > 0.5))
            end
        end
    end
    rows
end

mean_(x) = (c = collect(x); sum(c) / length(c))
all_rows = reduce(vcat, fetch.([Threads.@spawn backtest_state(u) for u in RUNOFF]))
df = DataFrame(all_rows)
df.faixa = [a <= 0.25 ? "a. ≤25%" : a <= 0.55 ? "b. 40–55%" : "c. ≥70%" for a in df.apurado]
println("\nParâmetros: estado inteiro ", BRElections.PROJECTION_PARAMS, "; por município ",
        BRElections.PROJECTION_PARAMS_MUNICIPAL)
g = combine(groupby(df, [:model, :faixa]), :err => (e -> mean_(abs.(e))) => :erro_medio_pp,
            :cover => mean_ => :cobertura_80, :p_win => mean_ => :chance_do_vencedor,
            :right => mean_ => :acerta_vencedor, nrow => :n)
show(stdout, sort!(g, [:model, :faixa]); allrows = true, summary = false, eltypes = false)
println("\n\nPor UF (erro médio, pontos):")
h = unstack(combine(groupby(df, [:uf, :model]), :err => (e -> round(mean_(abs.(e)); digits = 2)) => :erro), :model, :erro)
show(stdout, h; allrows = true, summary = false, eltypes = false)
println()
