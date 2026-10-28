/*
 * python/src/_ext.cpp -- CPython-Erweiterung simlev._ext (Etappe 7.3a)
 *
 * Ein Modul fuer alle gemeinsamen Kerne von R und Python. Jede Huelle steht in
 * ihrer eigenen Datei _ext_<kern>.cpp und liefert eine Methodentabelle; dieses
 * Modul fuegt sie zusammen. Die Kerne selbst sind Byte-fuer-Byte-Kopien der
 * kanonischen Quellen in core/ (src/core/, tools/core_sync.py).
 *
 * Ein Modul statt eines je Kern: ein Bau- und Ladeschritt, ein gemeinsamer Satz
 * Hilfen (_ext_common.h) und ein Wheel-Inhalt. Seit Etappe 9.1 auch die Huellen der
 * C-Bibliothek slc (_ext_slc*.c). Seit Etappe 9.6c ist die Erweiterung Pflicht (kein Schalter
 * SIMLEV_NO_EXT, keine reinen Python-Kerne mehr); die Huellen der entfallenen Kerne
 * (Bootstrap, DCC, MS-GARCH-Filter, rugarch, evd, imputeTS, truncnorm, R-Zufall) sind entfernt.
 */
#include "_ext_common.h"

#include <vector>

static PyMethodDef* const tables[] = {
    simlev_ext_research_methods,
    simlev_ext_withdrawal_methods,
    simlev_ext_engine_methods,
    simlev_ext_slc_methods,     /* C-Bibliothek slc (Etappe 9.1, _ext_slc.c) */
    simlev_ext_slc_linalg_methods,  /* 9.2: _ext_slc_linalg.c */
    simlev_ext_slc_opt_methods, /* 9.3: Optimierer der C-Bibliothek slc (_ext_slc_opt.c) */
    simlev_ext_slc_models_methods, /* 9.4: Modelle der C-Bibliothek slc (_ext_slc_models.c) */
};

static std::vector<PyMethodDef> all_methods;

static struct PyModuleDef ext_module = {
    PyModuleDef_HEAD_INIT, "_ext",
    "Gemeinsame Rechenkerne von R und Python fuer simlev (Kopien der Quellen aus core/).",
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
