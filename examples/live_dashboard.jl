#!/usr/bin/env julia
#
# Dashboard da apuração no terminal — `live_dashboard`, com o Tachikoma.jl.
#
#   julia -t auto examples/live_dashboard.jl --demo                  # apuração simulada (~3 min)
#   julia -t auto examples/live_dashboard.jl                         # Presidente, Brasil
#   julia -t auto examples/live_dashboard.jl governador sp
#   julia -t auto examples/live_dashboard.jl prefeito pe recife
#   julia -t auto examples/live_dashboard.jl senador pe --interval 30
#
# O Tachikoma não é dependência do pacote. Se ele não estiver no seu ambiente,
# o script monta um ambiente temporário com o BRElections deste diretório e o
# Tachikoma (a primeira vez demora alguns minutos para compilar). Nada é
# instalado no seu ambiente.
#
# Teclas: Tab alterna apuração/análise · ←→ cargo · u UF · m município ·
# r consultar agora · ↑↓ rolar · q sair.
#
using Pkg

const ROOT = dirname(@__DIR__)

if Base.find_package("Tachikoma") === nothing || Base.find_package("BRElections") === nothing
    Pkg.activate(; temp = true, io = devnull)
    Pkg.develop(; path = ROOT, io = devnull)
    println("Preparando um ambiente temporário com o Tachikoma (só na primeira vez demora)…")
    Pkg.add("Tachikoma")
end

using BRElections
using Tachikoma

const CARGOS = Dict(
    "presidente" => :president, "governador" => :governor, "senador" => :senator,
    "depfed" => :federal_deputy, "depest" => :state_deputy, "depdist" => :district_deputy,
    "prefeito" => :mayor, "vereador" => :councillor,
)

function main(args)
    pos = String[]
    demo = false
    interval = 10
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--demo"
            demo = true
        elseif a == "--interval"
            interval = parse(Int, args[i += 1])
        else
            push!(pos, a)
        end
        i += 1
    end
    nome = lowercase(get(pos, 1, "presidente"))
    haskey(CARGOS, nome) || throw(ArgumentError(
        "Cargo desconhecido: $nome. Use um de: " * join(sort(collect(keys(CARGOS))), ", ") * "."))
    Threads.nthreads() == 1 &&
        @warn "Rode com threads (julia -t auto): a projeção é calculada em segundo plano."
    live_dashboard(CARGOS[nome]; uf = get(pos, 2, nothing), municipality = get(pos, 3, nothing),
                   interval, demo)
end

try
    main(ARGS)
catch err
    err isa ArgumentError || rethrow()
    println(stderr, err.msg)
    exit(1)
end
