# ---------------------------------------------------------------------------
# Extração de ZIPs e normalização de codificação
# ---------------------------------------------------------------------------

# Latin-1 → UTF-8 é trivial: bytes < 0x80 são iguais, e cada byte ≥ 0x80 vira
# dois. Feito à mão, é ~10× mais rápido que passar pelo iconv e não aloca.

"""
    _latin1_to_utf8!(dst, src) -> Int

Escreve em `dst` (com ao menos `2 * length(src)` bytes) a conversão de `src`
de Latin-1 para UTF-8 e devolve o número de bytes escritos.
"""
function _latin1_to_utf8!(dst::Vector{UInt8}, src::AbstractVector{UInt8})
    j = 0
    @inbounds for b in src
        if b < 0x80
            dst[j += 1] = b
        else
            dst[j += 1] = 0xc0 | (b >> 6)
            dst[j += 1] = 0x80 | (b & 0x3f)
        end
    end
    j
end

"""
    ensure_utf8(bytes) -> Vector{UInt8}

Garante que o conteúdo esteja em UTF-8. Os CSVs do TSE são publicados em
ISO-8859-1 (Latin-1); se os bytes não formarem UTF-8 válido, são
transcodificados. Bytes já válidos em UTF-8 são devolvidos sem alteração.
"""
function ensure_utf8(bytes::Vector{UInt8})
    isvalid(String, bytes) && return bytes
    dst = Vector{UInt8}(undef, length(bytes) + count(>=(0x80), bytes))
    _latin1_to_utf8!(dst, bytes)
    dst
end

"Tamanho dos blocos lidos de cada entrada do ZIP na extração."
const EXTRACT_CHUNK_BYTES = Ref(8 * 2^20)

# Quantos bytes no fim de `v` formam uma sequência UTF-8 ainda incompleta
# (0 a 3) — o resto dela está no próximo bloco.
function _utf8_incomplete_tail(v::AbstractVector{UInt8})
    n = length(v)
    for k in 1:min(3, n)
        b = v[n - k + 1]
        b & 0xc0 == 0x80 && continue          # byte de continuação: olha mais atrás
        need = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 1
        return need > k ? k : 0
    end
    0
end

"""
    _write_utf8(entry, target; latin1 = false) -> Bool

Copia a entrada `entry` do ZIP para `target` em UTF-8, em blocos de
`EXTRACT_CHUNK_BYTES[]`, com memória constante. Equivale a
`write(target, ensure_utf8(read(entry)))` sem carregar o arquivo inteiro:

- enquanto só há ASCII, os bytes passam direto (servem às duas codificações);
- no primeiro bloco com bytes ≥ 0x80, decide: UTF-8 válido → copia e segue
  validando; senão → Latin-1, convertido daí em diante.

Devolve `false` se o arquivo parecia UTF-8 mas tem um trecho inválido mais
adiante; nesse caso a extração deve ser refeita com `latin1 = true`, como
faria `ensure_utf8` olhando o arquivo inteiro.
"""
function _write_utf8(entry, target::AbstractString; latin1::Bool = false)
    chunk = EXTRACT_CHUNK_BYTES[]
    buf = Vector{UInt8}(undef, chunk + 3)     # + sobra de sequência UTF-8 incompleta
    out = Vector{UInt8}(undef, 2 * chunk)
    mode = latin1 ? :latin1 : :undecided
    carry = 0
    open(target, "w") do io
        while !eof(entry)
            n = Int(min(chunk, entry.uncompressedsize - position(entry)))
            GC.@preserve buf unsafe_read(entry, pointer(buf, carry + 1), UInt(n))
            data = view(buf, 1:carry + n)
            carry = 0
            if mode === :latin1
                write(io, view(out, 1:_latin1_to_utf8!(out, data)))
            elseif mode === :undecided && all(<(0x80), data)
                write(io, data)
            else
                k = _utf8_incomplete_tail(data)
                body = view(data, 1:length(data) - k)
                if isvalid(String, body)
                    mode = :utf8
                    write(io, body)
                    copyto!(buf, 1, buf, length(body) + 1, k)
                    carry = k
                elseif mode === :utf8
                    return false
                else
                    mode = :latin1
                    write(io, view(out, 1:_latin1_to_utf8!(out, data)))
                end
            end
        end
        carry == 0          # sobrou sequência incompleta no fim: não era UTF-8
    end
end

# Reabre o ZIP e chama `f` com a entrada `name` (o ZipFile não volta ao início
# de uma entrada já lida).
function _with_entry(f, zippath::AbstractString, name::AbstractString)
    reader = ZipFile.Reader(zippath)
    try
        f(only(e for e in reader.files if e.name == name))
    finally
        close(reader)
    end
end

_is_tabular(name::AbstractString) =
    (endswith(lowercase(name), ".csv") || endswith(lowercase(name), ".txt")) &&
    !occursin("leiame", lowercase(name))

# Em ZIPs com várias tabelas (ex.: prestação de contas), `member` é o prefixo
# da tabela: casa com "member_ANO_UF.csv" e não com outra tabela que apenas
# comece igual ("receitas_candidatos" ≠ "receitas_candidatos_doador_originario").
_matches_member(name::AbstractString, member::AbstractString) =
    isempty(member) || occursin(Regex("^" * member * "_\\d{4}_", "i"), basename(name))

# Decide, a partir de uma lista de nomes (caminhos extraídos ou nomes de
# entradas do ZIP, antes mesmo de extrair), quais arquivos usar:
#  * se `uf` for dada, apenas os arquivos "_UF.csv";
#  * senão, o arquivo "_BRASIL.csv" se existir (evita dupla contagem);
#  * senão, todos os arquivos por UF.
# Usada tanto por `select_csvs` (pós-extração) quanto por `extract_csvs`
# (pré-extração, para não descompactar/transcodificar dados que não serão
# usados — alguns ZIPs nacionais do TSE têm um "_BRASIL.csv" que é a
# concatenação de todos os estados, várias vezes maior que qualquer UF isolada).
# Os arquivos do ZIP são divididos por UF (`..._PE.csv`, `..._BRASIL.csv`)?
_partitioned(names) = any(n -> occursin(r"_([A-Z]{2}|BRASIL)\.(csv|txt)$"i, basename(n)), names)

function _select_uf_names(names::AbstractVector{<:AbstractString};
                          uf::Union{Nothing,AbstractString,AbstractVector{<:AbstractString}} = nothing)
    # ZIP com um CSV só, sem divisão por UF (locais de votação até 2024): lê
    # tudo, e `elections` filtra as linhas pela coluna SG_UF.
    uf === nothing || _partitioned(names) || return collect(names)
    if uf isa AbstractVector
        return reduce(vcat, (_select_uf_names(names; uf = u) for u in uf); init = String[])
    end
    if uf !== nothing
        u = validate_uf(uf)
        suffix = uppercase("_$(u).csv")
        sel = [String(n) for n in names if endswith(uppercase(basename(n)), suffix)]
        isempty(sel) && throw(ArgumentError(
            "Nenhum arquivo para a UF $u neste dataset. Arquivos disponíveis: " *
            join(basename.(names), ", ")))
        return sel
    end
    brasil = [n for n in names if occursin("_BRASIL", uppercase(basename(n)))]
    isempty(brasil) ? collect(names) : brasil
end

"""
    extract_csvs(zippath; dest = _extract_dir(zippath), uf = nothing, member = "", force = false) -> Vector{String}

Extrai os arquivos tabulares (`.csv`/`.txt`, ignorando `leiame`) de um ZIP
do TSE para `dest`, transcodificando o conteúdo de ISO-8859-1 para UTF-8 na
extração. A cópia é feita em blocos, com memória constante mesmo para
arquivos de vários GB. Arquivos já extraídos são reaproveitados (cache), salvo
`force = true` ou quando o ZIP é mais novo que eles (o TSE publicou outra
versão e [`download_file`](@ref) a baixou).

Só as entradas do ZIP realmente necessárias são descompactadas: se `uf` for
informada, apenas os arquivos daquela UF; senão, o `_BRASIL.csv` (se
existir) em vez de também extrair cada arquivo por UF ao lado dele. `uf` também
pode ser um vetor de UFs. Em
alguns datasets nacionais do TSE o `_BRASIL.csv` é a concatenação de todos
os estados — extrair também os arquivos por UF seria puro desperdício de
tempo e memória, já que `_BRASIL.csv` sozinho já contém tudo. Um ZIP sem
`_BRASIL.csv` (ex.: já particionado por UF) continua tendo todas as suas
entradas extraídas normalmente. Em ZIPs com mais de uma tabela, `member`
restringe a extração a uma delas (ver `DATASETS`).

Retorna os caminhos dos CSVs extraídos, ordenados.
"""
function extract_csvs(zippath::AbstractString;
                      dest::AbstractString = _extract_dir(zippath),
                      uf::Union{Nothing,AbstractString,AbstractVector{<:AbstractString}} = nothing,
                      member::AbstractString = "",
                      force::Bool = false)
    isfile(zippath) || throw(ArgumentError("ZIP não encontrado: $zippath"))
    mkpath(dest)
    out = String[]
    reader = ZipFile.Reader(zippath)
    try
        entries = [e for e in reader.files if _is_tabular(e.name) && _matches_member(e.name, member)]
        wanted = Set(_select_uf_names([e.name for e in entries]; uf))
        for entry in entries
            entry.name in wanted || continue
            target = joinpath(dest, basename(entry.name))
            if force || !isfile(target) || mtime(target) < mtime(zippath)
                tmp = target * ".part"
                if !_write_utf8(entry, tmp)
                    _with_entry(e -> _write_utf8(e, tmp; latin1 = true), zippath, entry.name)
                end
                mv(tmp, target; force = true)
            end
            push!(out, target)
        end
    finally
        close(reader)
    end
    isempty(out) && @warn "Nenhum arquivo tabular encontrado no ZIP." zippath
    sort!(out)
end

# Seleciona, dentre os CSVs já extraídos de um ZIP nacional, quais ler.
select_csvs(paths::Vector{String}; uf::Union{Nothing,AbstractString,AbstractVector{<:AbstractString}} = nothing) =
    _select_uf_names(paths; uf)
