# julia/deps/build.jl – baut die Bibliothek slc (SimLev core) und die C-ABI-Hülle der
# geteilten Kerne mit dem System-Compiler (C++) in eine Bibliothek.
#
# Läuft bei Pkg.build("SimLev") bzw. Pkg.build() im Projekt und bei Pkg.add. Quellen sind die
# Kopien in deps/core/ der kanonischen Dateien in core/ (core/sync.py): slc*.{cpp,h}, die
# geteilten Kerne simlev_core.h und *_core_impl.h und ihre C-ABI-Hülle simlev_cabi.cpp; seit 1.6.0
# alles C++ (bis 1.5.2 slc in C99). Compiler aus ENV["SIMLEV_CXX"] (darf Optionen enthalten), sonst
# c++, g++, clang++. Gleiche Gleitkomma-Schalter für alle Dateien wie R (r/src/Makevars) und
# Python (python/setup.py): -std=gnu++17 -O2 -ffp-contract=off -fno-fast-math mit
# SIMLEV_FP_CONTRACT_BY_FLAG (core/simlev_core.h: kein Zusammenziehen zu fma, kein -ffast-math);
# außer unter Windows mit Threads (-DSLC_THREADS -pthread) für die parallelen Starts des
# MS-GARCH-Fits, beim Binden ebenfalls -pthread. Die öffentliche Schnittstelle (slc*.h,
# simlev_cabi.cpp) hat C-Bindung (extern "C"); die ccall-Namen sind unverändert.
# Ergebnis: deps/usr/lib/libslc.<dlext> und deps/deps.jl (const LIBSLC).
# Geprüft nur unter Linux x86-64; unter macOS und Windows ist ein C++-Compiler nötig.
const dlext = Base.Libc.Libdl.dlext   # ohne Paketabhängigkeit (Libdl ist keine Abhängigkeit von SimLev)

const DEPS = @__DIR__
const SRC = joinpath(DEPS, "core")
const LIBDIR = joinpath(DEPS, "usr", "lib")
# alle Quellen (Bibliothek slc und C-ABI-Hülle der geteilten Kerne), Schalter wie python/setup.py
const CXXFLAGS = ["-std=gnu++17", "-O2", "-fPIC", "-ffp-contract=off", "-fno-fast-math",
                  "-DSIMLEV_FP_CONTRACT_BY_FLAG=1"]
const THREAD_FLAGS = Sys.iswindows() ? String[] : ["-DSLC_THREADS", "-pthread"]
const CABI = "simlev_cabi.cpp"

function find_compiler(var, names, what)
    cc = strip(get(ENV, var, ""))
    isempty(cc) || return Base.shell_split(cc)
    for c in names
        Sys.which(c) === nothing || return [c]
    end
    error("SimLev: kein $what gefunden (ENV[\"$var\"] setzen oder $(join(names, "/")) installieren)")
end
find_cxx() = find_compiler("SIMLEV_CXX", ("c++", "g++", "clang++"), "C++-Compiler")

function build()
    isempty(strip(get(ENV, "SIMLEV_CC", ""))) ||
        @warn "SimLev: SIMLEV_CC wird seit 1.6.0 nicht mehr gelesen (alle Quellen C++); den Compiler wählt SIMLEV_CXX"
    cxx = find_cxx()
    srcs = sort([joinpath(SRC, f) for f in readdir(SRC) if startswith(f, "slc") && endswith(f, ".cpp")])
    isempty(srcs) && error("SimLev: keine Quellen in $SRC (core/sync.py --write ausführen)")
    isfile(joinpath(SRC, CABI)) || error("SimLev: $CABI fehlt in $SRC (core/sync.py --write ausführen)")
    push!(srcs, joinpath(SRC, CABI))
    mkpath(LIBDIR)
    lib = joinpath(LIBDIR, "libslc." * dlext)
    tmp = lib * ".neu"
    objs = String[]
    mktempdir() do dir
        @info "SimLev: übersetze $(length(srcs)) Quellen" cmd = Cmd([cxx..., CXXFLAGS..., THREAD_FLAGS..., "-c"])
        for s in srcs
            o = joinpath(dir, splitext(basename(s))[1] * ".o")
            run(Cmd([cxx..., CXXFLAGS..., THREAD_FLAGS..., "-c", s, "-o", o]))
            push!(objs, o)
        end
        cmd = Cmd([cxx..., "-shared", objs..., THREAD_FLAGS..., "-lm", "-o", tmp])
        @info "SimLev: baue die Bibliothek slc mit den geteilten Kernen" cmd
        run(cmd)
    end
    mv(tmp, lib; force = true)
    open(joinpath(DEPS, "deps.jl"), "w") do io
        println(io, "# erzeugt von deps/build.jl – nicht von Hand ändern")
        println(io, "const LIBSLC = ", repr(lib))
    end
    @info "SimLev: Bibliothek gebaut" lib
end

build()
