using Documenter
using BRElections

makedocs(
    sitename = "BRElections.jl",
    modules = [BRElections],
    format = Documenter.HTML(prettyurls = get(ENV, "CI", "false") == "true"),
    pages = [
        "Início" => "index.md",
        "Referência da API" => "api.md",
    ],
    checkdocs = :exports,
)

deploydocs(repo = "github.com/SEU_USUARIO/BRElections.jl.git")
