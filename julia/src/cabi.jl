# CAbi – Julia als dritter Host der geteilten C++-Kerne (eine Bibliothek für alle Sprachen, seit 1.2.0).
#
# Die Kerne core/research_core_impl.h, withdrawal_core_impl.h, tariff_core_impl.h und engine_core_impl.h
# rechnen in R, Python und Julia aus derselben Quelle. Julia ruft sie über die C-ABI-Hülle
# core/simlev_cabi.cpp (Kopie deps/core/, gebaut von deps/build.jl in libslc, const LIBSLC) per ccall auf:
# nur Zeiger, Längen und Skalare; Fehler als Rückgabecode mit Text (simlev_c_last_error, je Thread; ohne
# yield zwischen den beiden Aufrufen). Die früheren Julia-Ports sind entfallen. Diese Datei enthält
# nur die gemeinsamen Hilfen; die Aufrufe stehen bei den bisherigen Funktionen (sim_engine.jl,
# optimize_core.jl, dependence_core.jl, signals_core.jl, withdrawal_core.jl).
module CAbi

using ..SLib: LIBSLC

const OK = Cint(0)
const ERROR = Cint(1)
const INTERRUPT = Cint(2)

"Text des letzten Fehlers der Hülle (dieser Thread)."
last_error() = unsafe_string(ccall((:simlev_c_last_error, LIBSLC), Cstring, ()))

"""
    check(rc[, err])

Rückgabecode der Hülle auswerten: 0 nichts; 1 Fehler des Kerns (`SIMLEV_FAIL`): `err(text)` (Voreinstellung
`error(text)`, wie die früheren Ports); 2 Benutzerabbruch: `InterruptException`; sonst Fehler der Hülle.
"""
@inline function check(rc::Cint, err = error)
    rc == OK && return nothing
    _fail(rc, err)
end
@noinline function _fail(rc::Cint, err)
    msg = last_error()
    rc == ERROR && throw_err(err, msg)
    rc == INTERRUPT && throw(InterruptException())
    error("SimLev: C-Hülle der geteilten Kerne (Code $rc): $msg")
end
throw_err(err::Function, msg) = (err(msg); error(msg))
throw_err(::Type{T}, msg) where {T<:Exception} = throw(T(msg))

end # module
