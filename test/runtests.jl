using BRElections
using Test
using DataFrames
using Dates
using StringEncodings
using ZipFile

# Cache isolado para os testes.
BRElections.set_cache_dir!(mktempdir())

# ---------------------------------------------------------------------------
# Fixtures: gera um ZIP sintético no formato do TSE (Latin-1, ';', #NULO#)
# ---------------------------------------------------------------------------

const HEADER = "DT_GERACAO;NR_TURNO;SG_UF;NM_URNA_CANDIDATO;NR_CPF_CANDIDATO;QT_VOTOS_NOMINAIS"
const ROWS = [
    "01/10/2022;1;PE;JOÃO DA SILVA;01234567890;1500",
    "01/10/2022;1;PE;MARIA CONCEIÇÃO;#NULO#;230",
    "01/10/2022;2;PE;JOÃO DA SILVA;01234567890;3200",
    "01/10/2022;1;BA;#NE#;98765432100;42",
]

function make_fixture_zip(dir; per_uf = false)
    zippath = joinpath(dir, "consulta_teste_2022.zip")
    w = ZipFile.Writer(zippath)
    content = join(vcat(HEADER, ROWS), "\r\n") * "\r\n"
    latin1 = encode(content, enc"ISO-8859-1")
    if per_uf
        for uf in ("PE", "BA")
            sub = join(vcat(HEADER, [r for r in ROWS if occursin(";$uf;", r)]), "\r\n") * "\r\n"
            f = ZipFile.addfile(w, "consulta_teste_2022_$(uf).csv")
            write(f, encode(sub, enc"ISO-8859-1"))
        end
    else
        f = ZipFile.addfile(w, "consulta_teste_2022_BRASIL.csv")
        write(f, latin1)
    end
    g = ZipFile.addfile(w, "leiame.pdf")
    write(g, UInt8[0x25, 0x50, 0x44, 0x46]) # deve ser ignorado
    close(w)
    zippath
end

# ---------------------------------------------------------------------------

@testset "BRElections.jl" begin

    @testset "Validações" begin
        @test BRElections.validate_year(2022) == 2022
        @test_throws ArgumentError BRElections.validate_year(2021) # ímpar
        @test_throws ArgumentError BRElections.validate_year(1994) # antigo demais
        @test (@test_logs (:warn,) BRElections.validate_year(2030)) == 2030

        @test BRElections.validate_type(:candidates) == :candidates
        @test_throws ArgumentError BRElections.validate_type(:foo)

        @test BRElections.validate_uf("pe") == "PE"
        @test BRElections.validate_uf(" pe ") == "PE"  # espaços e caixa
        @test_throws ArgumentError BRElections.validate_uf("XX")
    end

    @testset "URLs" begin
        @test dataset_url(:candidates, 2022) ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/consulta_cand/consulta_cand_2022.zip"
        @test dataset_url(:section_votes, 2020; uf = "pe") ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/votacao_secao/votacao_secao_2020_PE.zip"
        @test_throws ArgumentError dataset_url(:section_votes, 2020)            # UF obrigatória
        @test_throws ArgumentError dataset_url(:section_votes, 2020; uf = "BR") # sem arquivo nacional
        # dataset nacional ignora `uf` (não particionado)
        @test dataset_url(:candidates, 2022; uf = "PE") == dataset_url(:candidates, 2022)
    end

    @testset "available_datasets" begin
        ds = available_datasets()
        @test ds isa DataFrame
        @test :candidates in ds.dataset
        @test nrow(ds) == length(BRElections.DATASETS)
    end

    @testset "Transcodificação" begin
        latin1 = encode("SÃO JOSÉ;çãõ", enc"ISO-8859-1")
        utf8 = BRElections.ensure_utf8(Vector{UInt8}(latin1))
        @test String(copy(utf8)) == "SÃO JOSÉ;çãõ"
        # UTF-8 válido passa intacto
        original = Vector{UInt8}(codeunits("já em utf-8 ✓"))
        @test BRElections.ensure_utf8(copy(original)) == original
    end

    @testset "Extração de ZIP" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir)
        csvs = BRElections.extract_csvs(zippath)
        @test length(csvs) == 1
        @test endswith(only(csvs), "_BRASIL.csv")
        # conteúdo extraído já está em UTF-8
        @test occursin("JOÃO", read(only(csvs), String))
        # cache: segunda extração reaproveita
        mtime1 = mtime(only(csvs))
        csvs2 = BRElections.extract_csvs(zippath)
        @test mtime(only(csvs2)) == mtime1
    end

    @testset "extract_csvs — não extrai o que não será usado (uf)" begin
        # Alguns datasets nacionais do TSE trazem, no mesmo ZIP, um arquivo
        # por UF *e* um "_BRASIL.csv" com todos os estados concatenados
        # (potencialmente GBs maior que qualquer UF isolada). Pedir uma UF
        # não deve tocar nos demais arquivos nem no _BRASIL.
        dir = mktempdir()
        zippath = joinpath(dir, "nacional_2022.zip")
        w = ZipFile.Writer(zippath)
        for (name, rows) in (
                ("consulta_teste_2022_PE.csv", [r for r in ROWS if occursin(";PE;", r)]),
                ("consulta_teste_2022_BA.csv", [r for r in ROWS if occursin(";BA;", r)]),
                ("consulta_teste_2022_BRASIL.csv", ROWS),
            )
            f = ZipFile.addfile(w, name)
            write(f, encode(join(vcat(HEADER, rows), "\r\n") * "\r\n", enc"ISO-8859-1"))
        end
        close(w)

        csvs_pe = BRElections.extract_csvs(zippath; uf = "PE")
        @test length(csvs_pe) == 1
        @test endswith(only(csvs_pe), "_PE.csv")
        @test !any(p -> endswith(p, "_BA.csv"), csvs_pe)
        @test !any(p -> endswith(p, "_BRASIL.csv"), csvs_pe)

        # UF inexistente neste ZIP: erro, e nada é extraído
        dir2 = mktempdir()
        @test_throws ArgumentError BRElections.extract_csvs(zippath; uf = "SP", dest = dir2)
        @test isempty(readdir(dir2))

        # sem uf: prefere o _BRASIL, não extrai os arquivos por UF ao lado
        dir3 = mktempdir()
        csvs_all = BRElections.extract_csvs(zippath; dest = dir3)
        @test length(csvs_all) == 1
        @test endswith(only(csvs_all), "_BRASIL.csv")
        @test !isfile(joinpath(dir3, "consulta_teste_2022_PE.csv"))
        @test !isfile(joinpath(dir3, "consulta_teste_2022_BA.csv"))
    end

    @testset "Seleção de arquivos (nacional vs UF)" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir; per_uf = true)
        csvs = BRElections.extract_csvs(zippath)
        @test length(csvs) == 2
        pe = BRElections.select_csvs(csvs; uf = "PE")
        @test length(pe) == 1 && endswith(only(pe), "_PE.csv")
        @test_throws ArgumentError BRElections.select_csvs(csvs; uf = "SP")
        # sem UF e sem _BRASIL: retorna todos
        @test length(BRElections.select_csvs(csvs)) == 2
    end

    @testset "read_tse_csv" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir)
        csv = only(BRElections.extract_csvs(zippath))

        df = read_tse_csv(csv)
        @test nrow(df) == 4
        @test names(df) == lowercase.(split(HEADER, ';'))       # nomes normalizados
        @test eltype(df.dt_geracao) <: Union{Missing,Date}       # datas convertidas
        @test df.dt_geracao[1] == Date(2022, 10, 1)
        @test eltype(df.qt_votos_nominais) <: Union{Missing,Integer}
        @test ismissing(df.nr_cpf_candidato[2])                  # #NULO# -> missing
        @test ismissing(df.nm_urna_candidato[4])                 # #NE#   -> missing
        @test df.nr_cpf_candidato[1] == "01234567890"            # zeros preservados
        @test df.nm_urna_candidato[2] == "MARIA CONCEIÇÃO"       # acentos ok

        # nomes originais preservados quando pedido
        df_orig = read_tse_csv(csv; normalize_names = false)
        @test "NR_TURNO" in names(df_orig)

        # seleção de colunas (insensível a caixa)
        df_cols = read_tse_csv(csv; columns = [:nr_turno, "SG_UF"])
        @test names(df_cols) == ["nr_turno", "sg_uf"]

        # filtro na importação (chunks)
        df_f = read_tse_csv(csv; filter = row -> row.NR_TURNO == 1 && row.SG_UF == "PE")
        @test nrow(df_f) == 2
        @test all(==(1), df_f.nr_turno)

        # filtro que elimina tudo mantém o esquema
        df_empty = read_tse_csv(csv; filter = row -> false)
        @test nrow(df_empty) == 0
        @test "nr_turno" in names(df_empty)
    end

    @testset "read_tse_csvs (concatenação)" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir; per_uf = true)
        csvs = BRElections.extract_csvs(zippath)
        df = BRElections.read_tse_csvs(csvs)
        @test nrow(df) == 4
        @test Set(df.sg_uf) == Set(["PE", "BA"])
        @test_throws ArgumentError BRElections.read_tse_csvs(String[])
    end

    @testset "Cache" begin
        old = cache_dir()
        tmp = mktempdir()
        @test set_cache_dir!(tmp) == abspath(tmp)
        @test cache_dir() == abspath(tmp)
        touch(joinpath(tmp, "x.zip"))
        clear_cache!()
        @test isdir(cache_dir()) && isempty(readdir(cache_dir()))
        set_cache_dir!(old)
    end

    @testset "Detecção de arquivos tabulares" begin
        @test BRElections._is_tabular("data.csv")
        @test BRElections._is_tabular("data.TXT")
        @test BRElections._is_tabular("path/to/data.CSV")
        @test !BRElections._is_tabular("leiame.csv")
        @test !BRElections._is_tabular("leiame.txt")
        @test !BRElections._is_tabular("LEIAME.CSV")
        @test !BRElections._is_tabular("leiame_consulta_cand_2022.txt")
        @test !BRElections._is_tabular("documento.pdf")
    end

    @testset "select_csvs — arquivo _BRASIL" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir)  # contém _BRASIL.csv
        csvs = BRElections.extract_csvs(zippath)
        sel = BRElections.select_csvs(csvs)
        @test length(sel) == 1
        @test occursin("_BRASIL", only(sel))
    end

    @testset "download_file (cache)" begin
        dir = mktempdir()
        dest = joinpath(dir, "test.zip")
        write(dest, "conteúdo de teste")
        result = BRElections.download_file("http://url-falsa.tse/test.zip", dest; verbose = false)
        @test result == dest
        @test read(result, String) == "conteúdo de teste"  # não sobrescrito
    end

    @testset "download_file (force + sem rede)" begin
        dir = mktempdir()
        dest = joinpath(dir, "test.zip")
        write(dest, "cache")
        @test_throws Exception BRElections.download_file(
            "http://url-falsa.tse/test.zip", dest;
            force = true, retries = 1, verbose = false)
    end

    @testset "read_tse_csv — arquivo inexistente" begin
        @test_throws ArgumentError read_tse_csv("/diretorio/inexistente/arquivo.csv")
    end

    @testset "read_tse_csvs — único arquivo" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir)
        csvs = BRElections.extract_csvs(zippath)
        df = BRElections.read_tse_csvs(csvs[1:1])
        @test nrow(df) == 4
        @test "nr_turno" in names(df)
    end

    @testset "available_datasets — estrutura" begin
        ds = available_datasets()
        @test names(ds) == ["dataset", "tse_dir", "by_uf", "first_year", "description"]
        @test eltype(ds.dataset) == Symbol
        @test eltype(ds.tse_dir) == String
        @test eltype(ds.by_uf) == Bool
        @test eltype(ds.first_year) == Int
        @test eltype(ds.description) == String
        @test :section_votes in ds.dataset
        @test Set(ds.dataset[ds.by_uf]) == Set([:section_votes, :voter_profile_section])
    end

    @testset "elections — integração offline (dataset nacional)" begin
        old_cache = cache_dir()
        cache = mktempdir()
        set_cache_dir!(cache)

        url = dataset_url(:candidates, 2022)
        subdir = joinpath(cache, "consulta_cand")
        mkpath(subdir)
        zippath_dest = joinpath(subdir, basename(url))
        fixture_dir = mktempdir()
        fixture_zip = make_fixture_zip(fixture_dir)
        cp(fixture_zip, zippath_dest)
        BRElections.extract_csvs(zippath_dest)

        df = elections(2022; type = :candidates, verbose = false, check_updates = false)
        @test nrow(df) == 4
        @test "dt_geracao" in names(df)
        @test "nr_cpf_candidato" in names(df)
        @test ismissing(df.nr_cpf_candidato[2])   # #NULO#
        @test df.dt_geracao[1] == Date(2022, 10, 1)

        set_cache_dir!(old_cache)
    end

    @testset "elections — integração offline (dataset por UF)" begin
        old_cache = cache_dir()
        cache = mktempdir()
        set_cache_dir!(cache)

        url = dataset_url(:section_votes, 2022; uf = "PE")
        subdir = joinpath(cache, "votacao_secao")
        mkpath(subdir)
        zippath_dest = joinpath(subdir, basename(url))
        fixture_dir = mktempdir()
        fixture_zip = make_fixture_zip(fixture_dir; per_uf = true)
        cp(fixture_zip, zippath_dest)
        BRElections.extract_csvs(zippath_dest)

        df = elections(2022; type = :section_votes, uf = "PE", verbose = false, check_updates = false)
        @test nrow(df) == 4
        @test "sg_uf" in names(df)

        set_cache_dir!(old_cache)
    end

    @testset "elections — erros de validação" begin
        @test_throws ArgumentError elections(2021)                     # ano ímpar
        @test_throws ArgumentError elections(2022; type = :foo)        # dataset inválido
        @test_throws ArgumentError elections(2022; type = :section_votes)  # UF obrigatória
    end

    @testset "Funções de conveniência" begin
        # o docstring de `elections` não pode se descolar da função
        @test occursin("Baixa (com cache)", string(@doc elections))
        for func in (candidates, candidate_votes, party_votes, vote_details,
                     assets, coalitions, vacancies, voter_profile)
            @test func isa Function
        end

        # section_votes e section_vote_details também existem
        @test section_votes isa Function
        @test section_vote_details isa Function
    end

    @testset "elections — colunas e filtro via API" begin
        old_cache = cache_dir()
        cache = mktempdir()
        set_cache_dir!(cache)

        url = dataset_url(:candidates, 2022)
        subdir = joinpath(cache, "consulta_cand")
        mkpath(subdir)
        zippath_dest = joinpath(subdir, basename(url))
        fixture_dir = mktempdir()
        fixture_zip = make_fixture_zip(fixture_dir)
        cp(fixture_zip, zippath_dest)
        BRElections.extract_csvs(zippath_dest)

        df = elections(2022; type = :candidates, columns = [:nr_turno, "SG_UF"], verbose = false, check_updates = false)
        @test names(df) == ["nr_turno", "sg_uf"]
        @test nrow(df) == 4

        df_f = elections(2022; type = :candidates,
                         filter = row -> row.NR_TURNO == 1 && row.SG_UF == "PE",
                         verbose = false, check_updates = false)
        @test nrow(df_f) == 2
        @test all(==(1), df_f.nr_turno)

        set_cache_dir!(old_cache)
    end

    @testset "elections — normalize_names=false via API" begin
        old_cache = cache_dir()
        cache = mktempdir()
        set_cache_dir!(cache)

        url = dataset_url(:candidates, 2022)
        subdir = joinpath(cache, "consulta_cand")
        mkpath(subdir)
        zippath_dest = joinpath(subdir, basename(url))
        fixture_dir = mktempdir()
        fixture_zip = make_fixture_zip(fixture_dir)
        cp(fixture_zip, zippath_dest)
        BRElections.extract_csvs(zippath_dest)

        df = elections(2022; type = :candidates, normalize_names = false, verbose = false, check_updates = false)
        @test "NR_TURNO" in names(df)
        @test "DT_GERACAO" in names(df)

        set_cache_dir!(old_cache)
    end

    @testset "_force_string — prefixos de identificadores" begin
        @test BRElections._force_string("NR_CPF_CANDIDATO")
        @test BRElections._force_string("nr_titulo_eleitor")        # insensível a caixa
        @test BRElections._force_string("NR_PROCESSO_TRT")
        @test BRElections._force_string("NR_PROTOCOLO_CANDIDATURA")
        @test !BRElections._force_string("QT_VOTOS_NOMINAIS")
        @test !BRElections._force_string("NR_TURNO")
    end

    @testset "Campos vazios entre aspas (\"\") — mesmo resultado no CSV 0.10 e 1.x" begin
        retype = BRElections._retype
        @test retype(Union{Missing,String}["1", missing, "20"]) isa Vector{Union{Missing,Int}}
        @test isequal(retype(Union{Missing,String}["1", missing, "20"]), [1, missing, 20])
        @test retype(Union{Missing,String}["1.5", "2"]) == [1.5, 2.0]
        @test isequal(retype(Union{Missing,String}["31/12/1980", missing]), [Date(1980, 12, 31), missing])
        @test retype(Union{Missing,String}["abc", "1"]) == ["abc", "1"]
        @test retype(Union{Missing,String}[missing, missing]) isa Vector{Missing}

        # O TSE põe todo campo entre aspas, inclusive os vazios.
        path = joinpath(mktempdir(), "vazios.csv")
        write(path, """
            "DT_NASCIMENTO";"NR_IDADE";"NM_CANDIDATO";"NR_CPF_CANDIDATO";"VR_RECEITA"
            "31/12/1980";"44";"ANA";"01234567890";"10,50"
            "";"";"";"";""
            """)
        df = read_tse_csv(path)
        @test eltype(df.dt_nascimento) == Union{Missing,Date}
        @test isequal(df.dt_nascimento, [Date(1980, 12, 31), missing])
        @test isequal(df.nr_idade, [44, missing]) && nonmissingtype(eltype(df.nr_idade)) <: Integer
        @test isequal(df.nm_candidato, ["ANA", missing])
        @test isequal(df.nr_cpf_candidato, ["01234567890", missing])       # identificador: String
        @test isequal(df.vr_receita, [10.5, missing])
        # o filtro vê os mesmos tipos
        @test nrow(read_tse_csv(path; filter = r -> !ismissing(r.dt_nascimento) && year(r.dt_nascimento) == 1980)) == 1
    end

    @testset "Cabeçalho, select e types (compatíveis com CSV 0.10 e 1.x)" begin
        path = joinpath(mktempdir(), "h.csv")
        write(path, "\"NR_TURNO\";\"SG_UF\";\"NR_CPF_CANDIDATO\";\"NR_TITULO_ELEITORAL\"\n1;PE;0123;0456\n")
        header = BRElections._read_header(path)
        @test header == [:NR_TURNO, :SG_UF, :NR_CPF_CANDIDATO, :NR_TITULO_ELEITORAL]
        # select: insensível a caixa, na ordem do arquivo, ignorando o que não existe
        @test BRElections._select_columns(header, ["sg_uf", :NR_Turno, "nao_existe"]) == [:NR_TURNO, :SG_UF]
        @test isempty(BRElections._select_columns(header, ["nao_existe"]))
        # types: só os identificadores, como String
        @test BRElections._string_types(header) ==
              Dict{Symbol,Type}(:NR_CPF_CANDIDATO => String, :NR_TITULO_ELEITORAL => String)
        @test BRElections._string_types([:NR_TURNO]) === nothing
        df = read_tse_csv(path)
        @test df.nr_cpf_candidato == ["0123"] && df.nr_titulo_eleitoral == ["0456"]
        @test df.nr_turno == [1]
        @test names(read_tse_csv(path; columns = [:sg_uf, :nao_existe])) == ["sg_uf"]
    end

    @testset "Preservação de identificadores (NR_TITULO, NR_PROCESSO, NR_PROTOCOLO)" begin
        dir = mktempdir()
        path = joinpath(dir, "ids.csv")
        write(path, "NR_TITULO_ELEITOR;NR_PROCESSO;NR_PROTOCOLO;QT_VOTOS\n001234567890;0001234;00098;10\n")
        df = read_tse_csv(path)
        @test df.nr_titulo_eleitor[1] == "001234567890"  # zeros à esquerda preservados
        @test df.nr_processo[1] == "0001234"
        @test df.nr_protocolo[1] == "00098"
        @test eltype(df.qt_votos) <: Integer
    end

    @testset "read_tse_csv — ntasks" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir)
        csv = only(BRElections.extract_csvs(zippath))
        df1 = read_tse_csv(csv; ntasks = 1)
        df4 = read_tse_csv(csv; ntasks = 4)
        @test nrow(df1) == nrow(df4) == 4
        @test names(df1) == names(df4)
    end

    @testset "read_tse_csvs — união de colunas quando schemas diferem" begin
        dir = mktempdir()
        path1 = joinpath(dir, "a.csv")
        path2 = joinpath(dir, "b.csv")
        write(path1, "NR_TURNO;SG_UF\n1;PE\n")
        write(path2, "NR_TURNO;SG_UF;NR_CPF_CANDIDATO\n2;BA;01234567890\n")
        df = BRElections.read_tse_csvs([path1, path2])
        @test nrow(df) == 2
        @test "nr_cpf_candidato" in names(df)
        @test ismissing(df.nr_cpf_candidato[1])
        @test df.nr_cpf_candidato[2] == "01234567890"
    end

    @testset "select_csvs — uf insensível a caixa" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir; per_uf = true)
        csvs = BRElections.extract_csvs(zippath)
        pe = BRElections.select_csvs(csvs; uf = "pe")
        @test length(pe) == 1 && endswith(only(pe), "_PE.csv")
    end

    @testset "extract_csvs — ZIP sem arquivos tabulares" begin
        dir = mktempdir()
        zippath = joinpath(dir, "vazio.zip")
        w = ZipFile.Writer(zippath)
        f = ZipFile.addfile(w, "leiame.pdf")
        write(f, UInt8[0x25, 0x50, 0x44, 0x46])
        close(w)
        csvs = @test_logs (:warn,) BRElections.extract_csvs(zippath)
        @test isempty(csvs)
    end

    @testset "Helpers internos de cache (_zip_path, _extract_dir)" begin
        old = cache_dir()
        tmp = mktempdir()
        set_cache_dir!(tmp)
        url = dataset_url(:candidates, 2022)
        zp = BRElections._zip_path(:candidates, url)
        @test zp == joinpath(tmp, "consulta_cand", "consulta_cand_2022.zip")
        @test BRElections._extract_dir(zp) == joinpath(tmp, "consulta_cand", "consulta_cand_2022")
        set_cache_dir!(old)
    end

    @testset "_progress_callback" begin
        cb = BRElections._progress_callback()
        @test cb(0, 50) === nothing                # total == 0: não faz nada
        @test_logs (:info,) cb(1000, 100)           # cruza 10%: loga
        @test_logs (:info,) cb(1000, 250)           # cruza 20%: loga de novo
    end

    @testset "Revalidação do cache — _cache_is_stale" begin
        stale = BRElections._cache_is_stale
        t = DateTime(2026, 10, 1, 12)
        # ETag decide quando os dois lados têm
        @test !stale(Dict("etag" => "\"a\""), Dict("etag" => "\"a\"", "last-modified" => "x"), t)
        @test stale(Dict("etag" => "\"a\""), Dict("etag" => "\"b\""), t)
        # sem ETag: Last-Modified / Content-Length
        @test stale(Dict("last-modified" => "A"), Dict("last-modified" => "B"), t)
        @test stale(Dict("content-length" => "10"), Dict("content-length" => "11"), t)
        @test !stale(Dict("content-length" => "10"), Dict("content-length" => "10"), t)
        # cache antigo, sem .meta: Last-Modified remoto contra o mtime local
        @test stale(Dict{String,String}(), Dict("last-modified" => "Sun, 04 Oct 2026 06:23:34 GMT"), t)
        @test !stale(Dict{String,String}(), Dict("last-modified" => "Mon, 01 Jan 2024 00:00:00 GMT"), t)
        # sem informação suficiente (ou data ilegível): mantém o cache
        @test !stale(Dict{String,String}(), Dict{String,String}(), t)
        @test !stale(Dict{String,String}(), Dict("last-modified" => "ontem"), t)
    end

    @testset "Revalidação do cache — arquivo .meta" begin
        dest = joinpath(mktempdir(), "x.zip")
        write(dest, "zip")
        meta = Dict("etag" => "\"2ce96-65cf\"", "last-modified" => "Sun, 04 Oct 2026 06:23:34 GMT",
                    "content-length" => "183958")
        BRElections._write_meta(dest, meta)
        @test BRElections._read_meta(dest) == meta
        BRElections._write_meta(dest, Dict{String,String}())   # sem validadores: remove
        @test !isfile(BRElections._meta_path(dest))
        @test isempty(BRElections._read_meta(dest))
    end

    @testset "download_file — check_updates" begin
        dest = joinpath(mktempdir(), "test.zip")
        write(dest, "cache")
        # sem rede: avisa e usa o cache
        r = @test_logs (:warn, r"Não foi possível verificar") BRElections.download_file(
            "http://url-falsa.tse/test.zip", dest; retries = 1)
        @test read(r, String) == "cache"
        # check_updates = false: nem consulta a rede
        r = @test_logs (:info, r"Cache") BRElections.download_file(
            "http://url-falsa.tse/test.zip", dest; check_updates = false)
        @test read(r, String) == "cache"
    end

    @testset "extract_csvs — reextrai quando o ZIP é mais novo" begin
        dir = mktempdir()
        zippath = make_fixture_zip(dir)
        csv = only(BRElections.extract_csvs(zippath))
        write(csv, "adulterado")
        # CSV mais novo que o ZIP: reaproveitado
        @test read(only(BRElections.extract_csvs(zippath)), String) == "adulterado"
        # ZIP atualizado (como após um novo download): reextrai
        touch(csv); sleep(1.1); touch(zippath)
        @test startswith(read(only(BRElections.extract_csvs(zippath)), String), "DT_GERACAO")
    end

    @testset "filter — nomes em qualquer caixa e sem avisos espúrios" begin
        dir = mktempdir()
        csv = only(BRElections.extract_csvs(make_fixture_zip(dir)))
        for pred in (row -> row.nr_turno == 1 && row.sg_uf == "PE",          # como no resultado
                     row -> row.NR_TURNO == 1 && row.SG_UF == "PE",          # como no arquivo
                     row -> row[:nr_turno] == 1 && row["SG_UF"] == "PE")     # indexação
            df = @test_logs min_level = Base.CoreLogging.Warn read_tse_csv(csv; filter = pred)
            @test nrow(df) == 2
        end
        # também com normalize_names = false
        df = read_tse_csv(csv; normalize_names = false, filter = row -> row.nr_turno == 2)
        @test nrow(df) == 1 && "NR_TURNO" in names(df)
        # coluna inexistente continua dando erro
        @test_throws ArgumentError read_tse_csv(csv; filter = row -> row.nao_existe == 1)
        # erro do próprio predicado não é engolido
        @test_throws DomainError read_tse_csv(csv; filter = row -> throw(DomainError(1)))
        # predicado que devolve `missing`: erro que explica o que fazer
        err = try read_tse_csv(csv; filter = row -> row.nr_cpf_candidato == "01234567890"); catch e; e; end
        @test err isa ArgumentError && occursin("coalesce", err.msg)
        # caixa mista, nome vindo de variável, hasproperty e propertynames
        col = "Nr_Turno"
        @test nrow(read_tse_csv(csv; filter = row -> getproperty(row, Symbol(col)) == 1)) == 3
        @test nrow(read_tse_csv(csv; filter = row -> hasproperty(row, :sg_uf) && !hasproperty(row, :xyz))) == 4
        @test nrow(read_tse_csv(csv; filter = row -> :NR_TURNO in propertynames(row))) == 4
    end

    @testset "filter — caminho em chunks" begin
        # Força o caminho de CSV.Chunks com um arquivo grande o suficiente.
        dir = mktempdir()
        csv = joinpath(dir, "grande.csv")
        open(csv, "w") do io
            println(io, "NR_TURNO;SG_UF;QT")
            for i in 1:20_000
                println(io, isodd(i) ? 1 : 2, ';', i % 3 == 0 ? "PE" : "BA", ';', i)
            end
        end
        old = BRElections.CHUNK_MIN_BYTES[]
        old_factor = BRElections.FILTER_MEMORY_FACTOR[]
        BRElections.CHUNK_MIN_BYTES[] = 0
        BRElections.FILTER_MEMORY_FACTOR[] = Inf      # "não cabe na memória"
        try
            df = read_tse_csv(csv; filter = row -> row.nr_turno == 1 && row.SG_UF == "PE", ntasks = 4)
            @test nrow(df) == count(i -> isodd(i) && i % 3 == 0, 1:20_000)
            @test names(df) == ["nr_turno", "sg_uf", "qt"]
            # ArgumentError do usuário não é confundido com falha de particionamento
            @test_throws ArgumentError read_tse_csv(csv; ntasks = 4,
                filter = row -> throw(ArgumentError("do usuário")))
        finally
            BRElections.CHUNK_MIN_BYTES[] = old
            BRElections.FILTER_MEMORY_FACTOR[] = old_factor
        end
        # cabe na memória: lê inteiro (mesmo resultado)
        BRElections.CHUNK_MIN_BYTES[] = 0
        try
            df = read_tse_csv(csv; filter = row -> row.nr_turno == 1 && row.SG_UF == "PE", ntasks = 4)
            @test nrow(df) == count(i -> isodd(i) && i % 3 == 0, 1:20_000)
            @test BRElections._filter_in_memory(csv)
        finally
            BRElections.CHUNK_MIN_BYTES[] = old
        end
    end

    @testset "municipalities — catálogo e parsing (offline)" begin
        # Formato real do ele-c.json, reduzido: a eleição geral mais recente é
        # a que tem o cargo 1 (Presidente), não a mais recente de todas.
        config = BRElections.JSON.parse("""
            { "pl" : [
              { "c" : "ele2022", "dt" : "02/10/2022", "e" : [
                { "cd" : "544", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "1", "ds" : "Presidente" } ] } ] } ] },
              { "c" : "ele2024", "dt" : "06/10/2024", "e" : [
                { "cd" : "619", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "11", "ds" : "Prefeito" } ] } ] } ] },
              { "c" : "ele2026", "dt" : "04/10/2026", "e" : [
                { "cd" : "6257", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "1", "ds" : "Presidente" } ] } ] },
                { "cd" : "6259", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "3", "ds" : "Governador" } ] } ] } ] },
              { "c" : "ele2024", "dt" : "21/06/2026", "e" : [
                { "cd" : "6280", "abr" : [ { "cd" : "sp", "mu" : [], "cp" : [ { "cd" : "11", "ds" : "Prefeito" } ] } ] } ] } ] }
            """)
        @test BRElections._latest_general_election(config) == ("ele2026", "6257")
        @test BRElections._municipalities_url("ele2026", "6257") ==
              "https://resultados.tse.jus.br/oficial/ele2026/6257/config/mun-e006257-cm.json"
        @test_throws ErrorException BRElections._latest_general_election(BRElections.JSON.parse("""{ "pl" : [] }"""))

        data = BRElections.JSON.parse("""
            { "abr" : [
              { "cd" : "pe", "ds" : "PERNAMBUCO", "mu" : [
                { "cd" : "25313", "cdi" : "2611606", "nm" : "RECIFE", "c" : "s", "z" : [ "0149", "0001" ] },
                { "cd" : "30015", "cdi" : "2605459", "nm" : "FERNANDO DE NORONHA", "c" : "n", "z" : [ "0004" ] } ] },
              { "cd" : "ac", "ds" : "ACRE", "mu" : [
                { "cd" : "01120", "cdi" : "1200013", "nm" : "ACRELÂNDIA", "c" : "n", "z" : [ "0008" ] } ] },
              { "cd" : "zz", "ds" : "EXTERIOR", "mu" : [
                { "cd" : "29254", "cdi" : "", "nm" : "ABIDJÃ", "c" : "n", "z" : [ "0001" ] } ] } ] }
            """)
        df = BRElections._parse_municipalities(data)
        @test names(df) == ["sg_uf", "cd_municipio", "cd_municipio_ibge", "nm_municipio", "capital", "zonas"]
        @test df.sg_uf == ["AC", "PE", "PE", "ZZ"]                  # ordenado por UF e nome
        @test df.cd_municipio == [1120, 30015, 25313, 29254]        # Int, sem zeros à esquerda (como nos CSVs)
        @test isequal(df.cd_municipio_ibge, [1200013, 2605459, 2611606, missing])
        @test df.capital == [false, false, true, false]
        @test df.zonas[3] == [1, 149]
        @test eltype(df.cd_municipio) == Int

        @test_throws ArgumentError municipalities(uf = "BR")
        @test_throws ArgumentError municipalities(uf = "XX")
    end

    @testset "live_results — escolha da eleição (offline)" begin
        config = BRElections.JSON.parse("""
            { "pl" : [
              { "c" : "ele2024", "dt" : "06/10/2024", "e" : [
                { "cd" : "619", "nm" : "Municipal 1T", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "11" }, { "cd" : "13" } ] } ] } ] },
              { "c" : "ele2024", "dt" : "27/10/2024", "e" : [
                { "cd" : "620", "nm" : "Municipal 2T", "abr" : [
                  { "cd" : "sp", "mu" : [ { "cd" : "71072" } ], "cp" : [ { "cd" : "11" } ] } ] } ] },
              { "c" : "ele2024", "dt" : "21/06/2026", "e" : [
                { "cd" : "6281", "nm" : "Suplementar Tuiuti", "abr" : [
                  { "cd" : "sp", "mu" : [ { "cd" : "69515" } ], "cp" : [ { "cd" : "11" } ] } ] },
                { "cd" : "6278", "nm" : "Suplementar RR", "abr" : [ { "cd" : "rr", "cp" : [ { "cd" : "3" } ] } ] } ] },
              { "c" : "ele2026", "dt" : "04/10/2026", "e" : [
                { "cd" : "6257", "nm" : "Federal 1T", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "1" } ] } ] },
                { "cd" : "6259", "nm" : "Estadual 1T", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "3" }, { "cd" : "5" } ] } ] } ] },
              { "c" : "ele2026", "dt" : "25/10/2026", "e" : [
                { "cd" : "6258", "nm" : "Federal 2T", "abr" : [ { "cd" : "br", "cp" : [ { "cd" : "1" } ] } ] } ] } ] }
            """)
        find(cargo; kw...) = BRElections._find_election(config, cargo; kw...).ele
        dia = Date(2026, 10, 4)
        # 2º turno ainda não realizado: fica com o 1º
        @test find(1; today = dia) == "6257"
        @test find(1; today = Date(2026, 10, 25)) == "6258"
        # só há eleições futuras: escolhe a mais próxima
        @test find(1; today = Date(2020, 1, 1)) == "6257"
        # abrangência com lista de municípios só serve para eles
        @test find(11; uf = "SP", municipality = 71072, today = dia) == "620"
        @test find(11; uf = "SP", municipality = 69515, today = dia) == "6281"
        @test find(11; uf = "SP", municipality = 50000, today = dia) == "619"
        @test find(11; uf = "PE", municipality = 25313, today = dia) == "619"
        # eleição estadual suplementar vale para a UF inteira, e só para ela
        @test find(3; uf = "RR", today = Date(2026, 7, 1)) == "6278"
        @test find(3; uf = "PE", today = Date(2026, 7, 1)) == "6259"   # única, embora futura
        @test find(13; uf = "SP", municipality = 71072, today = dia) == "619"   # vereador não teve 2º turno
        @test_throws ArgumentError BRElections._find_election(config, 99)
    end

    @testset "live_results — parsing (offline)" begin
        data = BRElections.JSON.parse("""
            { "ele" : "6278", "cdabr" : "rr", "dg" : "29/09/2026", "hg" : "19:26:03", "tf" : "s",
              "s" : { "ts" : "1483", "st" : "1483", "pst" : "100,00" },
              "e" : { "te" : "384582", "est" : "384582", "c" : "270558", "pc" : "70,35",
                      "a" : "114024", "pa" : "29,65" },
              "v" : { "tv" : "270558", "vv" : "102845", "pvv" : "39,13", "vb" : "3414", "pvb" : "1,26",
                      "tvn" : "4295", "ptvn" : "1,59" },
              "carg" : [ { "cd" : "3", "nmn" : "Governador", "nv" : "1", "agr" : [
                { "n" : "1", "nm" : "Roraima Segue em Frente", "par" : [ { "sg" : "REPUBLICANOS", "cand" : [
                  { "n" : "10", "sqcand" : "230002529860", "nm" : "FRANCISCO DOS SANTOS SAMPAIO",
                    "nmu" : "SOLDADO SAMPAIO", "dvt" : "Válido", "e" : "n", "st" : "Não eleito",
                    "vap" : "93897", "pvap" : "35,72", "pvapn" : "35,722791413" } ] } ] },
                { "n" : "2", "nm" : "PARTIDO LIBERAL", "par" : [ { "sg" : "PL", "cand" : [
                  { "n" : "22", "sqcand" : "230002529896", "nm" : "ARTHUR HENRIQUE BRANDÃO MACHADO",
                    "nmu" : "ARTHUR HENRIQUE", "dvt" : "Anulado sub judice", "e" : "n", "st" : "",
                    "vap" : "160004", "pvap" : "60,87", "pvapn" : "60,872972695" } ] } ] } ] } ] }
            """)
        df = BRElections._parse_live_results(data)
        @test names(df) == ["nr_candidato", "nm_urna_candidato", "nm_candidato", "sg_partido",
                            "nm_agremiacao", "qt_votos", "pc_votos", "eleito", "ds_situacao",
                            "ds_destinacao_voto", "sq_candidato"]
        @test df.nr_candidato == [22, 10]                     # ordem decrescente de votos
        @test df.qt_votos == [160004, 93897]
        @test df.pc_votos[1] ≈ 60.872972695
        @test isequal(df.ds_situacao, [missing, "Não eleito"])
        @test eltype(df.ds_situacao) == Union{Missing,String}
        @test df.sq_candidato[1] == "230002529896"
        m = metadata(df)
        @test m["cargo"] == "Governador" && m["vagas"] == 1 && m["abrangencia"] == "RR"
        @test m["atualizado_em"] == DateTime(2026, 9, 29, 19, 26, 3)
        @test m["totalizacao_final"] && m["pc_secoes_totalizadas"] == 100.0
        @test m["votos_validos"] == 102845 && m["votos_nulos"] == 4295
        @test m["pc_votos_validos"] ≈ 100 * 102845 / 270558           # sobre o total, não o `pvv`
        @test m["pc_votos_brancos"] == 1.26
        @test m["pc_comparecimento"] == 70.35 && m["pc_abstencao"] == 29.65
        @test m["eleitorado_apurado"] == 384582

        # sem candidatos: mesmo esquema
        data["carg"][1]["agr"] = []
        empty_df = BRElections._parse_live_results(data)
        @test nrow(empty_df) == 0 && names(empty_df) == names(df)
    end

    @testset "live_results — municípios, URL e validações (offline)" begin
        mun = DataFrame(sg_uf = ["RJ", "RJ", "RJ"], cd_municipio = [60011, 58858, 58130],
                        cd_municipio_ibge = [3304557, 3304300, 3300704],
                        nm_municipio = ["RIO DE JANEIRO", "RIO BONITO", "CABO FRIO"],
                        capital = [true, false, false], zonas = [[1], [2], [3]])
        resolve(q) = BRElections._resolve_municipality(mun, q).cd_municipio
        @test resolve("Rio de Janeiro") == 60011          # nome exato vence o trecho
        @test resolve("  rio de janeiro ") == 60011
        @test resolve("bonito") == 58858                  # trecho único
        @test resolve("cabo frio") == 58130
        @test resolve(60011) == 60011 && resolve("60011") == 60011   # código TSE
        @test resolve(3304300) == 58858                   # código IBGE
        @test_throws ArgumentError resolve("rio")         # ambíguo
        @test_throws ArgumentError resolve("Niterói")

        @test BRElections._live_results_url("ele2026", "6257", 1, "br", nothing) ==
              "https://resultados.tse.jus.br/oficial/ele2026/6257/dados/br/br-c0001-e006257-u.json"
        @test BRElections._live_results_url("ele2024", "619", 11, "sp", 1120) ==
              "https://resultados.tse.jus.br/oficial/ele2024/619/dados/sp/sp01120-c0011-e000619-u.json"

        @test BRElections._office_code(:mayor) == 11 && BRElections._office_code(6) == 6
        @test_throws ArgumentError live_results(:prefeito)
        err = try live_results(:vice_mayor; uf = "SP", municipality = "x"); catch e; e; end
        @test err isa ArgumentError && occursin("apuração própria", err.msg)

        # códigos conferidos contra consulta_cand (2014, 2022, 2024)
        @test OFFICES.president == 1 && OFFICES.vice_president == 2
        @test OFFICES.district_deputy == 8 && OFFICES.second_alternate == 10
        @test OFFICES.mayor == 11 && OFFICES.vice_mayor == 12 && OFFICES.councillor == 13
        @test sort(collect(values(OFFICES))) == 1:13
        @test all(k -> haskey(OFFICES, k), BRElections.LIVE_OFFICES)
        @test_throws ArgumentError live_results(:governor)                            # falta uf
        @test_throws ArgumentError live_results(:mayor; uf = "SP")                    # falta município
        @test_throws ArgumentError live_results(:president; municipality = "Recife")   # falta uf
        @test_throws ArgumentError live_results(:governor; uf = "XX")
    end

    @testset "Prestação de contas e novos datasets — URLs e anos" begin
        @test dataset_url(:candidate_revenue, 2022) ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/prestacao_contas/prestacao_de_contas_eleitorais_candidatos_2022.zip"
        @test dataset_url(:party_expenses_paid, 2024) ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/prestacao_contas/prestacao_de_contas_eleitorais_orgaos_partidarios_2024.zip"
        # as quatro tabelas de um prestador vêm do mesmo ZIP (e do mesmo cache)
        @test length(unique(dataset_url(t, 2022) for t in (:candidate_revenue, :candidate_revenue_original_donor,
                                                            :candidate_expenses_contracted, :candidate_expenses_paid))) == 1
        @test dataset_url(:candidate_social_media, 2022) ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/consulta_cand/rede_social_candidato_2022.zip"
        @test dataset_url(:voter_profile_section, 2022; uf = "pe") ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/perfil_eleitor_secao/perfil_eleitor_secao_2022_PE.zip"
        @test_throws ArgumentError dataset_url(:voter_profile_section, 2022)        # por UF
        # antes do primeiro ano do dataset
        @test_throws ArgumentError dataset_url(:candidate_revenue, 2016)
        @test_throws ArgumentError dataset_url(:cassation_reasons, 2010)
        @test dataset_url(:cassation_reasons, 2012) isa String

        @test_throws ArgumentError campaign_finance(2022; table = :receitas)
        @test_throws ArgumentError campaign_finance(2022; filer = :committees)
        @test_throws ArgumentError campaign_finance(2016; uf = "PE")              # antes de 2018, sem rede
    end

    @testset "extract_csvs — uma tabela de um ZIP com várias (member)" begin
        @test BRElections._matches_member("receitas_candidatos_2022_PE.csv", "receitas_candidatos")
        @test !BRElections._matches_member("receitas_candidatos_doador_originario_2022_PE.csv", "receitas_candidatos")
        @test BRElections._matches_member("RECEITAS_CANDIDATOS_DOADOR_ORIGINARIO_2022_PE.csv",
                                          "receitas_candidatos_doador_originario")
        @test BRElections._matches_member("qualquer.csv", "")

        dir = mktempdir()
        zippath = joinpath(dir, "prestacao_teste_2022.zip")
        w = ZipFile.Writer(zippath)
        for (table, rows) in (("receitas_candidatos", "1;100,50\n"),
                              ("receitas_candidatos_doador_originario", "2;7,25\n"),
                              ("despesas_pagas_candidatos", "3;9\n"))
            for uf in ("PE", "BA", "BRASIL")
                f = ZipFile.addfile(w, "$(table)_2022_$(uf).csv")
                write(f, "SQ;VR_VALOR\n" * rows)
            end
        end
        close(w)
        csvs = BRElections.extract_csvs(zippath; uf = "PE", member = "receitas_candidatos")
        @test basename.(csvs) == ["receitas_candidatos_2022_PE.csv"]
        csvs = BRElections.extract_csvs(zippath; member = "receitas_candidatos_doador_originario")
        @test basename.(csvs) == ["receitas_candidatos_doador_originario_2022_BRASIL.csv"]
        df = read_tse_csv(only(csvs))
        @test df.vr_valor == [7.25]                      # vírgula decimal convertida
    end

    @testset "Valores monetários (colunas VR_*)" begin
        dir = mktempdir()
        csv = joinpath(dir, "valores.csv")
        write(csv, """
            "SQ";"VR_VIRGULA";"VR_PONTO";"VR_INTEIRO";"VR_TEXTO";"VR_FALTANDO";"DS_VALOR"
            "1";"1500,00";"1270629.01";"10";"abc";"#NULO#";"1,5"
            "2";"0,5";"-1";"-1";"12,0";"2,25";"2,5"
            """)
        df = read_tse_csv(csv)
        @test df.vr_virgula == [1500.0, 0.5] && eltype(df.vr_virgula) == Float64
        @test df.vr_ponto == [1270629.01, -1.0]
        @test df.vr_inteiro == [10, -1]                  # já numérica: intocada
        @test df.vr_texto == ["abc", "12,0"]             # nem tudo é número: fica texto
        @test isequal(df.vr_faltando, [missing, 2.25])
        @test eltype(df.vr_faltando) == Union{Missing,Float64}
        @test df.ds_valor == ["1,5", "2,5"]              # só colunas VR_* são convertidas
        # o filtro já vê números; o resultado vazio mantém o tipo
        @test nrow(read_tse_csv(csv; filter = row -> row.vr_virgula > 1000)) == 1
        @test eltype(read_tse_csv(csv; filter = row -> false).vr_virgula) == Float64
        @test BRElections._parse_money("1.234,56") === nothing   # milhar + decimal: não arrisca
    end

    @testset "Extração em blocos — Latin-1/UTF-8 nas fronteiras" begin
        # Conversor próprio contra o iconv (StringEncodings), em todos os bytes.
        all_bytes = collect(0x00:0xff)
        @test BRElections.ensure_utf8(all_bytes) ==
              Vector{UInt8}(codeunits(decode(all_bytes, enc"ISO-8859-1")))

        @test BRElections._utf8_incomplete_tail(UInt8[0x41, 0xc3]) == 1            # 'Ã' cortado
        @test BRElections._utf8_incomplete_tail(UInt8[0x41, 0xc3, 0x83]) == 0
        @test BRElections._utf8_incomplete_tail(UInt8[0xe2, 0x82]) == 2            # '€' cortado
        @test BRElections._utf8_incomplete_tail(UInt8[0xf0, 0x9f, 0x98]) == 3      # emoji cortado
        @test BRElections._utf8_incomplete_tail(UInt8[0xf0, 0x9f, 0x98, 0x80]) == 0
        @test BRElections._utf8_incomplete_tail(UInt8[]) == 0

        texto = "DT;NOME\n" * join(("$(i);JOÃO DA CONCEIÇÃO € São Tomé 😀" for i in 1:50), "\n") * "\n"
        ascii = "DT;NOME\n" * join(("$(i);JOAO" for i in 1:50), "\n") * "\n"
        latin1 = encode(replace(texto, "€" => "E", "😀" => ":)"), enc"ISO-8859-1")
        # UTF-8 válido no começo e um byte Latin-1 (0xC7 = 'Ç') depois de vários
        # blocos: tem de refazer tudo como Latin-1, como o ensure_utf8 faria.
        misto = vcat(Vector{UInt8}(codeunits("A;" * "ã"^40 * "\n")), UInt8[0x42, 0xc7, 0x0a])

        dir = mktempdir()
        zippath = joinpath(dir, "enc_2022.zip")
        w = ZipFile.Writer(zippath)
        for (name, data) in (("utf8_2022_PE.csv", codeunits(texto)), ("ascii_2022_PE.csv", codeunits(ascii)),
                             ("latin1_2022_PE.csv", latin1), ("misto_2022_PE.csv", misto))
            f = ZipFile.addfile(w, name; method = ZipFile.Deflate)
            write(f, data)
        end
        close(w)

        old = BRElections.EXTRACT_CHUNK_BYTES[]
        try
            for chunk in (1, 2, 3, 5, 7, 64, 2^20)
                BRElections.EXTRACT_CHUNK_BYTES[] = chunk
                d = mktempdir()
                for (name, expected) in (("utf8", Vector{UInt8}(codeunits(texto))),
                                         ("ascii", Vector{UInt8}(codeunits(ascii))),
                                         ("latin1", BRElections.ensure_utf8(Vector{UInt8}(latin1))),
                                         ("misto", BRElections.ensure_utf8(misto)))
                    out = only(BRElections.extract_csvs(zippath; dest = d, member = name))
                    @test read(out) == expected
                    @test isvalid(String, read(out))
                end
            end
        finally
            BRElections.EXTRACT_CHUNK_BYTES[] = old
        end
        # Como no ensure_utf8: um byte inválido em UTF-8 faz o arquivo inteiro ser
        # lido como Latin-1, inclusive o trecho do começo que parecia UTF-8.
        @test read(only(BRElections.extract_csvs(zippath; dest = mktempdir(), member = "misto")), String) ==
              "A;" * "Ã£"^40 * "\nBÇ\n"
    end

    @testset "Revalidação do cache — intervalo mínimo" begin
        dest = joinpath(mktempdir(), "test.zip")
        write(dest, "cache")
        BRElections._write_meta(dest, Dict("etag" => "\"x\""))
        old = BRElections.REVALIDATE_INTERVAL[]
        try
            BRElections.REVALIDATE_INTERVAL[] = 3600
            # recém-verificado: usa o cache sem tocar na rede (a URL nem existe)
            @test_logs (:info, r"verificado no TSE há menos de 1.0 h") BRElections.download_file(
                "http://url-falsa.tse/test.zip", dest)
            BRElections.REVALIDATE_INTERVAL[] = 0
            before = mtime(BRElections._meta_path(dest))
            sleep(1.1)
            # intervalo vencido: consulta; falha de rede não marca a verificação
            @test_logs (:warn, r"Não foi possível verificar") BRElections.download_file(
                "http://url-falsa.tse/test.zip", dest; retries = 1)
            @test mtime(BRElections._meta_path(dest)) == before
            @test read(dest, String) == "cache"
        finally
            BRElections.REVALIDATE_INTERVAL[] = old
        end
        @test BRElections._fmt_interval(3600.0) == "1.0 h"
        @test BRElections._fmt_interval(600.0) == "10 min"
    end

    @testset "elections — vários anos (offline)" begin
        old_cache = cache_dir()
        set_cache_dir!(mktempdir())
        # Dois anos com esquemas diferentes, como os do TSE:
        #  * 2018 tem NM_EMAIL (renomeada para DS_EMAIL) e uma coluna que sumiu;
        #  * CD_CODIGO é número em 2018 e texto em 2022; VR_VALOR é Int e Float.
        files = Dict(
            2018 => "ANO_ELEICAO;SG_UF;NM_EMAIL;CD_CODIGO;VR_VALOR;SO_2018\n2018;PE;a@x.br;10;1;velha\n2018;BA;b@x.br;20;2;velha\n",
            2022 => "ANO_ELEICAO;SG_UF;DS_EMAIL;CD_CODIGO;VR_VALOR;SO_2022\n2022;PE;c@x.br;A1;1,5;nova\n",
        )
        for (y, content) in files
            zp = BRElections._zip_path(:candidates, dataset_url(:candidates, y))
            mkpath(dirname(zp))
            w = ZipFile.Writer(zp)
            f = ZipFile.addfile(w, "consulta_cand_$(y)_BRASIL.csv")
            write(f, content)
            close(w)
        end
        try
            df = candidates(2022:-4:2018; verbose = false, check_updates = false)   # ordem e repetição não importam
            @test names(df)[1] == "ano"
            @test df.ano == [2018, 2018, 2022]
            @test df.ds_email == ["a@x.br", "b@x.br", "c@x.br"]        # NM_EMAIL unificada
            @test !("nm_email" in names(df))
            @test df.cd_codigo == ["10", "20", "A1"]                    # Int + texto → texto
            @test eltype(df.cd_codigo) == String
            @test df.vr_valor == [1.0, 2.0, 1.5]                        # Int + Float → Float
            @test eltype(df.vr_valor) == Float64
            @test isequal(df.so_2018, ["velha", "velha", missing])      # colunas de um ano só
            @test isequal(df.so_2022, [missing, missing, "nova"])

            # pedir o nome atual traz o antigo também
            df = elections([2018, 2022, 2018]; type = :candidates, columns = [:sg_uf, :ds_email],
                           verbose = false, check_updates = false)
            @test names(df) == ["ano", "sg_uf", "ds_email"]
            @test df.ds_email == ["a@x.br", "b@x.br", "c@x.br"]

            # filter e normalize_names = false continuam valendo
            df = candidates([2018, 2022]; filter = row -> row.sg_uf == "PE", normalize_names = false,
                            verbose = false, check_updates = false)
            @test df.ANO == [2018, 2022] && "DS_EMAIL" in names(df)
        finally
            set_cache_dir!(old_cache)
        end

        # validação antes de qualquer download
        @test_throws ArgumentError candidates(Int[])
        @test_throws ArgumentError campaign_finance([2016, 2022]; uf = "PE")       # 2016 < 2018
        @test_throws ArgumentError section_votes([2018, 2022])                      # falta uf
        @test_throws ArgumentError candidates([2018, 2019])                         # ano ímpar
    end

    @testset "Proveniência — sources e cite (offline)" begin
        old_cache = cache_dir()
        set_cache_dir!(mktempdir())
        etag = "\"abc-123\""
        for y in (2018, 2022)
            zp = BRElections._zip_path(:candidates, dataset_url(:candidates, y))
            mkpath(dirname(zp))
            w = ZipFile.Writer(zp)
            for uf in ("PE", "BA")
                f = ZipFile.addfile(w, "consulta_cand_$(y)_$(uf).csv")
                write(f, "ANO_ELEICAO;SG_UF;NR_TURNO\n$y;$uf;1\n$y;$uf;2\n")
            end
            close(w)
            BRElections._write_meta(zp, Dict("etag" => etag,
                                             "last-modified" => "Tue, 04 Oct 2022 10:20:30 GMT"))
        end
        try
            df = candidates(2022; uf = "PE", columns = [:SG_UF, :nr_turno], filter = r -> r.nr_turno == 1,
                            verbose = false, check_updates = false)
            src = sources(df)
            @test nrow(src) == 1
            r = src[1, :]
            @test r.dataset == :candidates && r.ano == 2022 && r.uf == "PE"
            @test r.url == dataset_url(:candidates, 2022)
            @test r.arquivos == ["consulta_cand_2022_PE.csv"]
            @test r.publicado_em == DateTime(2022, 10, 4, 10, 20, 30)
            @test r.etag == etag
            @test r.baixado_em isa DateTime && r.verificado_em isa DateTime
            @test r.colunas == ["sg_uf", "nr_turno"]
            @test r.filtrado
            @test metadata(df, "versao_brelections") == string(pkgversion(BRElections))
            @test metadata(df, "dataset") == "candidates"

            # acompanha operações do DataFrames.jl
            @test nrow(sources(select(df, :sg_uf))) == 1

            # sem filtro/colunas, Brasil inteiro
            r = sources(candidates(2022; verbose = false, check_updates = false))[1, :]
            @test ismissing(r.uf) && ismissing(r.colunas) && !r.filtrado
            @test sort(r.arquivos) == ["consulta_cand_2022_BA.csv", "consulta_cand_2022_PE.csv"]

            # vários anos: uma fonte por ano, mesmo com o vcat
            many = candidates([2018, 2022]; uf = "PE", verbose = false, check_updates = false)
            @test sources(many).ano == [2018, 2022]

            # citações
            acc = BRElections._abnt_date(Date(sources(df).verificado_em[1]))
            abnt = cite(df)
            @test occursin("BRASIL. Tribunal Superior Eleitoral. Repositório de dados eleitorais: " *
                           "Candidaturas registradas (consulta_cand) — 2022, PE. Brasília: TSE, 2022.", abnt)
            @test occursin("Acesso em: $acc.", abnt)
            @test occursin("BERTUZZI, Dante. BRElections.jl", abnt)
            @test occursin("Versão $(pkgversion(BRElections))", abnt)
            @test count("BRASIL. Tribunal", cite(many)) == 2
            @test occursin("[Data set]. Retrieved ", cite(df; style = :apa))
            bib = cite(many; style = :bibtex)
            @test occursin("@misc{tse_candidates_2018_pe,", bib) && occursin("@misc{tse_candidates_2022_pe,", bib)
            @test occursin("note = {ETag abc-123}", bib)
            @test occursin("@software{bertuzzi_brelections_", bib)
            @test_throws ArgumentError cite(df; style = :vancouver)
            @test_throws ArgumentError sources(DataFrame(a = 1))
            @test BRElections._abnt_date(Date(2026, 5, 3)) == "3 maio 2026"
        finally
            set_cache_dir!(old_cache)
        end
    end

    @testset "Várias UFs e uf = :all / \"BR\" (offline)" begin
        N = BRElections._normalize_uf
        @test N(nothing) === nothing && N("pe") == "PE" && N(:all) === :all
        @test N(["pe", "BA", "PE"]) == ["BA", "PE"]
        @test N(["sp"]) == "SP"
        @test_throws ArgumentError N(String[])
        @test_throws ArgumentError N(:todas)
        @test_throws ArgumentError N(["PE", "XX"])

        # votos para Presidente por seção: só no ZIP BR, em eleições gerais
        @test endswith(dataset_url(:section_votes, 2022; uf = "BR"), "votacao_secao_2022_BR.zip")
        @test_throws ArgumentError dataset_url(:section_votes, 2024; uf = "BR")
        @test_throws ArgumentError dataset_url(:voter_profile_section, 2022; uf = "BR")

        old_cache = cache_dir()
        set_cache_dir!(mktempdir())
        csv(y, uf) = "ANO_ELEICAO;SG_UF;QT_VOTOS\n$y;$uf;1\n$y;$uf;2\n"
        zp = BRElections._zip_path(:candidates, dataset_url(:candidates, 2022))
        mkpath(dirname(zp))
        w = ZipFile.Writer(zp)
        for uf in ("PE", "BA", "SP")
            write(ZipFile.addfile(w, "consulta_cand_2022_$(uf).csv"), csv(2022, uf))
        end
        close(w)
        for uf in ("PE", "BA")
            zp = BRElections._zip_path(:section_votes, dataset_url(:section_votes, 2022; uf))
            mkpath(dirname(zp))
            w = ZipFile.Writer(zp)
            write(ZipFile.addfile(w, "votacao_secao_2022_$(uf).csv"), csv(2022, uf))
            close(w)
        end
        try
            # dataset nacional: só os arquivos das UFs pedidas, de um ZIP
            df = candidates(2022; uf = ["pe", "BA"], verbose = false, check_updates = false)
            @test sort(unique(df.sg_uf)) == ["BA", "PE"] && nrow(df) == 4
            @test sources(df).uf == ["BA, PE"]
            extracted = readdir(BRElections._extract_dir(BRElections._zip_path(:candidates, dataset_url(:candidates, 2022))))
            @test !("consulta_cand_2022_SP.csv" in extracted)
            @test nrow(candidates(2022; uf = :all, verbose = false, check_updates = false)) == 6

            # dataset por UF: um ZIP por UF, empilhados
            df = section_votes(2022; uf = ["PE", "BA"], columns = [:sg_uf], verbose = false, check_updates = false)
            @test df.sg_uf == ["BA", "BA", "PE", "PE"] && names(df) == ["sg_uf"]
            @test sources(df).uf == ["BA", "PE"]
            @test count("BRASIL. Tribunal", cite(df)) == 2

            # com vários anos também
            df = section_votes([2022]; uf = ["PE", "BA"], verbose = false, check_updates = false)
            @test nrow(df) == 4 && names(df)[1] == "ano"
            @test_throws ArgumentError section_votes([2020, 2022]; uf = ["PE", "XX"])
        finally
            set_cache_dir!(old_cache)
        end
    end

    @testset "Locais de votação — CSV único, coordenadas e CEP (offline)" begin
        @test BRElections._partitioned(["x_2022_PE.csv", "x_2022_BRASIL.csv"])
        @test !BRElections._partitioned(["eleitorado_local_votacao_2022.csv"])
        @test dataset_url(:polling_places, 2010) ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/eleitorado_locais_votacao/eleitorado_local_votacao_2010.zip"
        @test_throws ArgumentError dataset_url(:polling_places, 2008)

        old_cache = cache_dir()
        set_cache_dir!(mktempdir())
        # Até 2024: um CSV só, sem UF no nome; ponto decimal e -1 sem coordenada.
        # 2026: um CSV por UF e vírgula decimal.
        header = "NR_TURNO;SG_UF;NM_LOCAL_VOTACAO;NR_CEP;NR_TELEFONE_LOCAL;NR_LATITUDE;NR_LONGITUDE"
        single = join([header,
            "1;\"PE\";\"ESCOLA A\";\"50000000\";\"+558133330000\";\"-8.05\";\"-34.9\"",
            "2;\"PE\";\"ESCOLA A\";\"50000000\";\"+558133330000\";\"-8.05\";\"-34.9\"",
            "1;\"PE\";\"ESCOLA B\";\"55190000\";\"-1\";\"-1\";\"-1\"",
            "1;\"SP\";\"ESCOLA C\";\"01310100\";\"-1\";\"-23.56\";\"-46.65\"",
            "1;\"BA\";\"ESCOLA D\";\"40000000\";\"-1\";\"-12.97\";\"-38.5\""], "\n") * "\n"
        zp = BRElections._zip_path(:polling_places, dataset_url(:polling_places, 2022))
        mkpath(dirname(zp))
        w = ZipFile.Writer(zp)
        write(ZipFile.addfile(w, "eleitorado_local_votacao_2022.csv"), single)
        close(w)
        zp = BRElections._zip_path(:polling_places, dataset_url(:polling_places, 2026))
        w = ZipFile.Writer(zp)
        for (uf, row) in (("PE", "1;\"PE\";\"ESCOLA A\";\"50000000\";\"-1\";\"-8,05\";\"-34,9\""),
                          ("SP", "1;\"SP\";\"ESCOLA C\";\"01310100\";\"-1\";\"-23,56\";\"-46,65\""))
            write(ZipFile.addfile(w, "eleitorado_local_votacao_2026_$(uf).csv"), header * "\n" * row * "\n")
        end
        close(w)
        kw = (verbose = false, check_updates = false)
        try
            df = polling_places(2022; kw...)
            @test nrow(df) == 5
            @test eltype(df.nr_cep) == String && df.nr_cep[4] == "01310100"       # zero à esquerda
            @test eltype(df.nr_latitude) == Union{Missing,Float64}
            @test isequal(df.nr_latitude, [-8.05, -8.05, missing, -23.56, -12.97])
            @test isequal(df.nr_telefone_local, ["+558133330000", "+558133330000", missing, missing, missing])

            # uf num ZIP sem divisão por UF: filtro de linhas por SG_UF
            pe = polling_places(2022; uf = "pe", kw...)
            @test nrow(pe) == 3 && all(==("PE"), pe.sg_uf)
            @test sources(pe).uf == ["PE"] && !sources(pe).filtrado[1]
            # ... mesmo sem pedir SG_UF em `columns`, que não volta na tabela
            pe1 = polling_places(2022; uf = "PE", columns = [:nr_turno, :nm_local_votacao],
                                 filter = r -> r.nr_turno == 1, kw...)
            @test names(pe1) == ["nr_turno", "nm_local_votacao"]
            @test pe1.nm_local_votacao == ["ESCOLA A", "ESCOLA B"]
            @test sources(pe1).filtrado[1]
            two = polling_places(2022; uf = ["SP", "BA"], columns = [:SG_UF], normalize_names = false, kw...)
            @test names(two) == ["SG_UF"] && sort(two.SG_UF) == ["BA", "SP"]

            # 2026: arquivos por UF, vírgula decimal
            df = polling_places(2026; uf = "SP", kw...)
            @test df.nr_cep == ["01310100"] && df.nr_latitude == [-23.56] && df.nr_longitude == [-46.65]
            @test_throws ArgumentError polling_places(2026; uf = "BA", kw...)        # UF sem arquivo
        finally
            set_cache_dir!(old_cache)
        end
    end

    @testset "cache_info e clear_cache! por dataset" begin
        old_cache = cache_dir()
        cache = set_cache_dir!(mktempdir())
        try
            @test nrow(cache_info()) == 0
            # Cache simulado: dois anos de votação, um ZIP por UF, prestação de
            # contas (ZIP compartilhado por quatro tabelas) e lixo que não é dataset.
            function fake(type, year; uf = nothing, zip = 2^20, csv = 3 * 2^20, meta = true)
                url = DATASETS_URL(type, year, uf)
                zp = BRElections._zip_path(type, url)
                mkpath(dirname(zp)); write(zp, zeros(UInt8, zip))
                meta && BRElections._write_meta(zp, Dict("etag" => "\"x\""))
                d = BRElections._extract_dir(zp); mkpath(d)
                write(joinpath(d, "dados.csv"), zeros(UInt8, csv))
                zp
            end
            DATASETS_URL(t, y, uf) = uf === nothing ? dataset_url(t, y) : dataset_url(t, y; uf)
            fake(:candidate_votes, 2018)
            fake(:candidate_votes, 2022; meta = false)
            fake(:section_votes, 2022; uf = "PE")
            fake(:candidate_revenue, 2022; zip = 4 * 2^20)
            fake(:candidates, 2022)
            write(joinpath(cache, "consulta_cand", "outra_coisa_2022.zip"), "x")      # ignorado
            mkpath(joinpath(cache, "resultados", "comum")); write(joinpath(cache, "resultados", "comum", "x.json"), "{}")

            info = cache_info()
            @test nrow(info) == 6
            @test names(info) == ["datasets", "year", "uf", "zip_mb", "extracted_mb", "checked_at", "path"]
            fin = only(subset(info, :datasets => ByRow(d -> :candidate_revenue in d)))
            @test fin.datasets == [:candidate_expenses_contracted, :candidate_expenses_paid,
                                   :candidate_revenue, :candidate_revenue_original_donor]
            @test fin.zip_mb == 4.0 && fin.extracted_mb == 3.0
            @test info.zip_mb[1] == 4.0                                  # maior primeiro
            sec = only(subset(info, :datasets => ByRow(==([:section_votes]))))
            @test sec.uf == "PE" && sec.year == 2022
            v22 = only(subset(info, :datasets => ByRow(==([:candidate_votes])), :year => ByRow(isequal(2022))))
            @test ismissing(v22.checked_at)                              # sem .meta
            v18 = only(subset(info, :datasets => ByRow(==([:candidate_votes])), :year => ByRow(isequal(2018))))
            @test abs(v18.checked_at - now()) < Minute(5)                # horário local
            @test any(d -> d == [:municipalities], info.datasets)

            # só os CSVs extraídos: o ZIP fica
            @test clear_cache!(:candidate_votes; year = 2018, extracted_only = true) == 3 * 2^20
            v18 = only(subset(cache_info(), :datasets => ByRow(==([:candidate_votes])), :year => ByRow(isequal(2018))))
            @test v18.zip_mb == 1.0 && v18.extracted_mb == 0.0
            # um ano: ZIP, .meta e extraídos
            freed = clear_cache!(:candidate_votes; year = [2018])
            @test freed >= 2^20
            @test !isfile(v18.path) && !isfile(v18.path * ".meta")
            @test nrow(subset(cache_info(), :datasets => ByRow(==([:candidate_votes])))) == 1
            # todos os anos; uma tabela de prestação de contas limpa o ZIP das quatro
            clear_cache!(:candidate_votes)
            clear_cache!(:candidate_expenses_paid)
            left = cache_info()
            @test !any(d -> :candidate_votes in d || :candidate_revenue in d, left.datasets)
            @test any(d -> d == [:candidates], left.datasets)              # o resto fica
            @test isfile(joinpath(cache, "consulta_cand", "outra_coisa_2022.zip"))
            @test clear_cache!(:assets) == 0                                # nada em cache
            @test_throws ArgumentError clear_cache!(:nao_existe)
        finally
            set_cache_dir!(old_cache)
        end
    end

    @testset "url_exists — erro de rede/URL retorna false" begin
        @test BRElections.url_exists("not a valid url") == false
        @test BRElections.url_status("not a valid url") == 0
    end

    # -----------------------------------------------------------------------
    # Testes de rede (opcionais): BRElections_TEST_NETWORK=true julia --project -e 'using Pkg; Pkg.test()'
    # -----------------------------------------------------------------------
    if get(ENV, "BRElections_TEST_NETWORK", "false") == "true"
        # O TSE bloqueia (HTTP 403 do WAF da Akamai) ou fica indisponível de
        # tempos em tempos. Isso não é link quebrado: falhar nesse caso só
        # produziria alarme falso semanal. Sonda uma URL conhecida antes de
        # rodar os testes de rede e, se o CDN não estiver respondendo, pula.
        probe_url = dataset_url(:vacancies, 2022)
        probe = BRElections.url_status(probe_url)
        cdn_up = 200 <= probe < 300 || probe == 404   # 404 = link quebrado de verdade

        if !cdn_up
            @warn """
                  CDN do TSE indisponível (HTTP $probe) — testes de rede pulados.
                  Isso indica bloqueio/indisponibilidade do lado do TSE, não link quebrado.
                  """ probe_url
        end

        @testset "Rede (TSE)" begin
            if !cdn_up
                @test_skip BRElections.url_exists(probe_url)
            else
                @test BRElections.url_exists(probe_url)

                # Checa os links de todos os datasets (available_datasets()) em
                # mais de um ano — pega tanto quebra de link pontual quanto
                # mudanças de estrutura do CDN entre ciclos eleitorais.
                for year in (2022, BRElections.LAST_KNOWN_YEAR)
                    @testset "available_files($year)" begin
                        av = available_files(year; ufs = ["PE"])
                        @test av isa DataFrame

                        # Só conta como ausente o que o CDN respondeu 404.
                        # 403/5xx/0 são indisponibilidade — reporta à parte.
                        gone = av[av.status .== 404, [:dataset, :uf, :url]]
                        unreachable = av[.!av.exists .&& av.status .!= 404,
                                         [:dataset, :uf, :url, :status]]

                        isempty(gone) ||
                            @warn "Datasets ausentes no CDN do TSE (HTTP 404)" year gone
                        isempty(unreachable) ||
                            @warn "Datasets inacessíveis (CDN recusou ou não respondeu)" year unreachable

                        @test isempty(gone)
                    end
                end

                # uf = :all descobre os ZIPs publicados, que variam com o ano
                mun = BRElections._published_ufs(:section_votes, 2024)
                @test "PE" in mun && !("DF" in mun) && !("BR" in mun)
                @test "BR" in BRElections._published_ufs(:section_votes, 2022)
                @test "ZZ" in BRElections._published_ufs(:voter_profile_section, 2022)

                # consulta_vagas é o menor dataset — bom para smoke test
                df = vacancies(2022; verbose = false)
                @test nrow(df) > 0
                @test "sg_uf" in names(df)

                pe = vacancies(2022; uf = "PE", verbose = false)
                @test all(==("PE"), skipmissing(pe.sg_uf))

                # Revalidação: o download grava os validadores; com o cache em
                # dia, a próxima chamada não baixa de novo.
                zippath = BRElections._zip_path(:vacancies, probe_url)
                @test haskey(BRElections._read_meta(zippath), "etag")
                before = mtime(zippath)
                # recém-baixado: dentro do intervalo, nem consulta o TSE
                @test_logs (:info, r"verificado no TSE há menos") match_mode = :any vacancies(2022)
                old_interval = BRElections.REVALIDATE_INTERVAL[]
                BRElections.REVALIDATE_INTERVAL[] = 0
                try
                    @test_logs (:info, r"em dia") match_mode = :any vacancies(2022)
                    @test mtime(zippath) == before
                    # ETag local diferente do publicado: baixa a versão nova
                    BRElections._write_meta(zippath, Dict("etag" => "\"versao-antiga\""))
                    @test_logs (:info, r"nova versão") match_mode = :any vacancies(2022)
                    @test BRElections._read_meta(zippath)["etag"] != "\"versao-antiga\""
                finally
                    BRElections.REVALIDATE_INTERVAL[] = old_interval
                end

                # Vários anos, de verdade (vagas: arquivos pequenos)
                vagas = vacancies([2018, 2022]; uf = "PE", verbose = false)
                @test Set(vagas.ano) == Set([2018, 2022])
                @test all(vagas.ano .== vagas.ano_eleicao)

                # Correspondência TSE ↔ IBGE
                mun = municipalities(verbose = false)
                @test nrow(mun) > 5_500
                @test count(mun.capital) == 27
                sp = only(subset(mun, :cd_municipio => ByRow(==(71072))))
                @test (sp.sg_uf, sp.cd_municipio_ibge, sp.nm_municipio) == ("SP", 3550308, "SÃO PAULO")
                @test all(ismissing, subset(mun, :sg_uf => ByRow(==("ZZ"))).cd_municipio_ibge)
                @test allunique(skipmissing(mun.cd_municipio_ibge))
                pe = municipalities(uf = "pe", verbose = false)
                @test all(==("PE"), pe.sg_uf) && 30015 in pe.cd_municipio   # Fernando de Noronha

                # Datasets novos (pequenos)
                cass = cassation_reasons(2022; uf = "PE", verbose = false)
                @test nrow(cass) > 0 && "ds_motivo" in names(cass)
                redes = candidate_social_media(2022; uf = "PE", verbose = false)
                @test nrow(redes) > 0 && "ds_url" in names(redes)

                # Apuração (Divulgação de Resultados): eleição já totalizada
                sp = live_results(:mayor; uf = "SP", municipality = "São Paulo", verbose = false)
                @test metadata(sp, "totalizacao_final")
                @test metadata(sp, "abrangencia") == "SÃO PAULO - SP"
                @test count(sp.eleito) == 1 && first(sp.eleito)
                @test sum(sp.pc_votos) ≈ 100 atol = 0.01
                br = live_results(:president; verbose = false)
                @test nrow(br) > 0 && metadata(br, "abrangencia") == "BR"
                @test metadata(br, "secoes") > 400_000
            end
        end
    else
        @info "Testes de rede desativados. Ative com BRElections_TEST_NETWORK=true."
    end
end
