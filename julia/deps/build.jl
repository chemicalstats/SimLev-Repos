# julia/deps/build.jl – baut die C-Bibliothek slc (SimLev core, Etappe 9.1) mit dem System-Compiler.
#
# Läuft bei Pkg.build("SimLev") bzw. Pkg.build() im Projekt und bei Pkg.add. Quellen sind die
# Kopien deps/core/slc*.{c,h} der kanonischen Dateien in core/ (tools/core_sync.py). Compiler aus
# ENV["SIMLEV_CC"] (darf Optionen enthalten), sonst cc, gcc, clang. Gleiche Flags wie R
# (r/src/Makevars) und Python (python/setup.py): -O2 -std=c99 -ffp-contract=off -fno-fast-math
# (Entwurf C.2/C.3). Ergebnis: deps/usr/lib/libslc.<dlext> und deps/deps.jl (const LIBSLC).
# Geprüft nur unter Linux x86-64; unter macOS und Windows ist ein C-Compiler nötig (R5).
const dlext = Base.Libc.Libdl.dlext   # ohne Paketabhängigkeit (Libdl ist keine Abhängigkeit von SimLev)

const DEPS = @__DIR__
const SRC = joinpath(DEPS, "core")
const LIBDIR = joinpath(DEPS, "usr", "lib")
const FLAGS = ["-std=c99", "-O2", "-fPIC", "-ffp-contract=off", "-fno-fast-math"]

function find_cc()
    cc = strip(get(ENV, "SIMLEV_CC", ""))
    isempty(cc) || return Base.shell_split(cc)
    for c in ("cc", "gcc", "clang")
        Sys.which(c) === nothing || return [c]
    end
    error("SimLev: kein C-Compiler gefunden (ENV[\"SIMLEV_CC\"] setzen oder cc/gcc/clang installieren)")
end

function build()
    cc = find_cc()
    srcs = sort([joinpath(SRC, f) for f in readdir(SRC) if startswith(f, "slc") && endswith(f, ".c")])
    isempty(srcs) && error("SimLev: keine Quellen in $SRC (tools/core_sync.py --write ausführen)")
    mkpath(LIBDIR)
    lib = joinpath(LIBDIR, "libslc." * dlext)
    tmp = lib * ".neu"
    cmd = Cmd([cc..., FLAGS..., "-shared", srcs..., "-lm", "-o", tmp])
    @info "SimLev: baue die C-Bibliothek slc" cmd
    run(cmd)
    mv(tmp, lib; force = true)
    open(joinpath(DEPS, "deps.jl"), "w") do io
        println(io, "# erzeugt von deps/build.jl – nicht von Hand ändern")
        println(io, "const LIBSLC = ", repr(lib))
    end
    @info "SimLev: C-Bibliothek gebaut" lib
end

build()
