using BinaryProvider
using CUDAnative

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1,
                          joinpath(dirname(dirname(pathof(CUDAnative))), "deps", "usr")))

# stuff we need to resolve
const products = if Sys.iswindows()
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
            LibraryProduct(prefix, "cufft$(width)_$(verstr)", :libcufft),
            LibraryProduct(prefix, "curand$(width)_$(verstr)", :libcurand),
            LibraryProduct(prefix, "cublas$(width)_$(verstr)", :libcublas),
            LibraryProduct(prefix, "cusolver$(width)_$(verstr)", :libcusolver),
            LibraryProduct(prefix, "cusparse$(width)_$(verstr)", :libcusparse),
        ]
    catch
        # just fail at runtime
        @error "On Windows, the CUDA toolkit version needs to be known at build time."
        [
            LibraryProduct(prefix, "cufft", :libcufft),
            LibraryProduct(prefix, "curand", :libcurand),
            LibraryProduct(prefix, "cublas", :libcublas),
            LibraryProduct(prefix, "cusolver", :libcusolver),
            LibraryProduct(prefix, "cusparse", :libcusparse),
        ]
    end
else
    [
        LibraryProduct(prefix, "libcufft", :libcufft),
        LibraryProduct(prefix, "libcurand", :libcurand),
        LibraryProduct(prefix, "libcublas", :libcublas),
        LibraryProduct(prefix, "libcusolver", :libcusolver),
        LibraryProduct(prefix, "libcusparse", :libcusparse),
    ]
end
unsatisfied() = any(!satisfied(p; verbose=verbose) for p in products)

const depsfile = joinpath(@__DIR__, "deps.jl")

function main()
    use_binarybuilder = parse(Bool, get(ENV, "JULIA_CUDA_USE_BINARYBUILDER", "true"))
    if use_binarybuilder
        if try_binarybuilder()
            @assert !unsatisfied()
            return
        end
    end

    do_fallback()

    return
end

function try_binarybuilder()
    if !CUDAnative.use_binarybuilder
        return false
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
    @warn "Could not download CUDA; assuming it will be available at run time"

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
            end""")
    end

    return
end

main()
