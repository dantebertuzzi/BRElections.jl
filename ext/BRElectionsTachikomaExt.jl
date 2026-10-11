# ---------------------------------------------------------------------------
# Painel de apuração ao vivo no terminal (`live_dashboard`), com o Tachikoma.
#
# Arquitetura Elm do Tachikoma: o estado fica em `Dashboard`, `update!` trata
# teclas e respostas, `view` desenha. As consultas ao TSE — e a projeção, que
# simula milhares de cenários — rodam em tasks e voltam como `TaskEvent`; cada
# uma leva um número de geração, e respostas de uma consulta já superada (o
# usuário trocou de cargo no meio) são ignoradas.
# ---------------------------------------------------------------------------
module BRElectionsTachikomaExt

using BRElections
using BRElections: LIVE_OFFICES, MUNICIPAL_OFFICES, OFFICES, REGIONS, _live_query, _live_fetch, _office_code,
                   _projection_setup, _fetch_all, _rule
using DataFrames
using Dates
using Tachikoma
@tachikoma_app

# --- Estado ----------------------------------------------------------------

"O que o painel mostra: os argumentos de `live_results`."
struct Target
    office::Union{Symbol,Int}
    uf::Union{Nothing,String}
    municipality::Union{Nothing,String,Int}
    election::Union{Nothing,String,Int}
end

# Um ponto da evolução da apuração, guardado a cada versão nova do TSE.
struct Snapshot
    at::DateTime
    pc_secoes::Float64
    gap::Float64          # 1º − 2º, em pontos percentuais dos válidos (NaN com < 2)
    chance::Float64       # chance de vitória do líder da projeção (NaN sem projeção)
    votos::Int            # votos apurados até aqui
    secoes::Int           # seções totalizadas
    total_secoes::Int
end

# Quanto tempo (em quadros) os votos de um candidato ficam realçados depois de mudar.
const FLASH_FRAMES = 40
const FPS = 30
# Contadores "odômetro": quando o TSE publica uma versão nova, os números rolam
# do valor anterior ao novo em vez de saltar. Só animam entre duas versões
# reais — nunca passam do último número publicado.
const ANIM_SECONDS = 3.0
const ANIM_KEYS = ("secoes_totalizadas", "pc_secoes_totalizadas", "eleitorado_apurado", "comparecimento",
                   "abstencao", "pc_comparecimento", "pc_abstencao", "votos", "votos_validos",
                   "votos_brancos", "votos_nulos", "pc_votos_validos", "pc_votos_brancos", "pc_votos_nulos")
# Janela usada para o ritmo da apuração.
const PACE_WINDOW = Minute(10)
const NSIMS = 2000
const VBARS = collect("▁▂▃▄▅▆▇")
const REGION_ORDER = ("Norte", "Nordeste", "Centro-Oeste", "Sudeste", "Sul", "Exterior")

# Cores dos candidatos, atribuídas na ordem em que aparecem e fixas depois:
# a cor acompanha o candidato quando a ordem muda.
const PALETTE = [ColorRGB(0x5f, 0xaf, 0xff), ColorRGB(0xff, 0x87, 0x5f), ColorRGB(0x87, 0xd7, 0x87),
                 ColorRGB(0xd7, 0x87, 0xff), ColorRGB(0xff, 0xd7, 0x5f), ColorRGB(0x5f, 0xd7, 0xd7),
                 ColorRGB(0xff, 0x87, 0xaf), ColorRGB(0xaf, 0xaf, 0x87)]

@kwdef mutable struct Dashboard <: Model
    target::Target
    interval::Float64 = 10.0
    # Quem resolve, busca e prepara a projeção: injetáveis para os testes
    # rodarem sem rede.
    resolve::Function = t -> _live_query(t.office; t.uf, t.municipality, t.election)
    fetch::Function = _live_fetch
    prepare::Function = q -> _projection_setup(q)
    tq::TaskQueue = TaskQueue()
    timer::Union{Nothing,CancelToken} = nothing
    query::Any = nothing                       # consulta resolvida de `target`
    setup::Any = nothing                       # estratos e turno anterior de `target`
    df::Union{Nothing,DataFrame} = nothing
    strata::Union{Nothing,Vector} = nothing    # resultados por UF (presidente)
    proj::Union{Nothing,DataFrame} = nothing
    history::Vector{Snapshot} = Snapshot[]
    error::Union{Nothing,String} = nothing
    loading::Bool = false
    generation::Int = 0
    last_fetch::Float64 = 0.0                  # `time()` da última resposta
    scroll::Int = 0
    input::Union{Nothing,Symbol} = nothing     # :uf ou :municipality enquanto digita
    pending::Union{Nothing,Target} = nothing   # alvo escolhido que ainda espera UF/município
    buffer::String = ""
    colors::Dict{Int,ColorRGB} = Dict{Int,ColorRGB}()      # nr_candidato => cor
    flash::Dict{Int,Int} = Dict{Int,Int}()                 # nr_candidato => quadro em que mudou
    screen::Symbol = :count                    # :count (apuração) ou :analysis
    anim::Any = nothing                        # valores de partida do odômetro
    anim_start::Float64 = 0.0
    tick::Int = 0
    quit::Bool = false
end

should_quit(m::Dashboard) = m.quit
task_queue(m::Dashboard) = m.tq

_final(m::Dashboard) = m.df !== nothing && metadata(m.df, "totalizacao_final")

function init!(m::Dashboard, ::Tachikoma.Terminal)
    m.timer = spawn_timer!(m.tq, :clock, 1.0; repeat = true)
    request!(m)
end

cleanup!(m::Dashboard) = (m.timer === nothing || cancel!(m.timer); nothing)

function dashboard(office; uf, municipality, election, interval, demo = false)
    target = Target(office, uf === nothing ? nothing : uppercase(strip(uf)), municipality, election)
    m = demo ? demo_dashboard() : Dashboard(; target, interval)
    app(m; fps = FPS)
    nothing
end

# --- Demonstração --------------------------------------------------------------
#
# Fora do dia da eleição não há apuração em andamento para ver. A demonstração
# reconstitui uma a partir do resultado final real por UF da eleição
# presidencial mais recente, comprimida em alguns minutos: cada UF começa e
# avança no seu ritmo (o Nordeste mais tarde e mais devagar), e o que é
# apurado primeiro em cada UF vem enviesado, como quando as capitais terminam
# antes do interior. Os números intermediários são simulados; os finais, os
# do TSE. O título deixa isso claro.

const DEMO_SECONDS = 180.0        # duração da apuração simulada
const DEMO_PUBLISH = 4.0          # o "TSE" publica uma versão a cada 4 s
const DEMO_CLOCK = 60             # 1 s real = 1 min de apuração

mutable struct Replay
    national::DataFrame
    strata::Vector{DataFrame}
    delay::Vector{Float64}        # início de cada UF (fração da duração)
    span::Vector{Float64}         # quanto da duração cada UF leva
    bias::Vector{Float64}         # viés do apurado primeiro, em pontos, a favor do 1º da UF
    t0::Float64
    step::Int                     # versão servida na última consulta nacional
end

function Replay(national, strata; seed = 2026)
    rng = BRElections.Random.Xoshiro(seed)
    ne = [get(REGIONS, metadata(s, "abrangencia"), "") == "Nordeste" for s in strata]
    delay = [n ? 0.12 + 0.08rand(rng) : 0.08rand(rng) for n in ne]
    span = [n ? 0.80 + 0.08rand(rng) : 0.55 + 0.25rand(rng) for n in ne]
    bias = 2.0 .+ 3.0 .* rand(rng, length(strata))
    Replay(national, strata, delay, span, bias, time(), 0)
end

replay_step(r::Replay) = floor(Int, (time() - r.t0) / DEMO_PUBLISH)

# Fração apurada de cada UF na versão `step`: curva em S (devagar no começo
# e no fim, como a apuração real).
function replay_fraction(r::Replay, i, step)
    x = clamp((step * DEMO_PUBLISH / DEMO_SECONDS - r.delay[i]) / r.span[i], 0, 1)
    x * x * (3 - 2x)
end

const DEMO_SCALED = ("comparecimento", "abstencao", "votos", "votos_brancos", "votos_nulos")

function replay_partial(d::DataFrame, f, bias, at)
    p = copy(d)
    final = f >= 1
    if !final
        v = Float64.(d.qt_votos) .* f
        # O apurado primeiro favorece o 1º da UF; o viés some ao fim da apuração.
        if nrow(d) >= 2
            shift = min(bias / 100 * (1 - f) * sum(v), v[2])
            v[1] += shift
            v[2] -= shift
        end
        p.qt_votos = round.(Int, v)
        p.pc_votos = 100 .* p.qt_votos ./ max(sum(p.qt_votos), 1)
        p.eleito .= false
        p.ds_situacao .= missing
        sort!(p, :qt_votos; rev = true)
    end
    md = metadata(d)
    apurado = round(Int, md["eleitorado"] * f)
    for k in DEMO_SCALED
        metadata!(p, k, round(Int, md[k] * f); style = :note)
    end
    metadata!(p, "votos_validos", sum(p.qt_votos[.!occursin.("Anulado", coalesce.(p.ds_destinacao_voto, ""))]);
              style = :note)
    metadata!(p, "eleitorado_apurado", apurado; style = :note)
    metadata!(p, "secoes_totalizadas", round(Int, md["secoes"] * f); style = :note)
    metadata!(p, "pc_secoes_totalizadas", 100f; style = :note)
    metadata!(p, "totalizacao_final", final; style = :note)
    metadata!(p, "atualizado_em", at; style = :note)
    p
end

function replay_version(r::Replay, uf, step)
    at = metadata(r.national, "atualizado_em") - Second(round(Int, DEMO_SECONDS * DEMO_CLOCK)) +
         Second(round(Int, step * DEMO_PUBLISH * DEMO_CLOCK))
    parts = [replay_partial(s, replay_fraction(r, i, step), r.bias[i], at) for (i, s) in enumerate(r.strata)]
    uf === "BR" || return parts[findfirst(s -> metadata(s, "abrangencia") == uf, r.strata)]
    # O nacional é a soma das UFs, com o resumo nacional proporcional.
    n = copy(r.national)
    total = Dict{Int,Int}()
    for s in parts, (nr, v) in zip(s.nr_candidato, s.qt_votos)
        total[nr] = get(total, nr, 0) + v
    end
    final = all(p -> metadata(p, "totalizacao_final"), parts)
    if !final
        n.qt_votos = [total[nr] for nr in n.nr_candidato]
        n.pc_votos = 100 .* n.qt_votos ./ max(sum(n.qt_votos), 1)
        n.eleito .= false
        n.ds_situacao .= missing
        sort!(n, :qt_votos; rev = true)
    end
    sumof(k) = sum(metadata(p, k) for p in parts)
    for k in (DEMO_SCALED..., "votos_validos", "eleitorado_apurado", "secoes_totalizadas")
        metadata!(n, k, sumof(k); style = :note)
    end
    md = metadata(n)
    metadata!(n, "pc_secoes_totalizadas", 100 * md["secoes_totalizadas"] / md["secoes"]; style = :note)
    metadata!(n, "pc_comparecimento", 100 * md["comparecimento"] / max(md["eleitorado_apurado"], 1); style = :note)
    metadata!(n, "pc_abstencao", 100 * md["abstencao"] / max(md["eleitorado_apurado"], 1); style = :note)
    for (k, part) in (("pc_votos_validos", "votos_validos"), ("pc_votos_brancos", "votos_brancos"),
                      ("pc_votos_nulos", "votos_nulos"))
        metadata!(n, k, 100 * md[part] / max(md["votos"], 1); style = :note)
    end
    metadata!(n, "totalizacao_final", final; style = :note)
    metadata!(n, "atualizado_em", at; style = :note)
    metadata!(n, "eleicao", "SIMULAÇÃO · " * metadata(r.national, "eleicao"); style = :note)
    n
end

function demo_dashboard()
    q = _live_query(:president)
    national = _live_fetch(q)
    strata = BRElections._fetch_all(BRElections._strata_queries(q))
    strata === nothing && error("Não foi possível baixar os resultados por UF para a demonstração.")
    r = Replay(national, strata)
    Dashboard(; target = Target(:president, nothing, nothing, nothing), interval = 2.0,
              resolve = t -> begin
                  (_office_code(t.office) == OFFICES.president && t.uf in (nothing, "BR") &&
                   t.municipality === nothing) || throw(ArgumentError(
                      "Na demonstração só há a eleição presidencial do Brasil todo."))
                  (uf = "BR", url = "demo")
              end,
              # O nacional fixa a versão; as UFs da mesma consulta usam a mesma.
              fetch = q -> q.uf == "BR" ? (r.step = replay_step(r); replay_version(r, "BR", r.step)) :
                                          replay_version(r, q.uf, r.step),
              prepare = q -> (strata = [(uf = metadata(s, "abrangencia"), url = "demo") for s in strata],
                              previous = nothing))
end

# --- Consultas -------------------------------------------------------------

# Dispara uma consulta. Mudar de alvo exige resolver de novo (catálogo,
# município, estratos e turno anterior); o mesmo alvo reaproveita tudo isso e
# só baixa os números.
function request!(m::Dashboard, target::Target = m.target)
    m.generation += 1
    gen = m.generation
    same = target == m.target
    query, setup = same ? (m.query, m.setup) : (nothing, nothing)
    resolve, fetch, prepare = m.resolve, m.fetch, m.prepare
    oldproj, oldstrata, olddf = same ? (m.proj, m.strata, m.df) : (nothing, nothing, nothing)
    m.loading = true
    spawn_task!(m.tq, :fetch) do
        try
            q = query === nothing ? resolve(target) : query
            df = fetch(q)
            strata = proj = nothing
            if _rule(df) !== :proportional
                # A projeção é um extra: se falhar, o painel mostra só a apuração.
                setup === nothing && (setup = try prepare(q) catch; (strata = nothing, previous = nothing) end)
                if unchanged(olddf, oldstrata, df) && oldproj !== nothing
                    # O nacional não mudou (o caso comum, consultando a cada poucos
                    # segundos): as UFs também não, e a projeção continua valendo —
                    # uma requisição em vez de 29.
                    strata, proj = oldstrata, oldproj
                else
                    strata = setup.strata === nothing ? nothing : _fetch_all(setup.strata; fetch)
                    previous = strata === nothing && setup.strata !== nothing ? nothing : setup.previous
                    proj = try projection(df; strata, previous, nsims = NSIMS) catch; nothing end
                end
            end
            (gen = gen, target = target, query = q, setup = setup, df = df,
             strata = strata, proj = proj, error = nothing)
        catch e
            (gen = gen, target = target, query = nothing, setup = nothing, df = nothing,
             strata = nothing, proj = nothing, error = e)
        end
    end
    nothing
end

# A versão nova é a mesma da anterior? Pelo horário de atualização do TSE; e
# se alguma UF ficou com a versão anterior (consulta falhou), vale buscar de novo.
unchanged(old, oldstrata, new) =
    old !== nothing && metadata(old, "atualizado_em") == metadata(new, "atualizado_em") &&
    (oldstrata === nothing || !any(stale, oldstrata))

stale(df) = metadata(df, "versao_anterior", false)

nothing_counted(df) = df !== nothing && metadata(df, "votos_validos") == 0

_message(e::ArgumentError) = e.msg
_message(e::TaskFailedException) = _message(e.task.exception)
_message(e) = first(split(sprint(showerror, e), '\n'))

function receive!(m::Dashboard, r)
    r.gen == m.generation || return            # resposta de uma consulta superada
    m.loading = false
    m.last_fetch = time()
    if r.error !== nothing
        # Alvo inválido (UF sem o cargo, município ambíguo...) ou falha de rede:
        # mostra o erro e mantém o que estava na tela.
        m.error = _message(r.error)
        return
    end
    m.error = nothing
    if r.target != m.target
        m.target = r.target
        m.history = Snapshot[]
        m.df = nothing
        m.scroll = 0
        empty!(m.flash)
    end
    m.query, m.setup = r.query, r.setup
    old = m.df
    df = r.df
    if old === nothing || metadata(df, "atualizado_em") != metadata(old, "atualizado_em")
        push!(m.history, snapshot(df, r.proj))
        if old !== nothing
            # O odômetro parte do que está na tela (pode ser o meio de outra animação).
            shown = animated(m)
            m.anim = (votes = Dict(zip(shown.nr_candidato, Float64.(shown.qt_votos))),
                      pc = Dict(zip(shown.nr_candidato, shown.pc_votos)),
                      meta = Dict(k => Float64(metadata(shown, k)) for k in ANIM_KEYS))
            m.anim_start = time()
            before = Dict(zip(old.nr_candidato, old.qt_votos))
            for c in eachrow(df)
                get(before, c.nr_candidato, c.qt_votos) == c.qt_votos || (m.flash[c.nr_candidato] = m.tick)
            end
        end
    end
    for nr in df.nr_candidato
        haskey(m.colors, nr) || (m.colors[nr] = PALETTE[mod1(length(m.colors) + 1, length(PALETTE))])
    end
    m.df, m.strata, m.proj = df, r.strata, r.proj
    nothing
end

snapshot(df, proj = nothing) =
    Snapshot(metadata(df, "atualizado_em"), metadata(df, "pc_secoes_totalizadas"),
             nrow(df) < 2 ? NaN : df.pc_votos[1] - df.pc_votos[2],
             proj === nothing || nrow(proj) == 0 || ismissing(proj.p_vitoria[1]) ? NaN : proj.p_vitoria[1],
             metadata(df, "votos"), metadata(df, "secoes_totalizadas"), metadata(df, "secoes"))

# O resultado como deve aparecer neste quadro: durante o odômetro, os números
# interpolados entre a versão anterior e a atual; depois, a atual.
function animated(m::Dashboard)
    (m.anim === nothing || m.df === nothing) && return m.df
    t = (time() - m.anim_start) / ANIM_SECONDS
    t >= 1 && (m.anim = nothing; return m.df)
    e = 1 - (1 - clamp(t, 0, 1))^3            # desacelera ao chegar
    lerp(a, b) = a + (b - a) * e
    d = copy(m.df)
    a = m.anim
    d.qt_votos = [round(Int, lerp(get(a.votes, nr, Float64(v)), v)) for (nr, v) in zip(d.nr_candidato, d.qt_votos)]
    d.pc_votos = [lerp(get(a.pc, nr, p), p) for (nr, p) in zip(d.nr_candidato, d.pc_votos)]
    for (k, v0) in a.meta
        v1 = metadata(m.df, k)
        metadata!(d, k, v1 isa Integer ? round(Int, lerp(v0, v1)) : lerp(v0, v1); style = :note)
    end
    d
end

# Ritmo da apuração nos últimos minutos (pelos horários do TSE) e a hora
# prevista para terminar nesse ritmo.
function pace(m::Dashboard)
    length(m.history) < 2 && return nothing
    last_ = m.history[end]
    window = filter(s -> s.at >= last_.at - PACE_WINDOW, m.history)
    first_ = length(window) >= 2 ? window[1] : m.history[end-1]
    minutes = Dates.value(last_.at - first_.at) / 60_000
    minutes > 0 || return nothing
    votes = (last_.votos - first_.votos) / minutes
    sections = (last_.secoes - first_.secoes) / minutes
    left = last_.total_secoes - last_.secoes
    eta = sections > 0 && left > 0 ? last_.at + Second(round(Int, 60 * left / sections)) : nothing
    (votes = votes, sections = sections, eta = eta)
end

fmtqty(x) = x >= 1e6 ? fmtpct(x / 1e6; digits = 1, suffix = " mi") :
            x >= 1e4 ? string(round(Int, x / 1e3)) * " mil" : fmtint(round(Int, x))

# --- Eventos ---------------------------------------------------------------

function update!(m::Dashboard, evt::TaskEvent)
    if evt.id === :fetch
        receive!(m, evt.value)
    elseif evt.id === :clock
        # Depois da totalização final os números não mudam mais: só sob `r`.
        !m.loading && !_final(m) && time() - m.last_fetch >= m.interval && request!(m)
    end
end

function update!(m::Dashboard, evt::KeyEvent)
    evt.action == Tachikoma.key_release && return
    m.input === nothing ? navigate!(m, evt) : type!(m, evt)
end

function navigate!(m::Dashboard, evt::KeyEvent)
    k, c = evt.key, evt.char
    if k === :escape || k === :ctrl_c || (k === :char && c == 'q')
        m.quit = true
    elseif k === :left || k === :right || (k === :char && c in ('h', 'l'))
        step = (k === :left || c == 'h') ? -1 : 1
        office = cycle_office(m.target.office, step)
        # Cargo que exige UF (ou município) e ainda não a tem: pergunta antes.
        if _office_code(office) != OFFICES.president && m.target.uf in (nothing, "BR")
            m.pending, m.input, m.buffer = with(m.target; office), :uf, ""
        elseif _office_code(office) in MUNICIPAL_OFFICES && m.target.municipality === nothing
            m.pending, m.input, m.buffer = with(m.target; office), :municipality, ""
        else
            request!(m, with(m.target; office))
        end
    elseif k === :char && c == 'u'
        m.input, m.buffer = :uf, ""             # o valor atual aparece como dica
    elseif k === :char && c == 'm'
        m.input, m.buffer = :municipality, ""
    elseif k === :char && c == 'r'
        request!(m)
    elseif k === :tab || k === :backtab || (k === :char && c == 'a')
        m.screen = m.screen === :count ? :analysis : :count
    elseif k === :up || (k === :char && c == 'k')
        m.scroll = max(0, m.scroll - 1)
    elseif k === :down || (k === :char && c == 'j')
        m.scroll += 1                           # limitado ao desenhar
    elseif k === :pageup
        m.scroll = max(0, m.scroll - 10)
    elseif k === :pagedown
        m.scroll += 10
    elseif k === :home
        m.scroll = 0
    end
    nothing
end

function type!(m::Dashboard, evt::KeyEvent)
    k = evt.key
    if k === :escape || k === :ctrl_c
        m.input = m.pending = nothing
    elseif k === :enter
        text = strip(m.buffer)
        value = isempty(text) ? nothing : String(text)
        base = something(m.pending, m.target)
        target = if m.input === :uf
            # Trocar de UF invalida o município da anterior.
            with(base; uf = value === nothing ? nothing : uppercase(value), municipality = nothing)
        else
            with(base; municipality = value)
        end
        if m.pending !== nothing && m.input === :uf && _office_code(target.office) in MUNICIPAL_OFFICES
            # Prefeito/vereador: depois da UF, o município.
            m.pending, m.input, m.buffer = target, :municipality, ""
            return nothing
        end
        m.input = m.pending = nothing
        request!(m, target)
    elseif k === :backspace
        isempty(m.buffer) || (m.buffer = chop(m.buffer))
    elseif k === :char && isprint(evt.char)
        m.buffer *= evt.char
    end
    nothing
end

const OFFICE_NAMES = Dict(:president => "Presidente", :governor => "Governador", :senator => "Senador",
                          :federal_deputy => "Dep. Federal", :state_deputy => "Dep. Estadual",
                          :district_deputy => "Dep. Distrital", :mayor => "Prefeito", :councillor => "Vereador")
office_name(o) = get(OFFICE_NAMES, o, string(o))

with(t::Target; office = t.office, uf = t.uf, municipality = t.municipality, election = t.election) =
    Target(office, uf, municipality, election)

function cycle_office(office, step)
    i = findfirst(o -> _office_code(o) == _office_code(office), collect(LIVE_OFFICES))
    LIVE_OFFICES[mod1(something(i, 1) + step, length(LIVE_OFFICES))]
end

# --- Formatação --------------------------------------------------------------

fmtint(n::Integer) = (n < 0 ? "-" : "") * replace(string(abs(n)), r"(?<=\d)(?=(\d{3})+$)" => ".")

function fmtpct(x::Real; suffix = "%", digits = 2)
    c = round(Int, 10^digits * abs(x))
    s = digits == 0 ? string(c) : string(c ÷ 10^digits) * "," * lpad(c % 10^digits, digits, '0')
    (x < 0 && c > 0 ? "-" : "") * s * suffix
end

# Chance em %: sem fingir precisão que a simulação não tem.
function fmtchance(p)
    ismissing(p) && return "–"
    p >= 0.995 ? ">99%" : p <= 0.005 ? "<1%" : string(round(Int, 100p)) * "%"
end

# Corta com reticências para caber em `w` colunas.
clip(s::AbstractString, w::Integer) =
    w <= 0 ? "" : textwidth(s) <= w ? s : first(s, max(w - 1, 0)) * "…"

function situacao(c)
    sit = c.eleito ? "Eleito" : coalesce(c.ds_situacao, "")
    dest = coalesce(c.ds_destinacao_voto, "")
    dest in ("", "Válido") || (sit = isempty(sit) ? dest : "$sit · $dest")
    sit
end

function situacao_style(sit::AbstractString, eleito::Bool)
    occursin("Anulad", sit) && return tstyle(:error)
    (eleito || occursin("eleito (garantido)", sit) ||
     (startswith(sit, "Eleito") && !occursin("Não", sit))) && return tstyle(:success; bold = true)
    occursin("2º turno", sit) && return tstyle(:warning; bold = true)
    occursin("Não eleito", sit) && return tstyle(:text_dim)
    tstyle(:text)
end

# Barra horizontal com resolução de 1/8 de célula.
function draw_bar!(buf, x, y, width, ratio, style)
    width <= 0 && return
    eighths = round(Int, clamp(ratio, 0, 1) * width * 8)
    full, rest = divrem(eighths, 8)
    for i in 0:full-1
        set_char!(buf, x + i, y, '█', style)
    end
    rest > 0 && full < width && set_char!(buf, x + full, y, BARS_H[rest], style)
end

function wrap(s::AbstractString, w::Integer)
    lines = String[]
    line = ""
    for word in split(s)
        candidate = isempty(line) ? String(word) : "$line $word"
        if textwidth(candidate) > w && !isempty(line)
            push!(lines, line)
            line = String(word)
        else
            line = candidate
        end
    end
    isempty(line) || push!(lines, line)
    lines
end

# --- Desenho -----------------------------------------------------------------

function view(m::Dashboard, f::Frame)
    m.tick += 1
    # Os painéis leem `m.df`; durante o odômetro, ele é a versão animada.
    real = m.df
    m.df = animated(m)
    try
        draw!(m, f)
    finally
        m.df = real
    end
end

function draw!(m::Dashboard, f::Frame)
    buf = f.buffer
    rows = split_layout(Layout(Vertical, [Fixed(4), Fixed(3), Fill(), Fixed(1)]), f.area)
    length(rows) < 4 && return
    draw_header!(m, buf, rows[1])
    if m.df === nothing
        draw_waiting!(m, buf, Rect(rows[2].x, rows[2].y, rows[2].width, rows[2].height + rows[3].height))
    else
        draw_progress!(m, buf, rows[2])
        m.screen === :analysis ? draw_analysis!(m, buf, rows[3]) : draw_count!(m, buf, rows[3])
    end
    draw_status!(m, buf, rows[4])
end

function draw_count!(m::Dashboard, buf, area)
    body = split_layout(Layout(Horizontal, [Fill(), Fixed(40)]), area)
    draw_candidates!(m, buf, body[1])
    side = m.strata === nothing ?
        split_layout(Layout(Vertical, [Fixed(9), Fill()]), body[2]) :
        split_layout(Layout(Vertical, [Fixed(9), Fixed(9), Fill()]), body[2])
    draw_turnout!(m, buf, side[1])
    m.strata === nothing || draw_regions!(m, buf, side[2])
    draw_history!(m, buf, side[end])
end

spinner(m) = SPINNER_BRAILLE[mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))]

function draw_header!(m::Dashboard, buf, area)
    df = m.df
    title = df === nothing ? " BRElections · apuração " : " $(metadata(df, "eleicao")) "
    stamp = df === nothing ? "" :
        " atualizado pelo TSE em $(Dates.format(metadata(df, "atualizado_em"), "dd/mm HH:MM:SS")) "
    inner = render(Block(; title, title_right = stamp, title_style = tstyle(:title; bold = true),
                         title_right_style = tstyle(:text_dim)), area, buf)
    inner.height < 1 && return
    x, y, r = inner.x + 1, inner.y, right(inner)

    if df !== nothing
        vagas = metadata(df, "vagas")
        local_ = metadata(df, "abrangencia")
        local_ == "BR" && (local_ = "BRASIL")
        x = set_string!(buf, x, y, metadata(df, "cargo"), tstyle(:text_bright; bold = true); max_x = r)
        set_string!(buf, x, y, " · $local_ · $vagas vaga$(vagas == 1 ? "" : "s")", tstyle(:text); max_x = r)
    end

    # Selo à direita: AO VIVO pulsando, FINAL fixo.
    badge, style = if _final(m)
        "✔ TOTALIZAÇÃO FINAL", tstyle(:success; bold = true)
    elseif nothing_counted(df)
        "◌ AGUARDANDO APURAÇÃO", tstyle(:warning; bold = true)
    elseif df !== nothing
        pulse = 0.5 + 0.5 * sin(m.tick / 4)
        "● AO VIVO", Style(; fg = dim_color(Tachikoma.to_rgb(tstyle(:error).fg), 0.6 * (1 - pulse)), bold = true)
    else
        "", tstyle(:text)
    end
    isempty(badge) || set_string!(buf, r - textwidth(badge), y, badge, style; max_x = r)

    inner.height < 2 && return
    y += 1
    if m.error !== nothing
        set_string!(buf, inner.x + 1, y, "⚠ " * m.error, tstyle(:error); max_x = r)
    elseif m.loading && df === nothing
        set_string!(buf, inner.x + 1, y, "$(spinner(m)) consultando o TSE…", tstyle(:accent); max_x = r)
    elseif _final(m)
        set_string!(buf, inner.x + 1, y, "Resultado final — pressione r para consultar de novo",
                    tstyle(:text_dim); max_x = r)
    else
        wait = max(0, ceil(Int, m.interval - (time() - m.last_fetch)))
        # Consultas de rotina não trocam a linha: só o indicador gira.
        xx = set_string!(buf, inner.x + 1, y, m.loading ? "$(spinner(m)) consultando" : "nova consulta em $(wait)s",
                         m.loading ? tstyle(:accent) : tstyle(:text_dim); max_x = r)
        p = pace(m)
        if p !== nothing && p.votes > 0
            xx = set_string!(buf, xx, y, "  ·  ritmo ", tstyle(:text_dim); max_x = r)
            xx = set_string!(buf, xx, y, fmtqty(p.votes) * " votos/min", tstyle(:accent; bold = true); max_x = r)
            xx = set_string!(buf, xx, y, " · " * fmtqty(p.sections) * " seções/min", tstyle(:text); max_x = r)
            p.eta === nothing ||
                set_string!(buf, xx, y, "  ·  término estimado ~" * Dates.format(p.eta, "HH:MM"),
                            tstyle(:text_bright); max_x = r)
        end
    end
end

function draw_waiting!(m::Dashboard, buf, area)
    msg = m.error === nothing ? "$(spinner(m))  Consultando a Divulgação de Resultados do TSE…" :
                                "Não foi possível mostrar este resultado. Troque o cargo (←→), a UF (u) ou o município (m)."
    style = m.error === nothing ? tstyle(:accent) : tstyle(:text_dim)
    r = center(area, min(textwidth(msg), area.width), 1)
    set_string!(buf, r.x, r.y, msg, style; max_x = right(area))
end

function draw_progress!(m::Dashboard, buf, area)
    md = metadata(m.df)
    pst = md["pc_secoes_totalizadas"]
    label = " $(fmtpct(pst)) das seções · $(fmtint(md["secoes_totalizadas"])) de $(fmtint(md["secoes"])) "
    render(Gauge(pst / 100; label,
                 block = Block(; title = " seções totalizadas ", title_style = tstyle(:title)),
                 filled_style = _final(m) ? tstyle(:success) : tstyle(:primary),
                 tick = _final(m) ? nothing : m.tick), area, buf)
end

# Colunas da tabela de candidatos: (chave, largura, título, alinhamento à direita).
# Nome e barra dividem o que sobra; em terminal estreito, as colunas de
# `DROP_ORDER` somem nessa ordem.
const DROP_ORDER = (:sit, :range, :votes, :p2, :nr)

function candidate_columns(m::Dashboard, width::Integer)
    live = m.proj !== nothing && !_final(m)
    cols = Tuple{Symbol,Int,String,Bool}[(:rank, 3, "#", true), (:nr, 5, "Nº", true),
                                         (:name, 0, "Candidato", false), (:party, 10, "Partido", false),
                                         (:bar, 0, "", false), (:pct, 8, "%", true), (:votes, 12, "Votos", true)]
    if live
        push!(cols, (:proj, 7, "Proj.", true), (:range, 13, "faixa 80%", true))
        if metadata(m.proj, "regra") == "majority"
            push!(cols, (:p1, 6, "1º t.", true), (:p2, 6, "2º t.", true))
        else
            push!(cols, (:p1, 6, "Chance", true))
        end
    end
    push!(cols, (:sit, 18, "Situação", false))
    fixed(cs) = sum(c[2] for c in cs) + length(cs) - 1
    for key in DROP_ORDER
        width - fixed(cols) >= 16 && break         # cabe um nome legível
        filter!(c -> c[1] !== key, cols)
    end
    # O nome tem prioridade sobre a barra: ela só aparece com o que sobrar.
    rest = max(width - fixed(cols), 0)
    wname = min(rest, 22)
    wbar = rest - wname - 1
    if wbar < 6
        wname, wbar = max(rest, 6), 0
    end
    cols = [(k, k === :name ? wname : k === :bar ? wbar : w, t, r) for (k, w, t, r) in cols]
    filter!(c -> c[2] > 0, cols)
end

function draw_candidates!(m::Dashboard, buf, area)
    df = m.df
    n = nrow(df)
    inner = render(Block(; title = " candidatos ($n) ", title_style = tstyle(:title),
                         title_right = n > 0 ? " ↑↓ rolar " : "", title_right_style = tstyle(:text_dim)),
                   area, buf)
    (inner.width < 20 || inner.height < 2) && return
    cols = candidate_columns(m, inner.width - 2)
    xs = Dict{Symbol,Tuple{Int,Int}}()
    x = inner.x + 1
    for (k, w, _, _) in cols
        xs[k] = (x, w)
        x += w + 1
    end
    put!(key, y, text, style; rightalign = false) = begin
        haskey(xs, key) || return
        cx, w = xs[key]
        t = clip(text, w)
        set_string!(buf, rightalign ? cx + w - textwidth(t) : cx, y, t, style)
    end

    head = tstyle(:text_dim; bold = true)
    for (k, _, title, r) in cols
        put!(k, inner.y, title, head; rightalign = r)
    end

    proj = m.proj === nothing ? Dict{Int,Any}() : Dict(p.nr_candidato => p for p in eachrow(m.proj))
    sure = m.proj === nothing ? Dict{Int,Symbol}() : Dict(zip(m.proj.nr_candidato, m.proj.garantido))
    visible = inner.height - 1
    m.scroll = clamp(m.scroll, 0, max(n - visible, 0))
    top = n == 0 ? 0.0 : maximum(df.pc_votos)
    for (k, i) in enumerate(m.scroll+1:min(n, m.scroll + visible))
        c = df[i, :]
        y = inner.y + k
        color = get(m.colors, c.nr_candidato, PALETTE[1])
        # A garantia matemática vale antes de o TSE declarar a situação.
        g = get(sure, c.nr_candidato, :open)
        sit = !_final(m) && g === :elected ? "✔ eleito (garantido)" :
              !_final(m) && g === :runoff ? "✔ 2º turno garantido" : situacao(c)
        put!(:rank, y, string(i), tstyle(:text_dim); rightalign = true)
        put!(:nr, y, string(c.nr_candidato), tstyle(:text_dim); rightalign = true)
        put!(:name, y, c.nm_urna_candidato, Style(; fg = color, bold = c.eleito || g === :elected))
        put!(:party, y, c.sg_partido, tstyle(:text))
        if haskey(xs, :bar)
            bx, bw = xs[:bar]
            draw_bar!(buf, bx, y, bw, top > 0 ? c.pc_votos / top : 0.0, Style(; fg = color))
        end
        put!(:pct, y, fmtpct(c.pc_votos), tstyle(:text_bright; bold = i == 1); rightalign = true)
        flashing = m.tick - get(m.flash, c.nr_candidato, typemin(Int) ÷ 2) < FLASH_FRAMES
        put!(:votes, y, fmtint(c.qt_votos), flashing ? tstyle(:accent; bold = true) : tstyle(:text);
             rightalign = true)
        p = get(proj, c.nr_candidato, nothing)
        if p !== nothing
            put!(:proj, y, fmtpct(p.pc_projetado; digits = 1), Style(; fg = color, bold = true); rightalign = true)
            put!(:range, y, fmtpct(p.pc_min; digits = 1, suffix = "") * "–" * fmtpct(p.pc_max; digits = 1),
                 tstyle(:text_dim); rightalign = true)
            put!(:p1, y, fmtchance(p.p_vitoria), chance_style(p.p_vitoria); rightalign = true)
            put!(:p2, y, fmtchance(p.p_segundo_turno), chance_style(p.p_segundo_turno); rightalign = true)
        end
        put!(:sit, y, sit, situacao_style(sit, c.eleito))
    end
    by = bottom(inner) + 1
    n > visible && set_string!(buf, right(inner) - 14, by,
                               " $(m.scroll + 1)–$(min(n, m.scroll + visible)) de $n ", tstyle(:text_dim))
    if m.proj !== nothing && !_final(m)
        how = metadata(m.proj, "estratos") > 1 ? "por UF" : "do local todo"
        metadata(m.proj, "usa_turno_anterior") && (how *= " + 1º turno")
        note = nothing_counted(m.df) ?
            " nada apurado: projeção = 1º turno, eliminados divididos na proporção " :
            " tendência $how · modelo simples, não é pesquisa "
        x = set_string!(buf, inner.x + 1, by, note,
                        nothing_counted(m.df) ? tstyle(:warning) : tstyle(:text_dim); max_x = right(inner) - 16)
        # UFs cuja consulta falhou entram com a versão anterior: avisa.
        late = m.strata === nothing ? 0 : count(stale, m.strata)
        late > 0 && set_string!(buf, x, by, " ⚠ $late UF$(late == 1 ? "" : "s") com a versão anterior ",
                                tstyle(:warning); max_x = right(inner) - 16)
    end
end

function chance_style(p)
    ismissing(p) && return tstyle(:text_dim)
    p >= 0.9 ? tstyle(:success; bold = true) : p >= 0.5 ? tstyle(:warning; bold = true) :
    p >= 0.1 ? tstyle(:text) : tstyle(:text_dim)
end

function draw_turnout!(m::Dashboard, buf, area)
    md = metadata(m.df)
    inner = render(Block(; title = " eleitorado e votos ", title_style = tstyle(:title)), area, buf)
    inner.height < 1 && return
    x, r = inner.x + 1, right(inner) - 1
    lines = (
        ("Eleitorado", nothing, md["eleitorado"], :text),
        ("Comparecimento", md["pc_comparecimento"], md["comparecimento"], :text),
        ("Abstenção", md["pc_abstencao"], md["abstencao"], :text_dim),
        ("Válidos", md["pc_votos_validos"], md["votos_validos"], :success),
        ("Brancos", md["pc_votos_brancos"], md["votos_brancos"], :text_dim),
        ("Nulos", md["pc_votos_nulos"], md["votos_nulos"], :text_dim),
        ("Falta apurar", nothing, max(md["eleitorado"] - md["eleitorado_apurado"], 0), :warning),
    )
    for (k, (label, pct, n, color)) in enumerate(lines)
        y = inner.y + k - 1
        y > bottom(inner) && break
        set_string!(buf, x, y, label, tstyle(:text); max_x = r)
        num = fmtint(n)
        set_string!(buf, r - textwidth(num) + 1, y, num, tstyle(color === :warning ? :warning : :text_dim); max_x = r)
        pct === nothing || set_string!(buf, x + 15, y, lpad(fmtpct(pct), 7), tstyle(color; bold = true); max_x = r)
    end
end

# Por região: quanto já foi apurado, quanto do eleitorado que falta no país
# está lá (o peso do atraso) e quem lidera entre os dois primeiros do país.
function region_rows(m::Dashboard)
    df = m.df
    lead = nrow(df) >= 2 ? (df.nr_candidato[1], df.nr_candidato[2]) : nothing
    names = Dict(zip(df.nr_candidato, df.nm_urna_candidato))
    total_left = sum(max(metadata(s, "eleitorado") - metadata(s, "eleitorado_apurado"), 0) for s in m.strata)
    map(REGION_ORDER) do reg
        parts = [s for s in m.strata if get(REGIONS, metadata(s, "abrangencia"), "") == reg]
        isempty(parts) && return nothing
        ele = sum(metadata(s, "eleitorado") for s in parts)
        apur = sum(metadata(s, "eleitorado_apurado") for s in parts)
        left = max(ele - apur, 0)
        margin = nothing
        if lead !== nothing
            v = [sum(sum(s.qt_votos[s.nr_candidato .== nr]; init = 0) for s in parts) for nr in lead]
            valid = sum(sum(s.qt_votos) for s in parts)
            if valid > 0
                w = v[1] >= v[2] ? 1 : 2
                margin = (lead[w], names[lead[w]], 100 * abs(v[1] - v[2]) / valid)
            end
        end
        (region = reg, pc_apurado = ele > 0 ? 100 * apur / ele : 0.0,
         pc_falta = total_left > 0 ? 100 * left / total_left : 0.0, margin = margin)
    end |> rows -> filter(!isnothing, collect(rows))
end

function draw_regions!(m::Dashboard, buf, area)
    inner = render(Block(; title = " regiões ", title_style = tstyle(:title),
                         title_right = " apur. · resta ", title_right_style = tstyle(:text_dim)), area, buf)
    inner.height < 1 && return
    x, r = inner.x + 1, right(inner) - 1
    for (k, row) in enumerate(region_rows(m))
        y = inner.y + k - 1
        y > bottom(inner) && break
        xx = set_string!(buf, x, y, rpad(row.region, 12), tstyle(:text); max_x = r)
        late = row.pc_apurado < 99.5 && row.pc_falta >= 25
        xx = set_string!(buf, xx, y, lpad(fmtpct(row.pc_apurado; digits = 0), 5),
                         row.pc_apurado >= 99.95 ? tstyle(:success) : tstyle(:text_bright); max_x = r)
        xx = set_string!(buf, xx, y, lpad(fmtpct(row.pc_falta; digits = 0), 5),
                         late ? tstyle(:warning; bold = true) : tstyle(:text_dim); max_x = r)
        if row.margin !== nothing
            nr, name, pts = row.margin
            tail = " +" * fmtpct(pts; digits = 1, suffix = "")
            room = r - xx - textwidth(tail)
            room > 2 && (xx = set_string!(buf, xx + 1, y, clip(name, room - 1),
                                          Style(; fg = get(m.colors, nr, PALETTE[1])); max_x = r))
            set_string!(buf, xx, y, tail, tstyle(:text_dim); max_x = r)
        end
    end
end

function draw_history!(m::Dashboard, buf, area)
    inner = render(Block(; title = " 1º − 2º ao longo da apuração ", title_style = tstyle(:title)), area, buf)
    (inner.height < 1 || inner.width < 4) && return
    x, r = inner.x + 1, right(inner) - 1
    h = filter(s -> !isnan(s.gap), m.history)
    if isempty(h)
        set_string!(buf, x, inner.y, "Só um candidato.", tstyle(:text_dim); max_x = r)
        return
    end
    last_ = h[end]
    xx = if nothing_counted(m.df)
        set_string!(buf, x, inner.y, "aguardando os primeiros votos", tstyle(:text_dim); max_x = r)
    else
        set_string!(buf, x, inner.y, "agora " * fmtpct(last_.gap; suffix = " p.p."),
                    tstyle(:text_bright; bold = true); max_x = r)
    end
    if length(h) >= 2
        d = last_.gap - h[end-1].gap
        arrow = d > 0 ? "▲" : d < 0 ? "▼" : "="
        set_string!(buf, xx + 1, inner.y, "$arrow $(fmtpct(abs(d); suffix = ""))", tstyle(:text_dim); max_x = r)
    end
    y = inner.y + 1
    if m.proj !== nothing && nrow(m.proj) >= 2 && !_final(m) && y <= bottom(inner)
        p = m.proj
        set_string!(buf, x, y, "projetado " * fmtpct(p.pc_projetado[1] - p.pc_projetado[2]; suffix = " p.p.") *
                    " · " * clip(p.nm_urna_candidato[1], 14), tstyle(:accent); max_x = r)
        y += 1
    end
    graph = Rect(inner.x + 1, y + 1, inner.width - 2, bottom(inner) - y)
    (graph.height < 1 || graph.width < 2) && return
    if length(h) < 2
        for (k, part) in enumerate(wrap("a evolução aparece a partir da próxima atualização do TSE", graph.width))
            k > graph.height && break
            set_string!(buf, graph.x, graph.y + k - 1, part, tstyle(:text_dim); max_x = right(graph))
        end
        return
    end
    # A diferença pode mudar de sinal (virada): o gráfico mostra a tendência
    # a partir de um pouco abaixo do menor valor visto.
    gaps = [s.gap for s in h]
    lo, hi = extrema(gaps)
    render(Sparkline(gaps .- (lo - max(0.25 * (hi - lo), 0.01)); style = tstyle(:primary)), graph, buf)
end

function draw_status!(m::Dashboard, buf, area)
    dim = tstyle(:text_dim)
    key = tstyle(:accent; bold = true)
    left = if m.input === nothing
        [Span(" tab ", key), Span(m.screen === :count ? "análise  " : "apuração  ", dim),
         Span("←→ ", key), Span("cargo  ", dim), Span("u ", key), Span("UF  ", dim),
         Span("m ", key), Span("município  ", dim), Span("r ", key), Span("atualizar  ", dim),
         Span("q ", key), Span("sair", dim)]
    else
        base = something(m.pending, m.target)
        what = m.input === :uf ?
            "UF$(base.uf === nothing ? "" : " (agora $(base.uf))") — vazio = Brasil" :
            "Município$(base.municipality === nothing ? "" : " (agora $(base.municipality))") — nome, código TSE ou IBGE; vazio = a UF toda"
        m.pending === nothing || (what = "$(office_name(m.pending.office)) · " * what)
        [Span(" $what: ", key), Span(m.buffer * "▏", tstyle(:text_bright)),
         Span("   enter confirma · esc cancela", dim)]
    end
    render(StatusBar(; left, right = [Span("resultados.tse.jus.br ", dim)]), area, buf)
end

# --- Tela de análise ---------------------------------------------------------

function draw_analysis!(m::Dashboard, buf, area)
    if m.proj === nothing || nrow(m.proj) == 0
        msg = m.df !== nothing && _rule(m.df) === :proportional ?
            "Cargo proporcional: a vaga depende do quociente eleitoral, e o painel não projeta vagas." :
            "Projeção indisponível para esta consulta."
        r = center(area, min(textwidth(msg), area.width), 1)
        set_string!(buf, r.x, r.y, msg, tstyle(:text_dim); max_x = right(area))
        return
    end
    cols = split_layout(Layout(Horizontal, [Percent(55), Fill()]), area)
    nshow = min(nrow(m.proj), 8)
    left = split_layout(Layout(Vertical, [Fixed(nshow + 3), Fill()]), cols[1])
    draw_chances!(m, buf, left[1], nshow)
    draw_distribution!(m, buf, left[2])
    right_ = split_layout(Layout(Vertical, [Fixed(9), Fixed(7), Fill()]), cols[2])
    draw_needs!(m, buf, right_[1])
    draw_convergence!(m, buf, right_[2])
    m.strata === nothing ? draw_method!(m, buf, right_[3]) : draw_states!(m, buf, right_[3])
end

function draw_chances!(m::Dashboard, buf, area, nshow)
    p = m.proj
    majority = metadata(p, "regra") == "majority"
    inner = render(Block(; title = majority ? " chance: vence no 1º turno · vai ao 2º " : " chance de vitória ",
                         title_style = tstyle(:title)), area, buf)
    (inner.height < 1 || inner.width < 30) && return
    x, r = inner.x + 1, right(inner) - 1
    wname = 16
    wtext = majority ? 15 : 6
    wbar = r - x - wname - wtext - 1
    for i in 1:min(nshow, inner.height)
        c = p[i, :]
        y = inner.y + i - 1
        color = get(m.colors, c.nr_candidato, PALETTE[1])
        set_string!(buf, x, y, clip(c.nm_urna_candidato, wname - 1), Style(; fg = color, bold = i == 1))
        # Com 2º turno possível, a barra é a chance de seguir na disputa
        # (vencer já ou ir ao 2º turno); o texto separa as duas.
        alive = majority ? c.p_vitoria + coalesce(c.p_segundo_turno, 0.0) : c.p_vitoria
        for k in 0:wbar-1
            set_char!(buf, x + wname + k, y, '░', tstyle(:text_dim; dim = true))
        end
        draw_bar!(buf, x + wname, y, wbar, alive, Style(; fg = color))
        text = majority ? lpad(fmtchance(c.p_vitoria), 4) * " · " * lpad(fmtchance(c.p_segundo_turno), 4) :
                          fmtchance(c.p_vitoria)
        set_string!(buf, r - textwidth(text) + 1, y, text, chance_style(alive); max_x = r)
    end
    inner.height > nshow &&
        set_string!(buf, x, inner.y + nshow, "$(size(metadata(p, "cenarios").pc, 1)) cenários simulados",
                    tstyle(:text_dim); max_x = r)
end

# A grandeza que decide a eleição agora, em cada cenário, e o corte: a parcela
# do líder contra 50% (se a vitória no 1º turno está em jogo) ou a diferença
# entre os dois candidatos dos dois lados da última vaga.
function decisive(p, seats)
    sims = metadata(p, "cenarios")
    col(nr) = sims.pc[:, findfirst(==(nr), sims.nr_candidato)]
    n = nrow(p)
    if metadata(p, "regra") == "majority"
        outright = sum(p.p_vitoria)
        if 0.005 < outright < 0.995 || n < 3
            return (values = collect(col(p.nr_candidato[1])), cut = 50.0,
                    title = " cenários: % de $(p.nm_urna_candidato[1]) · corte 50% ",
                    above = p.nr_candidato[1], below = n >= 2 ? p.nr_candidato[2] : p.nr_candidato[1],
                    question = "vence no 1º turno")
        end
        a, b = 2, 3                               # a disputa pela vaga no 2º turno
        coalesce(p.p_segundo_turno[3], 0.0) < 0.005 && ((a, b) = (1, 2))
    else
        a, b = n > seats ? (seats, seats + 1) : (1, min(2, n))
    end
    (values = collect(col(p.nr_candidato[a]) .- col(p.nr_candidato[b])), cut = 0.0,
     title = " cenários: $(clip(p.nm_urna_candidato[a], 12)) − $(clip(p.nm_urna_candidato[b], 12)) (p.p.) ",
     above = p.nr_candidato[a], below = p.nr_candidato[b],
     question = "$(clip(p.nm_urna_candidato[a], 14)) à frente")
end

function draw_distribution!(m::Dashboard, buf, area)
    d = decisive(m.proj, metadata(m.df, "vagas"))
    inner = render(Block(; title = d.title, title_style = tstyle(:title)), area, buf)
    (inner.height < 4 || inner.width < 12) && return
    x, r = inner.x + 1, right(inner) - 1
    v = sort(d.values)
    share = count(>(d.cut), v) / length(v)
    set_string!(buf, x, inner.y, "P($(d.question)) = " * fmtchance(share), chance_style(share); max_x = r)

    graph = Rect(x, inner.y + 1, r - x + 1, inner.height - 2)
    lo, hi = BRElections.quantile_sorted(v, 0.005), BRElections.quantile_sorted(v, 0.995)
    # O corte entra no gráfico se estiver perto da distribuição.
    hi - lo < 1e-6 && (lo -= 0.5; hi += 0.5)      # todos os cenários iguais (apuração encerrada)
    span = max(hi - lo, 0.05)
    abs(d.cut - (lo + hi) / 2) < 2span && (lo = min(lo, d.cut - 0.1span); hi = max(hi, d.cut + 0.1span))
    # Faixas de duas colunas: com alguns milhares de cenários, uma por coluna
    # deixa o histograma serrilhado.
    cw = 2
    nb = max(graph.width ÷ cw, 1)
    counts = zeros(Int, nb)
    for val in v
        lo <= val <= hi || continue
        counts[clamp(1 + floor(Int, (val - lo) / (hi - lo) * nb), 1, nb)] += 1
    end
    top = max(maximum(counts), 1)
    ca, cb = get(m.colors, d.above, PALETTE[1]), get(m.colors, d.below, PALETTE[2])
    cutcol = clamp(1 + floor(Int, (d.cut - lo) / (hi - lo) * nb), 0, nb + 1)
    for b in 1:nb, c in 0:cw-1
        gx = graph.x + (b - 1) * cw + c
        center_ = lo + (b - 0.5) / nb * (hi - lo)
        style = Style(; fg = center_ > d.cut ? ca : cb)
        eighths = round(Int, counts[b] / top * graph.height * 8)
        for row in 0:graph.height-1
            y = bottom(graph) - row
            e = clamp(eighths - 8row, 0, 8)
            if e > 0
                set_char!(buf, gx, y, e == 8 ? '█' : VBARS[e], style)
            elseif b == cutcol && c == 0
                set_char!(buf, gx, y, '┊', tstyle(:text_dim))
            end
        end
    end
    # Eixo: extremos e o corte.
    y = bottom(inner)
    fmt(xv) = fmtpct(xv; digits = 1, suffix = "")
    set_string!(buf, x, y, fmt(lo), tstyle(:text_dim); max_x = r)
    hl = fmt(hi)
    set_string!(buf, r - textwidth(hl) + 1, y, hl, tstyle(:text_dim); max_x = r)
    if 1 <= cutcol <= nb
        lbl = "▲" * fmt(d.cut)
        set_string!(buf, clamp(graph.x + (cutcol - 1) * cw, x + 6, r - 6 - textwidth(lbl)), y, lbl,
                    tstyle(:text_bright); max_x = r)
    end
end

function draw_needs!(m::Dashboard, buf, area)
    inner = render(Block(; title = " o que falta ", title_style = tstyle(:title)), area, buf)
    inner.height < 1 && return
    x, r = inner.x + 1, right(inner) - 1
    df, p = m.df, m.proj
    rest = metadata(p, "validos_restantes")
    lines = Tuple{String,Any}[]
    if nothing_counted(df)
        push!(lines, ("Nada apurado ainda.", tstyle(:text_bright; bold = true)))
        push!(lines, ("Válidos esperados (pelo 1º turno): " * fmtint(round(Int, rest)), tstyle(:text)))
        push!(lines, ("Até os primeiros votos, a projeção é o 1º turno de cada UF com os votos dos " *
                      "eliminados divididos na proporção dos finalistas — um ponto de partida, não uma previsão.",
                      tstyle(:text_dim)))
    else
        push!(lines, ("Válidos a apurar (est.): " * fmtint(round(Int, rest)), tstyle(:text)))
    end
    if nrow(df) >= 2 && !nothing_counted(df)
        v1, v2 = df.qt_votos[1], df.qt_votos[2]
        n1, n2 = df.nm_urna_candidato[1], df.nm_urna_candidato[2]
        V = sum(df.qt_votos)
        push!(lines, ("Diferença 1º–2º: " * fmtint(v1 - v2) * " votos", tstyle(:text)))
        if rest > 0 && V > 0
            X = rest * (v1 + v2) / V                  # o que os dois devem receber no que falta
            q = (v1 - v2 + X) / (2X)
            now_ = v2 / max(v1 + v2, 1)
            if q > 1
                push!(lines, ("$(clip(n2, 16)): virada fora de alcance", tstyle(:text_dim)))
            else
                push!(lines, ("Para virar, $(clip(n2, 16)) precisa de $(fmtpct(100q; digits = 1)) dos votos " *
                              "dos dois no que falta (até agora: $(fmtpct(100now_; digits = 1)))", tstyle(:warning; bold = true)))
            end
            if metadata(p, "regra") == "majority"
                need = (0.5 * (V + rest) - v1) / rest
                msg = need <= 0 ? "$(clip(n1, 16)) já tem maioria dos válidos" :
                      need > 1 ? "$(clip(n1, 16)) não vence no 1º turno" :
                      "$(clip(n1, 16)) precisa de $(fmtpct(100need; digits = 1)) do resto p/ vencer no 1º t."
                push!(lines, (msg, tstyle(:accent)))
            end
        elseif rest <= 0
            push!(lines, ("Tudo apurado.", tstyle(:success)))
        end
    end
    y = inner.y
    for (text, style) in lines, (k, part) in enumerate(wrap(text, r - x - 1))
        y > bottom(inner) && break
        set_string!(buf, x + (k > 1 ? 2 : 0), y, part, style; max_x = r)
        y += 1
    end
end

function draw_convergence!(m::Dashboard, buf, area)
    p = m.proj
    leader = p.nm_urna_candidato[1]
    inner = render(Block(; title = " chance do líder ao longo da apuração ", title_style = tstyle(:title)), area, buf)
    inner.height < 1 && return
    x, r = inner.x + 1, right(inner) - 1
    chances = [s.chance for s in m.history if !isnan(s.chance)]
    now_ = p.p_vitoria[1]
    what = metadata(p, "regra") == "majority" ? "vencer no 1º t." : "vencer"
    set_string!(buf, x, inner.y, "$(clip(leader, 16)): $(fmtchance(now_)) de $what", chance_style(now_); max_x = r)
    graph = Rect(x, inner.y + 1, r - x + 1, inner.height - 1)
    graph.height < 1 && return
    if length(chances) < 2
        set_string!(buf, x, graph.y, "a curva aparece com as próximas atualizações", tstyle(:text_dim); max_x = r)
    else
        render(Sparkline(chances; max_val = 1.0, style = Style(; fg = get(m.colors, p.nr_candidato[1], PALETTE[1]))),
               graph, buf)
    end
end

# Por UF, das que mais pesam no que falta apurar às que menos pesam.
function draw_states!(m::Dashboard, buf, area)
    inner = render(Block(; title = " UFs pelo peso do que falta ", title_style = tstyle(:title)), area, buf)
    inner.height < 2 && return
    x, r = inner.x + 1, right(inner) - 1
    df = m.df
    a, b = nrow(df) >= 2 ? (df.nr_candidato[1], df.nr_candidato[2]) : (df.nr_candidato[1], df.nr_candidato[1])
    names = Dict(zip(df.nr_candidato, df.nm_urna_candidato))
    left(s) = max(metadata(s, "eleitorado") - metadata(s, "eleitorado_apurado"), 0)
    total = max(sum(left, m.strata), 1)
    rows = sort(m.strata; by = left, rev = true)
    set_string!(buf, x, inner.y, "UF  região        apur.  resta  vantagem", tstyle(:text_dim; bold = true); max_x = r)
    for (k, s) in enumerate(rows)
        y = inner.y + k
        y > bottom(inner) && break
        uf = metadata(s, "abrangencia")
        ele = metadata(s, "eleitorado")
        apur = ele > 0 ? 100 * metadata(s, "eleitorado_apurado") / ele : 0.0
        resta = 100 * left(s) / total
        xx = set_string!(buf, x, y, rpad(uf, 4) * rpad(get(REGIONS, uf, ""), 13), tstyle(:text); max_x = r)
        xx = set_string!(buf, xx, y, lpad(fmtpct(apur; digits = 0), 5),
                         apur >= 99.95 ? tstyle(:success) : tstyle(:text_bright); max_x = r)
        xx = set_string!(buf, xx, y, lpad(fmtpct(resta; digits = 1), 7),
                         resta >= 8 ? tstyle(:warning; bold = true) : tstyle(:text_dim); max_x = r)
        va = sum(s.qt_votos[s.nr_candidato .== a]; init = 0)
        vb = sum(s.qt_votos[s.nr_candidato .== b]; init = 0)
        valid = sum(s.qt_votos)
        if valid > 0 && a != b
            w = va >= vb ? a : b
            tail = " +" * fmtpct(100 * abs(va - vb) / valid; digits = 1, suffix = "")
            room = r - xx - textwidth(tail) - 1
            room > 2 && (xx = set_string!(buf, xx + 2, y, clip(names[w], room - 1),
                                          Style(; fg = get(m.colors, w, PALETTE[1])); max_x = r))
            set_string!(buf, xx, y, tail, tstyle(:text_dim); max_x = r)
        end
    end
end

function draw_method!(m::Dashboard, buf, area)
    inner = render(Block(; title = " como a tendência é calculada ", title_style = tstyle(:title)), area, buf)
    inner.height < 1 && return
    p = m.proj
    prm = BRElections.PROJECTION_PARAMS
    text = "Os votos que faltam são simulados $(size(metadata(p, "cenarios").pc, 1)) vezes, " *
           "a partir do perfil do que já foi apurado" *
           (metadata(p, "usa_turno_anterior") ? " e do 1º turno, corrigido pelo deslocamento observado" : "") *
           ". A incerteza diminui conforme a apuração avança, e inclui um desvio comum " *
           "(o eleitorado que falta pode votar diferente do já apurado). Modelo simples, sem pesquisas: " *
           "mostra para onde a apuração aponta. Parâmetros: referência $(round(Int, prm.prior)), " *
           "apurado $(round(Int, prm.observed)), desvio $(prm.shift)."
    for (k, line) in enumerate(wrap(text, inner.width - 2))
        k > inner.height && break
        set_string!(buf, inner.x + 1, inner.y + k - 1, line, tstyle(:text_dim); max_x = right(inner) - 1)
    end
end

end # module
