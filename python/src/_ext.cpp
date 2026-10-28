/*
 * python/src/_ext.cpp -- CPython-Erweiterung simlev._ext (Etappe 7.3a)
 *
 * Ein Modul fuer alle gemeinsamen Kerne von R und Python. Jede Huelle steht in
 * ihrer eigenen Datei _ext_<kern>.cpp und liefert eine Methodentabelle; dieses
 * Modul fuegt sie zusammen. Die Kerne selbst sind Byte-fuer-Byte-Kopien der
 * kanonischen Quellen in r/src/ (Liste in tests/test_shared_c.py).
 *
 * Ein Modul statt eines je Kern: ein Bau- und Ladeschritt, ein gemeinsamer Satz
 * Hilfen (_ext_common.h), eine Stelle fuer den Schalter SIMLEV_NO_EXT
 * (simlev._r.env.ext()) und ein Wheel-Inhalt. Seit Etappe 7.3b auch die Kerne mit
 * Zufallszahlen (Bootstrap, truncnorm) mit der C-Nachbildung von R's RNG (_rng_r.c).
 */
#include "_ext_common.h"

#include <vector>

static PyMethodDef* const tables[] = {
    simlev_ext_ms_garch_methods,
    simlev_ext_research_methods,
    simlev_ext_withdrawal_methods,
    simlev_ext_rugarch_methods,
    simlev_ext_dependence_methods,
    simlev_ext_evd_methods,
    simlev_ext_imputets_methods,
    simlev_ext_engine_methods,
    simlev_ext_bootstrap_methods,
    simlev_ext_truncnorm_methods,
    simlev_ext_rng_methods,
};

static std::vector<PyMethodDef> all_methods;

static struct PyModuleDef ext_module = {
    PyModuleDef_HEAD_INIT, "_ext",
    "Gemeinsame Rechenkerne von R und Python fuer simlev (Kopien der Quellen aus r/src/).",
    -1, nullptr, nullptr, nullptr, nullptr, nullptr
};

PyMODINIT_FUNC PyInit__ext(void)
{
    if (all_methods.empty()) {
        for (PyMethodDef* t : tables)
            for (PyMethodDef* m = t; m->ml_name != nullptr; ++m) all_methods.push_back(*m);
        all_methods.push_back(PyMethodDef{nullptr, nullptr, 0, nullptr});
    }
    ext_module.m_methods = all_methods.data();
    return PyModule_Create(&ext_module);
}
