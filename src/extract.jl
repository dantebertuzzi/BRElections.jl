# ---------------------------------------------------------------------------
# Extração de ZIPs e normalização de codificação
# ---------------------------------------------------------------------------

"""
    ensure_utf8(bytes) -> Vector{UInt8}

Garante que o conteúdo esteja em UTF-8. Os CSVs do TSE são publicados em
ISO-8859-1 (Latin-1); se os bytes não formarem UTF-8 válido, são
transcodificados. Bytes já válidos em UTF-8 são devolvidos sem alteração.
"""
function ensure_utf8(bytes::Vector{UInt8})
    isvalid(String, bytes) && return bytes
    Vector{UInt8}(codeunits(decode(bytes, enc"ISO-8859-1")))
end

_is_tabular(name::AbstractString) =
    (endswith(lowercase(name), ".csv") || endswith(lowercase(name), ".txt")) &&
    !occursin("leiame", lowercase(name))

# Decide, a partir de uma lista de nomes (caminhos extraídos ou nomes de
# entradas do ZIP, antes mesmo de extrair), quais arquivos usar:
#  * se `uf` for dada, apenas os arquivos "_UF.csv";
#  * senão, o arquivo "_BRASIL.csv" se existir (evita dupla contagem);
#  * senão, todos os arquivos por UF.
# Usada tanto por `select_csvs` (pós-extração) quanto por `extract_csvs`
# (pré-extração, para não descompactar/transcodificar dados que não serão
# usados — alguns ZIPs nacionais do TSE têm um "_BRASIL.csv" que é a
# concatenação de todos os estados, várias vezes maior que qualquer UF isolada).
function _select_uf_names(names::AbstractVector{<:AbstractString};
                          uf::Union{Nothing,AbstractString} = nothing)
    if uf !== nothing
        u = validate_uf(uf)
        suffix = uppercase("_$(u).csv")
        sel = [n for n in names if endswith(uppercase(basename(n)), suffix)]
        isempty(sel) && throw(ArgumentError(
            "Nenhum arquivo para a UF $u neste dataset. Arquivos disponíveis: " *
            join(basename.(names), ", ")))
        return sel
    end
    brasil = [n for n in names if occursin("_BRASIL", uppercase(basename(n)))]
    isempty(brasil) ? collect(names) : brasil
end

"""
    extract_csvs(zippath; dest = _extract_dir(zippath), uf = nothing, force = false) -> Vector{String}

Extrai os arquivos tabulares (`.csv`/`.txt`, ignorando `leiame`) de um ZIP
do TSE para `dest`, transcodificando o conteúdo de ISO-8859-1 para UTF-8 na
extração. Arquivos já extraídos são reaproveitados (cache), salvo `force = true`.

Só as entradas do ZIP realmente necessárias são descompactadas: se `uf` for
informada, apenas os arquivos daquela UF; senão, o `_BRASIL.csv` (se
existir) em vez de também extrair cada arquivo por UF ao lado dele. Em
alguns datasets nacionais do TSE o `_BRASIL.csv` é a concatenação de todos
os estados — extrair também os arquivos por UF seria puro desperdício de
tempo e memória, já que `_BRASIL.csv` sozinho já contém tudo. Um ZIP sem
`_BRASIL.csv` (ex.: já particionado por UF) continua tendo todas as suas
entradas extraídas normalmente.

Retorna os caminhos dos CSVs extraídos, ordenados.
"""
function extract_csvs(zippath::AbstractString;
                      dest::AbstractString = _extract_dir(zippath),
                      uf::Union{Nothing,AbstractString} = nothing,
                      force::Bool = false)
    isfile(zippath) || throw(ArgumentError("ZIP não encontrado: $zippath"))
    mkpath(dest)
    out = String[]
    reader = ZipFile.Reader(zippath)
    try
        entries = [e for e in reader.files if _is_tabular(e.name)]
        wanted = Set(_select_uf_names([e.name for e in entries]; uf))
        for entry in entries
            entry.name in wanted || continue
            target = joinpath(dest, basename(entry.name))
            if force || !isfile(target)
                data = ensure_utf8(read(entry))
                tmp = target * ".part"
                write(tmp, data)
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
select_csvs(paths::Vector{String}; uf::Union{Nothing,AbstractString} = nothing) =
    _select_uf_names(paths; uf)
