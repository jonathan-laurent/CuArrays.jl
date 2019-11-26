using Documenter
using Literate

@show get(ENV, "CI_BUILDS_DIR", nothing)
@show get(ENV, "CI_COMMIT_REF_NAME", nothing)
@show get(ENV, "CI_PAGES_DOMAIN", nothing)
@show get(ENV, "CI_PAGES_URL", nothing)
@show get(ENV, "CI_PROJECT_DIR", nothing)
@show get(ENV, "CI_PROJECT_NAME", nothing)
@show get(ENV, "CI_PROJECT_NAMESPACE", nothing)
@show get(ENV, "CI_PROJECT_PATH", nothing)
@show get(ENV, "CI_PROJECT_PATH_SLUG", nothing)
@show get(ENV, "CI_PROJECT_URL", nothing)
@show get(ENV, "GITLAB_CI", nothing)
@show get(ENV, "CI_REPOSITORY_URL", nothing)
exit(1)

using CuArrays

# generate tutorials
OUTPUT = joinpath(@__DIR__, "src/tutorials/generated")
Literate.markdown(joinpath(@__DIR__, "src/tutorials/intro.jl"), OUTPUT)

makedocs(
    modules = [CuArrays],
    format = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
    sitename = "CuArrays.jl",
    pages = [
        "Home" => "index.md",
        "Tutorials"  => [
            "tutorials/generated/intro.md"
        ],
    ],
    doctest = true
)
