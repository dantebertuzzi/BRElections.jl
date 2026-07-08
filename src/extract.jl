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
    isvalid(String(copy(bytes))) && return bytes
    Vector{UInt8}(codeunits(decode(bytes, enc"ISO-8859-1")))
end

_is_tabular(name::AbstractString) =
    (endswith(lowercase(name), ".csv") || endswith(lowercase(name), ".txt")) &&
    !occursin("leiame", lowercase(name))

"""
    extract_csvs(zippath; dest = _extract_dir(zippath), force = false) -> Vector{String}

Extrai os arquivos tabulares (`.csv`/`.txt`, ignorando `leiame`) de um ZIP
do TSE para `dest`, transcodificando o conteúdo de ISO-8859-1 para UTF-8 na
extração. Arquivos já extraídos são reaproveitados (cache), salvo `force = true`.

Retorna os caminhos dos CSVs extraídos, ordenados.
"""
function extract_csvs(zippath::AbstractString;
                      dest::AbstractString = _extract_dir(zippath),
                      force::Bool = false)
    isfile(zippath) || throw(ArgumentError("ZIP não encontrado: $zippath"))
    mkpath(dest)
    out = String[]
    reader = ZipFile.Reader(zippath)
    try
        for entry in reader.files
            _is_tabular(entry.name) || continue
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

# Seleciona, dentre os CSVs extraídos de um ZIP nacional, quais ler:
#  * se `uf` for dada, apenas os arquivos "_UF.csv";
#  * senão, o arquivo "_BRASIL.csv" se existir (evita dupla contagem);
#  * senão, todos os arquivos por UF.
function select_csvs(paths::Vector{String}; uf::Union{Nothing,AbstractString} = nothing)
    if uf !== nothing
        u = validate_uf(uf)
        suffix = "_$(u).csv"
        sel = [p for p in paths if endswith(uppercase(basename(p)), suffix)]
        isempty(sel) && throw(ArgumentError(
            "Nenhum arquivo para a UF $u neste dataset. Arquivos disponíveis: " *
            join(basename.(paths), ", ")))
        return sel
    end
    brasil = [p for p in paths if occursin("_BRASIL", uppercase(basename(p)))]
    isempty(brasil) ? paths : brasil
end
