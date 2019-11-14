using BinaryProvider
using CUDAnative

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
@assert isempty([a for a in ARGS if a != "--verbose"])

# online sources we can use
const bin_prefix = "https://github.com/JuliaGPU/CUDABuilder/releases/download/v0.1.1"
const resources = Dict(
    v"10.1" =>
        Dict(
            MacOS(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-cuda101.x86_64-apple-darwin14.tar.gz", "245a0664660baa56692637dc538afe18bcd6d2070c4db5d2791a776978864807"),
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-cuda101.x86_64-linux-gnu.tar.gz", "abaacd936474526bafd390ad9eb2de9749f9bb400e9d9dffa3ef41d0b1b8c319"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-cuda101.x86_64-w64-mingw32.tar.gz", "b69695f116f2fd3d962ecbec0c88cf9835940b025432bc8766f2d012a01135b2"),
        ),
    v"10.0" =>
        Dict(
            MacOS(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-cuda100.x86_64-apple-darwin14.tar.gz", "ec8f2525a3eba29168d00ffca9e504cde348bfa29bc784299a3d9363238bc27b"),
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-cuda100.x86_64-linux-gnu.tar.gz", "5a47e076bf508db5a8c18bf37e6827c13faedc665d5b0322f6bdbab297d56f5a"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-cuda100.x86_64-w64-mingw32.tar.gz", "75ba4bbcbe2cb08a85ac85b187043bf3285bb47d62e5162f1d1cf1bdb47c0a58"),
        ),
    v"9.2" =>
        Dict(
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-cuda92.x86_64-linux-gnu.tar.gz", "3f53342ddb8561d7434cd700fea5d382f6b8640c1fc9e3756fb259841fdef35c"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-cuda92.x86_64-apple-darwin14.tar.gz", "e18014d3baa8abc6aba11162332f9658163599fc833ba6b59b9093be4f12aef1"),
        ),
    v"9.0" =>
        Dict(
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-cuda90.x86_64-linux-gnu.tar.gz", "9d4b6dcc8de94ae6f79b0790c7cd30764a0c79c06f7b8f34afd63d7572fb00e1"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-cuda90.x86_64-apple-darwin14.tar.gz", "5e64681cd1022ed382126f0d76442c7063cec58052f3b4582fc80f6a8d5253b8"),
        ),
)

# stuff we need to resolve
const cuarrays_prefix = Prefix(joinpath(@__DIR__, "usr"))
const cuarrays_products = if Sys.iswindows()
    width = Sys.WORD_SIZE
    [
        LibraryProduct(cuarrays_prefix, "cudnn$(width)_7", :libcudnn),
    ]
else
    [
        LibraryProduct(cuarrays_prefix, "libcudnn", :libcudnn),
    ]
end

# stuff we resolve in CUDAnative's prefix
const cudanative_prefix = Prefix(joinpath(dirname(dirname(pathof(CUDAnative))), "deps", "usr"))
const cudanative_products = if Sys.iswindows()
    # on Windows, library names are version dependent. That's a problem if were not using
    # BinaryBuilder, becuase that means we don't know the CUDA toolkit version yet!
    #
    # However, we can't just bail out here, because that would break users of packages
    # like Flux which depend on CuArrays but don't necessarily use it.
    try
        width = Sys.WORD_SIZE
        ver = CUDAnative.version()
        verstr = ver >= v"10.1" ? "$(ver.major)" : "$(ver.major)$(ver.minor)"
        [
            LibraryProduct(cudanative_prefix, "cufft$(width)_$(verstr)", :libcufft),
            LibraryProduct(cudanative_prefix, "curand$(width)_$(verstr)", :libcurand),
            LibraryProduct(cudanative_prefix, "cublas$(width)_$(verstr)", :libcublas),
            LibraryProduct(cudanative_prefix, "cusolver$(width)_$(verstr)", :libcusolver),
            LibraryProduct(cudanative_prefix, "cusparse$(width)_$(verstr)", :libcusparse),
        ]
    catch
        # just fail at runtime
        @error "On Windows, the CUDA toolkit version needs to be known at build time."
        @assert !CUDAnative.use_binarybuilder
        nothing
    end
else
    [
        LibraryProduct(cudanative_prefix, "libcufft", :libcufft),
        LibraryProduct(cudanative_prefix, "libcurand", :libcurand),
        LibraryProduct(cudanative_prefix, "libcublas", :libcublas),
        LibraryProduct(cudanative_prefix, "libcusolver", :libcusolver),
        LibraryProduct(cudanative_prefix, "libcusparse", :libcusparse),
    ]
end

const products = vcat(cuarrays_products, cudanative_products)
unsatisfied(products) = any(!satisfied(p; verbose=verbose) for p in products)

const depsfile = joinpath(@__DIR__, "deps.jl")

function main()
    rm(depsfile; force=true)

    use_binarybuilder = parse(Bool, get(ENV, "JULIA_CUDA_USE_BINARYBUILDER", "true"))
    if use_binarybuilder
        if try_binarybuilder()
            @assert !unsatisfied(products) && !unsatisfied(cudanative_products)
            return
        end
    end

    do_fallback()

    return
end

function try_binarybuilder()
    @info "Trying to provide CUDA libraries using BinaryBuilder"

    # get some libraries from CUDAnative
    if !CUDAnative.use_binarybuilder
        @warn "CUDAnative has not been built with BinaryBuilder, so CuArrays can't either."
        return false
    end
    @assert !unsatisfied(cudanative_products)

    # XXX: should it be possible to use CUDAnative without BB, but still download CUDNN?

    cuda_version = CUDAnative.version()
    @info "Working with CUDA $cuda_version"

    if !haskey(resources, cuda_version)
        @warn("Selected CUDA version is not available through BinaryBuilder.")
        return false
    end
    download_info = resources[cuda_version]

    # Install unsatisfied or updated dependencies:
    dl_info = choose_download(download_info, platform_key_abi())
    if dl_info === nothing && unsatisfied(cuarrays_products)
        # If we don't have a compatible .tar.gz to download, complain.
        # Alternatively, you could attempt to install from a separate provider,
        # build from source or something even more ambitious here.
        @warn("Your platform (\"$(Sys.MACHINE)\", parsed as \"$(triplet(platform_key_abi()))\") is not supported through BinaryBuilder.")
        return false
    end

    # If we have a download, and we are unsatisfied (or the version we're
    # trying to install is not itself installed) then load it up!
    if unsatisfied(cuarrays_products) || !isinstalled(dl_info...; prefix=cuarrays_prefix)
        # Download and install binaries
        install(dl_info...; prefix=cuarrays_prefix, force=true, verbose=verbose)
    end

    # Write out a deps.jl file that will contain mappings for our products
    write_deps_file(depsfile, products, verbose=verbose)

    open(depsfile, "a") do io
        println(io)
        println(io, "const use_binarybuilder = true")
    end

    return true
end

# assume that everything will be fine at run time
function do_fallback()
    @warn "Could not download CUDA dependencies; assuming they will be available at run time"

    open(depsfile, "w") do io
        println(io, "const use_binarybuilder = false")
        for p in products
            if p isa LibraryProduct
                # libraries are expected to be available on LD_LIBRARY_PATH
                println(io, "const $(variable_name(p)) = $(repr(first(p.libnames)))")
            end
        end
        println(io, """
            using Libdl
            function check_deps()
                Libdl.dlopen(libcufft)
                Libdl.dlopen(libcurand)
                Libdl.dlopen(libcublas)
                Libdl.dlopen(libcusolver)
                Libdl.dlopen(libcusparse)
                # CUDNN is an optional dependency
            end""")
    end

    return
end

main()
