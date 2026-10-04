#!/usr/bin/env julia
#
# Apuração ao vivo no terminal — painel em cima de `live_results`, que lê a
# Divulgação de Resultados do TSE (resultados.tse.jus.br), a mesma fonte do
# site e do app "Resultados".
#
#   julia --project=. examples/live_results.jl                       # Presidente, Brasil
#   julia --project=. examples/live_results.jl governador sp
#   julia --project=. examples/live_results.jl senador pe --watch 60
#   julia --project=. examples/live_results.jl depfed sp --top 30
#   julia --project=. examples/live_results.jl presidente sp "são paulo"
#   julia --project=. examples/live_results.jl governador pe 25313   # código TSE ou IBGE
#   julia --project=. examples/live_results.jl prefeito sp "são paulo"
#
# Cargos: presidente, governador, senador, depfed, depest, depdist, prefeito,
# vereador. O município (3º argumento) é obrigatório para prefeito e vereador;
# pode ser o nome — sem acento e sem diferenciar maiúsculas; basta um trecho,
# se ele for único na UF —, o código TSE ou o código IBGE.
#
# Depende de PrettyTables.jl (v3), que não é dependência do pacote. Se faltar:
#   julia -e 'using Pkg; Pkg.add("PrettyTables")'
#
using BRElections
using DataFrames
using Dates
using Printf

try
    @eval using PrettyTables
catch
    error("Este exemplo precisa do PrettyTables.jl (v3). Instale com:\n" *
          "  julia -e 'using Pkg; Pkg.add(\"PrettyTables\")'")
end
pkgversion(PrettyTables) >= v"3" ||
    error("Este exemplo usa a API do PrettyTables v3; a versão carregada é $(pkgversion(PrettyTables)).")

const CARGOS = Dict(
    "presidente" => :president,
    "governador" => :governor,
    "senador"    => :senator,
    "depfed"     => :federal_deputy,
    "depest"     => :state_deputy,
    "depdist"    => :district_deputy,
    "prefeito"   => :mayor,
    "vereador"   => :councillor,
)

# ---------------------------------------------------------------------------
# Saída
# ---------------------------------------------------------------------------

fmtint(n) = replace(string(n), r"(?<=\d)(?=(\d{3})+$)" => ".")
fmtpct(x) = replace(@sprintf("%.2f", x), '.' => ',') * "%"

const PARTIAL_BLOCKS = collect("▏▎▍▌▋▊▉")  # 1/8 a 7/8 de bloco

# Barra horizontal proporcional ao percentual (100% = `width` blocos).
function bar(pct; width = 20)
    eighths = round(Int, clamp(pct, 0, 100) / 100 * width * 8)
    full, rest = divrem(eighths, 8)
    "█"^full * (rest == 0 ? "" : string(PARTIAL_BLOCKS[rest]))
end

const TABLE_FORMAT = TextTableFormat(; borders = text_table_borders__unicode_rounded)

function situacao(c)
    sit = c.eleito ? "ELEITO" : coalesce(c.ds_situacao, "")
    dest = coalesce(c.ds_destinacao_voto, "")
    dest in ("", "Válido") || (sit = isempty(sit) ? dest : "$sit / $dest")
    sit
end

function report(io, df; top)
    m = metadata(df)
    final = m["totalizacao_final"]

    # --- Resumo da apuração --------------------------------------------------
    pst = m["pc_secoes_totalizadas"]
    resumo = [
        "Seções totalizadas" fmtpct(pst)                  "$(fmtint(m["secoes_totalizadas"])) de $(fmtint(m["secoes"]))"  bar(pst)
        "Comparecimento"     fmtpct(m["pc_comparecimento"]) "$(fmtint(m["comparecimento"])) de $(fmtint(m["eleitorado_apurado"]))" ""
        "Abstenção"          fmtpct(m["pc_abstencao"])      fmtint(m["abstencao"])  ""
        "Válidos"            fmtpct(m["pc_votos_validos"]) fmtint(m["votos_validos"])  ""
        "Brancos"            fmtpct(m["pc_votos_brancos"]) fmtint(m["votos_brancos"])  ""
        "Nulos"              fmtpct(m["pc_votos_nulos"])   fmtint(m["votos_nulos"])    ""
    ]
    pretty_table(io, resumo;
        title = m["eleicao"],
        subtitle = "$(m["cargo"]) · $(m["abrangencia"]) · $(m["vagas"]) vaga(s)",
        source_notes = "Atualizado pelo TSE em $(Dates.format(m["atualizado_em"], "dd/mm/yyyy HH:MM:SS"))" *
                       (final ? " · TOTALIZAÇÃO FINAL" : ""),
        show_column_labels = false,
        alignment = [:l, :r, :r, :l],
        table_format = TABLE_FORMAT,
        highlighters = [TextHighlighter((d, i, j) -> i == 1 && j in (2, 4),
                                        final ? crayon"bold green" : crayon"bold cyan")],
    )

    # --- Candidatos -----------------------------------------------------------
    shown = first(df, top)
    tabela = isempty(shown) ? Matrix{Any}(undef, 0, 8) : permutedims(reduce(hcat, [
        Any[i, c.nr_candidato, c.nm_urna_candidato, c.sg_partido, fmtint(c.qt_votos),
            fmtpct(c.pc_votos), situacao(c), bar(c.pc_votos; width = 15)]
        for (i, c) in enumerate(eachrow(shown))]))
    # A barra fica por último: em terminal estreito, é ela que o PrettyTables corta.
    sit_col = 7
    pretty_table(io, tabela;
        column_labels = ["#", "Nº", "Candidato", "Partido", "Votos", "%", "Situação", ""],
        alignment = [:r, :r, :l, :l, :r, :r, :l, :l],
        table_format = TABLE_FORMAT,
        highlighters = [
            # eleito / vai ao 2º turno / votos anulados
            TextHighlighter((d, i, j) -> occursin(r"ELEITO|Eleito", string(d[i, sit_col])) &&
                                         !occursin("Não eleito", string(d[i, sit_col])),
                            crayon"bold green"),
            TextHighlighter((d, i, j) -> occursin("2º turno", string(d[i, sit_col])), crayon"bold yellow"),
            TextHighlighter((d, i, j) -> occursin("Anulado", string(d[i, sit_col])), crayon"red"),
            TextHighlighter((d, i, j) -> j == 8, crayon"blue"),
        ],
        fit_table_in_display_vertically = false,   # quem decide as linhas é o --top
        source_notes = nrow(df) > top ?
            "… e mais $(nrow(df) - top) candidatos (use --top N)" : "",
    )
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function parse_args(args)
    pos = String[]
    watch = 0
    top = 15
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--watch"
            watch = parse(Int, args[i += 1])
        elseif a == "--top"
            top = parse(Int, args[i += 1])
        else
            push!(pos, a)
        end
        i += 1
    end
    cargo_nome = lowercase(get(pos, 1, "presidente"))
    haskey(CARGOS, cargo_nome) ||
        throw(ArgumentError("Cargo desconhecido: $cargo_nome. Use um de: " *
                            join(sort(collect(keys(CARGOS))), ", ") * "."))
    uf = get(pos, 2, nothing)
    municipality = get(pos, 3, nothing)
    return (; office = CARGOS[cargo_nome], uf, municipality, watch, top)
end

function main(args)
    opts = parse_args(args)
    query() = live_results(opts.office; opts.uf, opts.municipality, verbose = false)

    while true
        try
            df = query()
            opts.watch > 0 && print("\e[2J\e[H")  # limpa a tela entre atualizações
            report(stdout, df; top = opts.top)
            opts.watch > 0 || return
            metadata(df, "totalizacao_final") && (println("Totalização final — encerrando."); return)
            println("Próxima consulta em $(opts.watch)s (Ctrl+C para sair).")
        catch err
            # Erro de uso (cargo, UF, município) não melhora esperando.
            (err isa InterruptException || err isa ArgumentError) && rethrow()
            println(stderr, "Falha ao consultar o TSE: ", sprint(showerror, err))
            opts.watch > 0 || exit(1)
        end
        sleep(opts.watch)
    end
end

try
    main(ARGS)
catch err
    # Erros de uso viram mensagem simples, sem stack trace.
    err isa ArgumentError || rethrow()
    println(stderr, err.msg)
    exit(1)
end
