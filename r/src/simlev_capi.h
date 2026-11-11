// src/simlev_capi.h
// Anbindung der C++-Kerne an R's C-Schnittstelle (ersetzt seit 0.5.0 Rcpp).
//
// Aufbau: Die Kerne rechnen auf schlanken Sichten (Zeiger und Laenge: NumVec,
// IntVec, NumMat) bzw. bei der Engine direkt auf den R-Listen von
// sim_mem. Jede .Call-Huelle (extern "C", registriert in init.cpp) wandelt ihre
// Argumente in derselben Reihenfolge und auf dieselbe Weise um wie die frueher
// von Rcpp::compileAttributes() erzeugten Huellen und ruft den Kern ueber
// sl::call() auf:
//
//   * Zufallszahlen: sl::call beruehrt R's Zufallszustand nicht. Die frueheren Kerne mit
//     R's Zufallszahlen (bootstrap_core.cpp, ueber sl::call_rng mit GetRNGstate/PutRNGstate
//     wie Rcpp::RNGScope) und der Schalter rng von call_impl sind seit 1.0.0 entfallen.
//   * Fehler: sl::stop() wirft eine C++-Ausnahme. sl::call() faengt sie, raeumt
//     auf (C++-Objekte, gehaltene R-Objekte) und loest erst danach
//     den Fehler in R aus: stop(cond) mit cond = simpleError(Text, call = NULL),
//     wie Rcpp es mit seiner Bedingung tat. conditionMessage() ist damit der Text
//     von sl::stop() und conditionCall() NULL wie bei Rcpp::stop(); nur die
//     Klasse ist simpleError statt Rcpp::exception/C++Error.
//     Kein longjmp ueber C++-Objekte mit Destruktoren.
//   * Benutzerabbruch: sl::check_interrupt() prueft wie
//     Rcpp::checkUserInterrupt() ueber R_ToplevelExec und bricht nach dem
//     Aufraeumen mit Rf_onintr() ab.
//   * R-Aufrufe, die mit einem R-Fehler abbrechen koennen (Umwandlungen,
//     Vektoren mit vom Aufrufer bestimmter Laenge, Attribute), laufen unter
//     R_UnwindProtect (sl::rcall); der R-Fehler wird nach dem Aufraeumen mit
//     R_ContinueUnwind fortgesetzt.
//   * Neu angelegte R-Objekte, die ueber weitere Allokationen hinweg leben,
//     haelt sl::keep() bis zum Ende des .Call am Leben (eine mit
//     R_PreserveObject gesicherte Kette je Aufruf; kein PROTECT-Zaehlen).
//
// Umwandlungen wie Rcpp 1.0.12 (as<>, r_cast<>, wrap()), mit denselben
// Fehlermeldungen:
//   * Vektoren: gleiches Objekt, wenn der Typ passt (Aenderungen wirken dann
//     an Ort und Stelle), sonst Rf_coerceVector (atomare Typen). Die Umwandlungen
//     ueber as.list()/as.character(), Text-Skalare, Listen-Setzer und weitere
//     Hilfen ohne Aufrufer sind seit 1.6.3 entfallen.
//   * Skalare (as_double/as_int/as_bool): Laenge 1 noetig, dann Umwandlung
//     wie oben und erstes Element (NA_LOGICAL als bool ist true wie bei Rcpp).
//   * Ergebnisse: neue Vektoren mit 0 bzw. dem Fuellwert, Matrizen mit
//     ganzzahligem dim-Attribut, Skalare als neue Vektoren der Laenge 1,
//     benannte Listen mit names-Attribut.
//
// Die Kerne stehen in src/*_impl.h (gemeinsam mit Python und Julia, siehe
// simlev_core.h; kanonisch in core/). Diese Datei ist ihr R-Host: der
// Abschnitt "R als Host der gemeinsamen Kerne" am Ende bindet die Namen simlev_host::* und
// SIMLEV_* an genau die Aufrufe von sl::, die vor der Teilung im Kern standen (gleicher
// Maschinencode). Eine .Call-Huelle bindet erst diese Datei, dann den Kern ein.
#ifndef SIMLEV_CAPI_H
#define SIMLEV_CAPI_H

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Utils.h>

#include <csetjmp>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

// Aus R's Unterbrechungsbehandlung; bewusst ohne Rmath.h, dessen Makros (beta, sign,
// dt ...) Bezeichner in den Kernen umbenennen wuerden.
extern "C" {
void Rf_onintr(void);
}

namespace sl {

// ---------------------------------------------------------------------------
// Ausnahmen
// ---------------------------------------------------------------------------

// Fehler mit fertigem Meldungstext (Rcpp::stop bzw. Rcpp-Umwandlungsfehler)
class error : public std::exception {
 public:
  explicit error(const std::string& msg) : msg_(msg) {}
  const char* what() const noexcept override { return msg_.c_str(); }
 private:
  std::string msg_;
};

struct interrupted {};                 // Benutzerabbruch
struct unwind_jump {                  // R-Fehler waehrend eines geschuetzten R-Aufrufs
  SEXP token;
};

// Rcpp::stop(fmt, ...): Meldung im printf-Format (die Kerne nutzen nur %d und %s)
[[noreturn]] inline void stop(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
[[noreturn]] inline void stop(const char* fmt, ...) {
  va_list ap, ap2;
  va_start(ap, fmt);
  va_copy(ap2, ap);
  const int n = std::vsnprintf(nullptr, 0, fmt, ap2);
  va_end(ap2);
  std::string s(n > 0 ? (size_t) n : 0, '\0');
  if (n > 0) std::vsnprintf(&s[0], (size_t) n + 1, fmt, ap);
  va_end(ap);
  throw error(s);
}

// ---------------------------------------------------------------------------
// Gehaltene R-Objekte je .Call
// ---------------------------------------------------------------------------

struct frame {
  SEXP anchor;     // CONS-Zelle (R_PreserveObject), CDR = Kette der gehaltenen Objekte
  frame* prev;
};

inline frame*& current_frame() {
  static frame* f = nullptr;
  return f;
}

// Haelt x bis zum Ende des laufenden .Call (ausserhalb eines .Call: unveraendert)
inline SEXP keep(SEXP x) {
  frame* f = current_frame();
  if (f == nullptr || x == R_NilValue) return x;
  PROTECT(x);
  if (f->anchor == nullptr) {
    f->anchor = Rf_cons(R_NilValue, R_NilValue);
    R_PreserveObject(f->anchor);
  }
  SETCDR(f->anchor, Rf_cons(x, CDR(f->anchor)));
  UNPROTECT(1);
  return x;
}

// ---------------------------------------------------------------------------
// R-Aufrufe unter R_UnwindProtect
// ---------------------------------------------------------------------------

namespace detail {
struct jump_target { std::jmp_buf buf; };
inline void jump_back(void* data, Rboolean jump) {
  if (jump) std::longjmp(static_cast<jump_target*>(data)->buf, 1);
}
template <class F> SEXP invoke(void* data) { return (*static_cast<F*>(data))(); }
}  // namespace detail

// Fuehrt f() (liefert SEXP) aus; bricht f mit einem R-Fehler ab, wirft rcall
// unwind_jump, und sl::call() setzt den Fehler nach dem Aufraeumen fort.
// Das Ergebnis ist ungeschuetzt (sofort keep() oder einhaengen).
template <class F> SEXP rcall(F f) {
  detail::jump_target target;
  SEXP token = PROTECT(R_MakeUnwindCont());
  if (setjmp(target.buf)) {
    R_PreserveObject(token);
    UNPROTECT(1);
    throw unwind_jump{token};
  }
  SEXP res = R_UnwindProtect(&detail::invoke<F>, &f, &detail::jump_back, &target, token);
  UNPROTECT(1);
  return res;
}

// ---------------------------------------------------------------------------
// .Call-Rahmen
// ---------------------------------------------------------------------------

namespace detail {
inline char* message_buffer() {
  static char buf[8192];
  return buf;
}
inline SEXP& pending_token() {
  static SEXP token = nullptr;
  return token;
}
inline void set_message(const char* msg) {
  char* buf = message_buffer();
  std::strncpy(buf, msg, 8191);
  buf[8191] = '\0';
}

// 0 = Erfolg, 1 = Abbruch, 2 = Fehler (Text im Puffer), 3 = R-Fehler fortsetzen
template <class F> int run(F& body, SEXP& res) {
  try {
    res = body();
    return 0;
  } catch (const unwind_jump& u) {
    pending_token() = u.token;
    return 3;
  } catch (const interrupted&) {
    return 1;
  } catch (const std::exception& e) {
    set_message(e.what());
    return 2;
  } catch (...) {
    set_message("c++ exception (unknown reason)");
    return 2;
  }
}

// Nach dem Aufraeumen: keine C++-Objekte mit Destruktoren mehr im Spiel
inline void raise(int status) {
  if (status == 1) {
    Rf_onintr();
    return;
  }
  if (status == 3) {
    SEXP token = pending_token();
    pending_token() = nullptr;
    R_ReleaseObject(token);
    R_ContinueUnwind(token);
  }
  // Wie Rcpp: Bedingung mit dem Text und ohne Aufruf (call = NULL), ausgeloest
  // mit stop(cond); die Klasse ist simpleError statt Rcpp::exception/C++Error.
  SEXP cond = PROTECT(Rf_allocVector(VECSXP, 2));
  SET_VECTOR_ELT(cond, 0, Rf_mkString(message_buffer()));
  SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
  SET_STRING_ELT(names, 0, Rf_mkChar("message"));
  SET_STRING_ELT(names, 1, Rf_mkChar("call"));
  Rf_setAttrib(cond, R_NamesSymbol, names);
  SEXP klass = PROTECT(Rf_allocVector(STRSXP, 3));
  SET_STRING_ELT(klass, 0, Rf_mkChar("simpleError"));
  SET_STRING_ELT(klass, 1, Rf_mkChar("error"));
  SET_STRING_ELT(klass, 2, Rf_mkChar("condition"));
  Rf_setAttrib(cond, R_ClassSymbol, klass);
  SEXP expr = PROTECT(Rf_lang2(Rf_install("stop"), cond));
  Rf_eval(expr, R_BaseEnv);
  UNPROTECT(4);
  Rf_error("%s", message_buffer());   // nicht erreicht
}
}  // namespace detail

// Rahmen jeder .Call-Huelle: Kern ausfuehren (Umwandlung der Argumente
// eingeschlossen), gehaltene Objekte freigeben, dann Ergebnis zurueckgeben oder den
// Fehler in R ausloesen. Kein Kern liest oder schreibt .Random.seed.
template <class F> SEXP call_impl(F& body) {
  frame f;
  f.anchor = nullptr;
  f.prev = current_frame();
  current_frame() = &f;
  SEXP res = R_NilValue;
  const int status = detail::run(body, res);
  if (status != 0) res = R_NilValue;
  PROTECT(res);
  current_frame() = f.prev;
  if (f.anchor != nullptr) R_ReleaseObject(f.anchor);
  UNPROTECT(1);
  if (status != 0) detail::raise(status);
  return res;
}
template <class F> SEXP call(F&& body) { return call_impl(body); }

// Rcpp::checkUserInterrupt()
namespace detail {
inline void check_interrupt_fn(void*) { R_CheckUserInterrupt(); }
}
inline void check_interrupt() {
  if (R_ToplevelExec(&detail::check_interrupt_fn, nullptr) == FALSE) throw interrupted();
}


// ---------------------------------------------------------------------------
// Umwandlungen (wie Rcpp r_cast<> / as<>)
// ---------------------------------------------------------------------------

inline const char* type_name(SEXP x) { return Rf_type2char((SEXPTYPE) TYPEOF(x)); }

// r_cast<to> fuer atomare Zieltypen: gleiches Objekt oder Rf_coerceVector
inline SEXP coerce(SEXP x, SEXPTYPE to) {
  if (TYPEOF(x) == (int) to) return x;
  switch (TYPEOF(x)) {
  case REALSXP: case RAWSXP: case LGLSXP: case CPLXSXP: case INTSXP:
    return rcall([&]() { return Rf_coerceVector(x, to); });
  default:
    stop("Not compatible with requested type: [type=%s; target=%s].", type_name(x), Rf_type2char(to));
  }
}

inline void check_scalar(SEXP x) {
  if (Rf_length(x) != 1) stop("Expecting a single value: [extent=%i].", Rf_length(x));
}

// as<double>, as<int>, as<bool>
inline double as_double(SEXP x) {
  check_scalar(x);
  return REAL(coerce(x, REALSXP))[0];
}
inline int as_int(SEXP x) {
  check_scalar(x);
  return INTEGER(coerce(x, INTSXP))[0];
}
inline bool as_bool(SEXP x) {
  check_scalar(x);
  return static_cast<bool>(LOGICAL(coerce(x, LGLSXP))[0]);
}

// ---------------------------------------------------------------------------
// Sichten auf Vektoren und Matrizen
// ---------------------------------------------------------------------------

template <class T> struct Vec {
  SEXP sexp;
  T* ptr;
  R_xlen_t len;
  T& operator[](R_xlen_t i) const { return ptr[i]; }
  R_xlen_t size() const { return len; }
  T* begin() const { return ptr; }
  T* end() const { return ptr + len; }
};
typedef Vec<double> NumVec;
typedef Vec<int> IntVec;

struct NumMat {
  SEXP sexp;
  double* ptr;
  int nr, nc;
  double& operator()(R_xlen_t i, R_xlen_t j) const { return ptr[i + (R_xlen_t) nr * j]; }
  int nrow() const { return nr; }
  int ncol() const { return nc; }
  double* begin() const { return ptr; }
  double* end() const { return ptr + (R_xlen_t) nr * nc; }
};

// NumericVector / IntegerVector / LogicalVector aus einem Argument
inline NumVec num_vec(SEXP x) {
  SEXP y = coerce(x, REALSXP);
  if (y != x) keep(y);
  NumVec v = {y, REAL(y), Rf_xlength(y)};
  return v;
}
inline IntVec int_vec(SEXP x) {
  SEXP y = coerce(x, INTSXP);
  if (y != x) keep(y);
  IntVec v = {y, INTEGER(y), Rf_xlength(y)};
  return v;
}

// NumericMatrix aus einem Argument (erst Umwandlung, dann dim-Pruefung wie Rcpp)
inline NumMat num_mat(SEXP x) {
  SEXP y = coerce(x, REALSXP);
  if (y != x) keep(y);
  if (!Rf_isMatrix(y)) throw error("Not a matrix.");
  const int* d = INTEGER(Rf_getAttrib(y, R_DimSymbol));
  NumMat m = {y, REAL(y), d[0], d[1]};
  return m;
}

// Neue Vektoren (Laenge vom Aufrufer, daher unter rcall)
inline SEXP alloc(SEXPTYPE type, R_xlen_t n) {
  return keep(rcall([&]() { return Rf_allocVector(type, n); }));
}
inline NumVec new_num(R_xlen_t n, double fill = 0.0) {
  SEXP x = alloc(REALSXP, n);
  NumVec v = {x, REAL(x), Rf_xlength(x)};
  for (R_xlen_t i = 0; i < v.len; i++) v.ptr[i] = fill;
  return v;
}
template <class It> NumVec num_copy(It first, It last) {
  NumVec v = new_num((R_xlen_t) (last - first));
  for (R_xlen_t i = 0; first != last; ++first, ++i) v.ptr[i] = *first;
  return v;
}

// NumericMatrix(nr, nc): Laenge nr * nc, mit 0 gefuellt, dim = c(nr, nc)
inline NumMat new_mat(int nr, int nc) {
  SEXP x = alloc(REALSXP, (R_xlen_t) nr * (R_xlen_t) nc);
  double* p = REAL(x);
  for (R_xlen_t i = 0, n = Rf_xlength(x); i < n; i++) p[i] = 0.0;
  rcall([&]() {
    SEXP dim = PROTECT(Rf_allocVector(INTSXP, 2));
    INTEGER(dim)[0] = nr;
    INTEGER(dim)[1] = nc;
    Rf_setAttrib(x, R_DimSymbol, dim);
    UNPROTECT(1);
    return R_NilValue;
  });
  NumMat m = {x, p, nr, nc};
  return m;
}

// Attribut ueber ein Symbol setzen (names, class; value gehalten), Zeichen und Text-Skalar anlegen: unter rcall
// (seit 1.6.4, K43 T1-B2; bis dahin direkt, ein Allokationsfehler sprang per longjmp ueber die C++-Rahmen)
inline void set_attr_sym(SEXP x, SEXP sym, SEXP value) {
  rcall([&]() {
    Rf_setAttrib(x, sym, value);
    return R_NilValue;
  });
}
inline SEXP mkchar(const char* s) { return rcall([&]() { return Rf_mkChar(s); }); }
inline SEXP mkstring(const char* s) { return keep(rcall([&]() { return Rf_mkString(s); })); }

// Attribut setzen (x.attr(name) = value)
inline void set_attr(SEXP x, const char* name, SEXP value) {
  PROTECT(value);
  keep(value);
  UNPROTECT(1);
  rcall([&]() {
    Rf_setAttrib(x, Rf_install(name), value);
    return R_NilValue;
  });
}

// ---------------------------------------------------------------------------
// wrap(): Skalare und Container als neue R-Objekte
// ---------------------------------------------------------------------------

// seit 1.6.4 (K43 T1-B2) ueber sl::alloc bzw. rcall (gehalten bis zum Ende des .Call)
inline SEXP wrap(double v) { SEXP x = alloc(REALSXP, 1); REAL(x)[0] = v; return x; }
inline SEXP wrap(int v) { SEXP x = alloc(INTSXP, 1); INTEGER(x)[0] = v; return x; }
inline SEXP wrap(bool v) { SEXP x = alloc(LGLSXP, 1); LOGICAL(x)[0] = v ? 1 : 0; return x; }
inline SEXP wrap(const char* s) { return mkstring(s); }
inline SEXP wrap(SEXP x) { return x; }
template <class T> SEXP wrap(const Vec<T>& v) { return v.sexp; }
inline SEXP wrap(const NumMat& m) { return m.sexp; }
inline SEXP wrap(const std::vector<double>& v) {
  SEXP x = alloc(REALSXP, (R_xlen_t) v.size());
  for (size_t i = 0; i < v.size(); i++) REAL(x)[i] = v[i];
  return x;
}
inline SEXP wrap(const std::vector<int>& v) {
  SEXP x = alloc(INTSXP, (R_xlen_t) v.size());
  for (size_t i = 0; i < v.size(); i++) INTEGER(x)[i] = v[i];
  return x;
}

// List::create(Named(n1) = v1, Named(n2) = v2, ...): named_list("n1", v1, "n2", v2, ...)
namespace detail {
inline void fill_list(SEXP, SEXP, R_xlen_t) {}
template <class T, class... Rest>
void fill_list(SEXP res, SEXP names, R_xlen_t i, const char* name, const T& value, const Rest&... rest) {
  SET_VECTOR_ELT(res, i, wrap(value));
  SET_STRING_ELT(names, i, mkchar(name));
  fill_list(res, names, i + 1, rest...);
}
}  // namespace detail

template <class... Args> SEXP named_list(const Args&... args) {
  const R_xlen_t n = (R_xlen_t) (sizeof...(Args) / 2);
  SEXP res = alloc(VECSXP, n);   // seit 1.6.4 (K43 T1-B2) Liste, Namen und Attribut unter rcall
  SEXP names = alloc(STRSXP, n);
  detail::fill_list(res, names, 0, args...);
  set_attr_sym(res, R_NamesSymbol, names);
  return res;
}

// ---------------------------------------------------------------------------
// Listen ueber Namen (wie Rcpp's generic_name_proxy)
// ---------------------------------------------------------------------------

// Position von name oder -1; -2, wenn die Liste keine Namen hat
inline R_xlen_t find(SEXP list, const char* name) {
  SEXP names = Rf_getAttrib(list, R_NamesSymbol);
  if (Rf_isNull(names)) return -2;
  const R_xlen_t n = Rf_xlength(list);
  for (R_xlen_t i = 0; i < n; i++)
    if (std::strcmp(name, CHAR(STRING_ELT(names, i))) == 0) return i;
  return -1;
}

}  // namespace sl

// ---------------------------------------------------------------------------
// R als Host der gemeinsamen Kerne (Schnittstelle in simlev_core.h)
// ---------------------------------------------------------------------------
//
// Die Kerne in src/*_impl.h (Kopien aus core/) sind gewoehnliche statische Funktionen ueber den Typen
// simlev_host::NumVec/IntVec/NumMat und den Makros SIMLEV_*. Fuer R stehen dort
// genau die Typen und Aufrufe, die frueher direkt im Kern standen; der Compiler
// uebersetzt die Kerne daher in der .Call-Huelle wie vor der Teilung (gleicher
// Maschinencode, geprueft per Disassemblierung). Python bindet dieselben Namen an
// seine Sichten (python/src/_ext_common.h).
namespace simlev_host {
typedef sl::NumVec NumVec;
typedef sl::IntVec IntVec;
typedef sl::NumMat NumMat;
using namespace sl;
}  // namespace simlev_host

#define SIMLEV_NA NA_REAL                                       // R's NA_real_
#define SIMLEV_FAIL sl::stop                                    // Fehler: stop() mit dem Text
#define SIMLEV_CHECK_INTERRUPT() sl::check_interrupt()          // Benutzerabbruch
#define SIMLEV_NUM(...) sl::new_num(__VA_ARGS__)                // Zahlenvektor (0 bzw. Fuellwert)
#define SIMLEV_MATRIX(...) sl::new_mat(__VA_ARGS__)             // Matrix (0)
#define SIMLEV_COPY(...) sl::num_copy(__VA_ARGS__).sexp         // Ergebnis: Kopie eines Bereichs
#define SIMLEV_COPY_VEC(...) sl::num_copy(__VA_ARGS__)          // Kopie eines Bereichs als Vektor
#define SIMLEV_SET_FLAG(v, name, flag) sl::set_attr((v).sexp, name, sl::wrap(flag))
#define SIMLEV_DONE(v) (v).sexp                                 // Ergebnis: Vektor
#define SIMLEV_LIST(...) sl::named_list(__VA_ARGS__)            // Ergebnis: benannte Liste

#endif
