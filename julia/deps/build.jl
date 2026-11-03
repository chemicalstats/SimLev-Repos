# julia/deps/build.jl – baut die C-Bibliothek slc (SimLev core, Etappe 9.1) und die C-ABI-Hülle der
# geteilten C++-Kerne (N7) mit dem System-Compiler in eine Bibliothek.
#
# Läuft bei Pkg.build("SimLev") bzw. Pkg.build() im Projekt und bei Pkg.add. Quellen sind die
# Kopien in deps/core/ der kanonischen Dateien in core/ (core/sync.py): slc*.{c,h}, die
# geteilten Kerne simlev_core.h und *_core_impl.h und ihre C-ABI-Hülle simlev_cabi.cpp.
# C-Compiler aus ENV["SIMLEV_CC"], C++-Compiler aus ENV["SIMLEV_CXX"] (dürfen Optionen enthalten),
# sonst cc, gcc, clang bzw. c++, g++, clang++. Gleiche Gleitkomma-Schalter wie R (r/src/Makevars)
# und Python (python/setup.py): C -O2 -std=c99 -ffp-contract=off -fno-fast-math (Entwurf C.2/C.3);
# C++ wie Python -O2 -std=gnu++17 -ffp-contract=off -fno-fast-math mit SIMLEV_FP_CONTRACT_BY_FLAG
# (core/simlev_core.h: kein Zusammenziehen zu fma, kein -ffast-math). Gebunden mit dem
# C++-Compiler. Ergebnis: deps/usr/lib/libslc.<dlext> und deps/deps.jl (const LIBSLC).
# Geprüft nur unter Linux x86-64; unter macOS und Windows sind C- und C++-Compiler nötig (R5).
# N6: außer unter Windows mit Threads (-DSLC_THREADS -pthread) für die parallelen Starts des MS-GARCH-Fits
# (wie r/src/Makevars und python/setup.py); beim Binden ebenfalls -pthread.
const dlext = Base.Libc.Libdl.dlext   # ohne Paketabhängigkeit (Libdl ist keine Abhängigkeit von SimLev)

const DEPS = @__DIR__
const SRC = joinpath(DEPS, "core")
const LIBDIR = joinpath(DEPS, "usr", "lib")
const FLAGS = ["-std=c99", "-O2", "-fPIC", "-ffp-contract=off", "-fno-fast-math"]
const THREAD_FLAGS = Sys.iswindows() ? String[] : ["-DSLC_THREADS", "-pthread"]   # N6
# N7: C-ABI-Hülle der geteilten C++-Kerne, Schalter wie python/setup.py
const CXXFLAGS = ["-std=gnu++17", "-O2", "-fPIC", "-ffp-contract=off", "-fno-fast-math",
                  "-DSIMLEV_FP_CONTRACT_BY_FLAG=1"]
const CABI = "simlev_cabi.cpp"

function find_compiler(var, names, what)
    cc = strip(get(ENV, var, ""))
    isempty(cc) || return Base.shell_split(cc)
    for c in names
        Sys.which(c) === nothing || return [c]
    end
    error("SimLev: kein $what gefunden (ENV[\"$var\"] setzen oder $(join(names, "/")) installieren)")
end
find_cc() = find_compiler("SIMLEV_CC", ("cc", "gcc", "clang"), "C-Compiler")
find_cxx() = find_compiler("SIMLEV_CXX", ("c++", "g++", "clang++"), "C++-Compiler")

function build()
    cc = find_cc()
    cxx = find_cxx()
    srcs = sort([joinpath(SRC, f) for f in readdir(SRC) if startswith(f, "slc") && endswith(f, ".c")])
    isempty(srcs) && error("SimLev: keine Quellen in $SRC (core/sync.py --write ausführen)")
    isfile(joinpath(SRC, CABI)) || error("SimLev: $CABI fehlt in $SRC (core/sync.py --write ausführen)")
    mkpath(LIBDIR)
    lib = joinpath(LIBDIR, "libslc." * dlext)
    tmp = lib * ".neu"
    objs = String[]
    mktempdir() do dir
        for s in srcs
            o = joinpath(dir, splitext(basename(s))[1] * ".o")
            run(Cmd([cc..., FLAGS..., THREAD_FLAGS..., "-c", s, "-o", o]))
            push!(objs, o)
        end
        o = joinpath(dir, "simlev_cabi.o")
        cmd = Cmd([cxx..., CXXFLAGS..., "-c", joinpath(SRC, CABI), "-o", o])
        @info "SimLev: übersetze die C-ABI-Hülle der geteilten Kerne" cmd
        run(cmd)
        push!(objs, o)
        cmd = Cmd([cxx..., "-shared", objs..., THREAD_FLAGS..., "-lm", "-o", tmp])
        @info "SimLev: baue die C-Bibliothek slc mit den geteilten Kernen" cmd
        run(cmd)
    end
    mv(tmp, lib; force = true)
    open(joinpath(DEPS, "deps.jl"), "w") do io
        println(io, "# erzeugt von deps/build.jl – nicht von Hand ändern")
        println(io, "const LIBSLC = ", repr(lib))
    end
    @info "SimLev: C-Bibliothek gebaut" lib
end

build()
