using BinaryProvider
using CUDAnative

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
@assert isempty([a for a in ARGS if a != "--verbose"])

# online sources we can use
const bin_prefix = "https://github.com/JuliaGPU/CUDABuilder/releases/download/v0.1.3"
const resources = Dict(
    v"9.0" =>
        Dict(
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-CUDA9.0-0.1.3.x86_64-linux-gnu.tar.gz", "b0f76625209b033462c7f8b7f3117140c2191f8d169149f507476a7410bfd19d"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-CUDA9.0-0.1.3.x86_64-w64-mingw32.tar.gz", "eeb1c6ae4a4973feb8814bf175daf06b5250addc1979c492358f9007741c6bd6"),
        ),
    v"9.2" =>
        Dict(
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-CUDA9.2-0.1.3.x86_64-linux-gnu.tar.gz", "b688f2bdbf0fc46bca74d9d0f10cc3f3092881cff84193912fdf887a53d85cc5"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-CUDA9.2-0.1.3.x86_64-w64-mingw32.tar.gz", "c2082d230835a31490c4253aa390cc50f443bec996acc84f2735f59b40d82787"),
        ),
    v"10.0" =>
        Dict(
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-CUDA10.0-0.1.3.x86_64-linux-gnu.tar.gz", "96d38f86f8d0b2a7d106cccdcebad0cae10958bf0ea7e3f0f5fd426488f25a2c"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-CUDA10.0-0.1.3.x86_64-w64-mingw32.tar.gz", "c62b3398fa8ae659c03548d2cad6ad82b3b5f6e48357ea662693bc90a75bddf0"),
            MacOS(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-CUDA10.0-0.1.3.x86_64-apple-darwin14.tar.gz", "8869fa21387e2703ba57c9749f5683ddc790e7b7145735b053b0828e1ff18ab4"),
        ),
    v"10.1" =>
        Dict(
            Linux(:x86_64, libc=:glibc) => ("$bin_prefix/CUDNN.v7.6.5-CUDA10.1-0.1.3.x86_64-linux-gnu.tar.gz", "09f41c36d61141fa7cc126e157d0eb189493fd76ea528945859ed45f2d00b2b7"),
            Windows(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-CUDA10.1-0.1.3.x86_64-w64-mingw32.tar.gz", "d092416272e2f2078c064cc0624d7ced72fc29fc34f58c3af14693ab3dd6d8a6"),
            MacOS(:x86_64) => ("$bin_prefix/CUDNN.v7.6.5-CUDA10.1-0.1.3.x86_64-apple-darwin14.tar.gz", "9ba01c82b9f3d108cb021b5e6a86560d6ac47701295c6be29479a71a35a61a87"),
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
