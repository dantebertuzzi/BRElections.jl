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
        @test_throws ArgumentError BRElections.validate_uf("XX")
    end

    @testset "URLs" begin
        @test dataset_url(:candidates, 2022) ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/consulta_cand/consulta_cand_2022.zip"
        @test dataset_url(:section_votes, 2020; uf = "pe") ==
              "https://cdn.tse.jus.br/estatistica/sead/odsele/votacao_secao/votacao_secao_2020_PE.zip"
        @test_throws ArgumentError dataset_url(:section_votes, 2020)            # UF obrigatória
        @test_throws ArgumentError dataset_url(:section_votes, 2020; uf = "BR") # sem arquivo nacional
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
        @test names(ds) == ["dataset", "tse_dir", "by_uf", "description"]
        @test eltype(ds.dataset) == Symbol
        @test eltype(ds.tse_dir) == String
        @test eltype(ds.by_uf) == Bool
        @test eltype(ds.description) == String
        @test :section_votes in ds.dataset
        datasets_by_uf = Set(ds.dataset[ds.by_uf])
        @test datasets_by_uf == Set([:section_votes, :section_vote_details])
        @test length(datasets_by_uf) == 2
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

        df = elections(2022; type = :candidates, verbose = false)
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

        df = elections(2022; type = :section_votes, uf = "PE", verbose = false)
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

        df = elections(2022; type = :candidates, columns = [:nr_turno, "SG_UF"], verbose = false)
        @test names(df) == ["nr_turno", "sg_uf"]
        @test nrow(df) == 4

        df_f = elections(2022; type = :candidates,
                         filter = row -> row.NR_TURNO == 1 && row.SG_UF == "PE",
                         verbose = false)
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

        df = elections(2022; type = :candidates, normalize_names = false, verbose = false)
        @test "NR_TURNO" in names(df)
        @test "DT_GERACAO" in names(df)

        set_cache_dir!(old_cache)
    end

    # -----------------------------------------------------------------------
    # Testes de rede (opcionais): BRElections_TEST_NETWORK=true julia --project -e 'using Pkg; Pkg.test()'
    # -----------------------------------------------------------------------
    if get(ENV, "BRElections_TEST_NETWORK", "false") == "true"
        @testset "Rede (TSE)" begin
            @test BRElections.url_exists(dataset_url(:vacancies, 2022))
            av = available_files(2022; ufs = ["PE"])
            @test av isa DataFrame && all(av.exists)

            # consulta_vagas é o menor dataset — bom para smoke test
            df = vacancies(2022; verbose = false)
            @test nrow(df) > 0
            @test "sg_uf" in names(df)

            pe = vacancies(2022; uf = "PE", verbose = false)
            @test all(==("PE"), skipmissing(pe.sg_uf))
        end
    else
        @info "Testes de rede desativados. Ative com BRElections_TEST_NETWORK=true."
    end
end
