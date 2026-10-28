# Zusatzfaelle der Gleichlaufpruefung (Etappe 9.3, Entwurf C.8/C.9): Optimierer der C-Bibliothek
# slc. Modul "slc_opt": .sl_optim in R, simlev._lib.optim in Python, SimLev.SLib.optim in Julia,
# jeweils mit derselben C-Zielfunktion (.sl_opt_testfn) ueber die Rueckfrage an den Host, dazu der
# direkte C-Weg (sl_minimize), der numerische Gradient und die Fehlertexte. Mit trace = TRUE
# werden alle Auswertungspunkte und Funktionswerte verglichen (Hex-Vergleich der Iterationsfolge).
#
# Aufruf aus der Repo-Wurzel (tools/gleichlauf/run.sh setzt SIMLEV_MODULE_DIR):
#   SIMLEV_MODULE_DIR=<ordner> R_LIBS=<R-Bibliothek> Rscript tools/gleichlauf/extra_cases_opt.R
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
source("golden/modules/ref_tools.R")
ref_init("slc_opt")

P <- "import math\nimport numpy as np\nimport simlev._lib as L\n"
J <- "const L = SL.SLib\n"
cs <- function(id, r, py, jl, inputs = list())
  ref_case(id, r = paste0("sl <- asNamespace('SimLev')\n", r), py = paste0(P, py), jl = paste0(J, jl), inputs = inputs)

# Zahlen und Vektoren in den drei Sprachen (17 Stellen, damit alle dieselben double-Werte sehen)
num <- function(v, lang) vapply(v, function(x) {
  if (is.infinite(x)) return(if (lang == "py") (if (x > 0) "math.inf" else "-math.inf") else (if (x > 0) "Inf" else "-Inf"))
  s <- sprintf("%.17g", x)
  if (lang != "r" && !grepl("[.eE]", s)) s <- paste0(s, ".0")
  s
}, "")
vr <- function(v) paste0("c(", paste(num(v, "r"), collapse = ", "), ")")
vp <- function(v) paste0("np.array([", paste(num(v, "py"), collapse = ", "), "])")
vj <- function(v) paste0("[", paste(num(v, "jl"), collapse = ", "), "]")
# Steuerwerte: benannte Liste (Zahlen oder Vektoren)
cr <- function(ct) if (!length(ct)) "list()" else paste0("list(", paste(sprintf("%s = %s", names(ct), vapply(ct, function(v) if (is.logical(v)) as.character(v) else if (length(v) > 1) vr(v) else num(v, "r"), "")), collapse = ", "), ")")
cp <- function(ct) if (!length(ct)) "None" else paste0("{", paste(sprintf("\"%s\": %s", names(ct), vapply(ct, function(v) if (is.logical(v)) (if (v) "True" else "False") else if (length(v) > 1) sub("^np.array\\((.*)\\)$", "\\1", vp(v)) else num(v, "py"), "")), collapse = ", "), "}")
cj <- function(ct) if (!length(ct)) "nothing" else paste0("Dict{String,Any}(", paste(sprintf("\"%s\" => %s", names(ct), vapply(ct, function(v) if (is.logical(v)) tolower(as.character(v)) else if (length(v) > 1) vj(v) else num(v, "jl"), "")), collapse = ", "), ")")

# ein Lauf ueber die Rueckfrage (Host-Schleife) mit der C-Prueffunktion id
opt_case <- function(id_case, fid, x0, method, grad = FALSE, lo = NULL, hi = NULL, ctl = list()) {
  br <- if (is.null(lo)) "" else sprintf(", lower = %s, upper = %s", vr(lo), vr(hi))
  bp <- if (is.null(lo)) "" else sprintf(", lower=%s, upper=%s", vp(lo), vp(hi))
  bj <- if (is.null(lo)) "" else sprintf(", lower = %s, upper = %s", vj(lo), vj(hi))
  gr_r <- if (grad) sprintf("function(x) sl$.sl_opt_testfn(%d, x, TRUE)[[2]]", fid) else "NULL"
  gr_p <- if (grad) sprintf("lambda x: L.opt_testfn(%d, x, True)[1]", fid) else "None"
  gr_j <- if (grad) sprintf("x -> L.opt_testfn(%d, x; grad = true)[2]", fid) else "nothing"
  cs(id_case,
     r = sprintf("sl$.sl_optim(%s, function(x) sl$.sl_opt_testfn(%d, x), %s, method = \"%s\"%s, control = %s)",
                 vr(x0), fid, gr_r, method, br, cr(ctl)),
     py = sprintf("result = L.optim(%s, lambda x: L.opt_testfn(%d, x), %s, method=\"%s\"%s, control=%s)",
                  vp(x0), fid, gr_p, method, bp, cp(ctl)),
     jl = sprintf("result = L.optim(%s, x -> L.opt_testfn(%d, x), %s; method = \"%s\"%s, control = %s)",
                  vj(x0), fid, gr_j, method, bj, cj(ctl)))
}
# derselbe Lauf direkt in C (sl_minimize mit Funktionszeiger)
c_case <- function(id_case, fid, x0, method, grad = FALSE, lo = NULL, hi = NULL, ctl = list()) {
  br <- if (is.null(lo)) "" else sprintf(", lower = %s, upper = %s", vr(lo), vr(hi))
  bp <- if (is.null(lo)) "" else sprintf(", lower=%s, upper=%s", vp(lo), vp(hi))
  bj <- if (is.null(lo)) "" else sprintf(", lower = %s, upper = %s", vj(lo), vj(hi))
  cs(id_case,
     r = sprintf("sl$.sl_minimize_test(%d, %s, \"%s\"%s, control = %s, grad = %s)", fid, vr(x0), method, br, cr(ctl), grad),
     py = sprintf("result = L.minimize_test(%d, %s, \"%s\"%s, control=%s, grad=%s)", fid, vp(x0), method, bp, cp(ctl), if (grad) "True" else "False"),
     jl = sprintf("result = L.minimize_test(%d, %s; method = \"%s\"%s, control = %s, grad = %s)", fid, vj(x0), method, bj, cj(ctl), tolower(grad)))
}

TR <- list(trace = TRUE)
starts <- list(rosen2 = list(1, c(-1.2, 1)), rosen10 = list(1, rep(c(-1.2, 1), 5)), beale = list(2, c(1, 1)),
               powell = list(3, c(3, -1, 0, 1)), wood = list(4, c(-3, -1, -3, -1)), quad5 = list(5, rep(0, 5)),
               glatt_nicht = list(6, c(3, 3, 3)), logschranke = list(7, c(3, 3, 3)))
meths <- c(nm = "Nelder-Mead", bfgs = "BFGS", pbfgs = "L-BFGS-B")
for (nm in names(starts)) for (mk in names(meths)) {
  s <- starts[[nm]]
  long <- nm %in% c("rosen10", "quad5", "wood")
  opt_case(sprintf("%s_%s_num", mk, nm), s[[1]], s[[2]], meths[[mk]], ctl = if (long) list() else TR)
  if (mk != "nm") opt_case(sprintf("%s_%s_grad", mk, nm), s[[1]], s[[2]], meths[[mk]], grad = TRUE, ctl = if (long) list() else TR)
  c_case(sprintf("c_%s_%s", mk, nm), s[[1]], s[[2]], meths[[mk]])
}
# Schranken mit aktiven Grenzen
boxes <- list(rosen_kasten = list(1, c(-1.2, 1), c(-2, 1.5), c(0.5, 3)),
              rosen10_kasten = list(1, rep(c(-0.2, 0.3), 5), rep(-0.5, 10), rep(0.8, 10)),
              quad_kopplung = list(8, rep(0, 4), rep(-1, 4), rep(1, 4)),
              quad_halboffen = list(8, rep(0.5, 6), c(-Inf, -1, 0, -Inf, -Inf, -1), c(1.5, Inf, Inf, 0, 3, Inf)),
              quad5_kasten = list(5, rep(0.2, 5), rep(0, 5), c(2, 0.5, 2, 0.5, 2)),
              log_kasten = list(7, c(3, 3, 3), rep(1e-3, 3), c(0.8, 0.3, 1)),
              fest = list(8, c(1, 0.5, 2), c(1, -Inf, -Inf), c(1, Inf, Inf)),
              start_ausserhalb = list(8, c(5, -5, 5, -5), rep(-1, 4), rep(1, 4)))
for (nm in names(boxes)) {
  b <- boxes[[nm]]
  opt_case(sprintf("pbfgs_%s_num", nm), b[[1]], b[[2]], "L-BFGS-B", lo = b[[3]], hi = b[[4]], ctl = TR)
  opt_case(sprintf("pbfgs_%s_grad", nm), b[[1]], b[[2]], "L-BFGS-B", grad = TRUE, lo = b[[3]], hi = b[[4]])
  c_case(sprintf("c_pbfgs_%s", nm), b[[1]], b[[2]], "L-BFGS-B", lo = b[[3]], hi = b[[4]])
}
# Steuerwerte wie an den SimLev-Aufrufstellen und Skalierung
ctls <- list(nm_maxit4000 = list("Nelder-Mead", list(maxit = 4000)),
             nm_reltol = list("Nelder-Mead", list(maxit = 500, reltol = 1e-10)),
             nm_maxit10 = list("Nelder-Mead", list(maxit = 10)),
             bfgs_reltol = list("BFGS", list(maxit = 500, reltol = 1e-10)),
             bfgs_maxit5 = list("BFGS", list(maxit = 5)),
             bfgs_maxfev = list("BFGS", list(maxfev = 12)),
             bfgs_skaliert = list("BFGS", list(parscale = c(2, 0.5), fnscale = 3)),
             bfgs_gtol = list("BFGS", list(gtol = 1e-3, xtol = 1e-6)),
             pbfgs_factr = list("L-BFGS-B", list(maxit = 5000, factr = 1e3, pgtol = 1e-12)),
             pbfgs_skaliert = list("PBFGS", list(parscale = c(0.5, 4), fnscale = 0.25, reltol = 1e-12)),
             nm_skaliert = list("NM", list(parscale = c(3, 1), maxfev = 300)))
for (nm in names(ctls)) {
  q <- ctls[[nm]]
  opt_case(paste0("steuer_", nm), 1, c(-1.2, 1), q[[1]], ctl = q[[2]])
  c_case(paste0("c_steuer_", nm), 1, c(-1.2, 1), q[[1]], ctl = q[[2]])
}
# Maximum ueber fnscale < 0 (Host-Zielfunktion nur aus + und *, in allen Sprachen bitgleich)
cs("maximum_fnscale", r = "sl$.sl_optim(c(1, 1), function(x) 3 - (x[1] - 2) * (x[1] - 2) - (x[2] + 1) * (x[2] + 1) + 0.5 * x[1] * x[2], method = 'BFGS', control = list(fnscale = -1, trace = TRUE))",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 3 - (x[0] - 2) * (x[0] - 2) - (x[1] + 1) * (x[1] + 1) + 0.5 * x[0] * x[1], method='BFGS', control={'fnscale': -1, 'trace': True})",
   jl = "result = L.optim([1.0, 1.0], x -> 3 - (x[1] - 2) * (x[1] - 2) - (x[2] + 1) * (x[2] + 1) + 0.5 * x[1] * x[2]; method = \"BFGS\", control = Dict{String,Any}(\"fnscale\" => -1, \"trace\" => true))")
# NaN und Inf waehrend der Suche (+Inf), Startwert nicht endlich (Fehler)
cs("inf_bereich_bfgs", r = "sl$.sl_optim(c(-1.2, 1), function(x) if (x[1] > 0.9) Inf else sl$.sl_opt_testfn(1, x), method = 'BFGS')",
   py = "result = L.optim(np.array([-1.2, 1.0]), lambda x: math.inf if x[0] > 0.9 else L.opt_testfn(1, x), method='BFGS')",
   jl = "result = L.optim([-1.2, 1.0], x -> x[1] > 0.9 ? Inf : L.opt_testfn(1, x); method = \"BFGS\")")
cs("nan_bereich_nm", r = "sl$.sl_optim(c(0, 0, 0), function(x) if (x[1] + x[2] + x[3] > 1) NaN else (x[1] - 0.3) * (x[1] - 0.3) + (x[2] - 0.3) * (x[2] - 0.3) + (x[3] - 0.3) * (x[3] - 0.3), method = 'Nelder-Mead')",
   py = "result = L.optim(np.zeros(3), lambda x: math.nan if x[0] + x[1] + x[2] > 1 else (x[0] - 0.3) * (x[0] - 0.3) + (x[1] - 0.3) * (x[1] - 0.3) + (x[2] - 0.3) * (x[2] - 0.3), method='Nelder-Mead')",
   jl = "result = L.optim(zeros(3), x -> x[1] + x[2] + x[3] > 1 ? NaN : (x[1] - 0.3) * (x[1] - 0.3) + (x[2] - 0.3) * (x[2] - 0.3) + (x[3] - 0.3) * (x[3] - 0.3); method = \"Nelder-Mead\")")
for (m in c("Nelder-Mead", "BFGS", "L-BFGS-B"))
  cs(paste0("fehler_start_nan_", gsub("-", "", m)), r = sprintf("sl$.sl_optim(c(1, 1), function(x) NaN, method = '%s')", m),
     py = sprintf("result = L.optim(np.array([1.0, 1.0]), lambda x: math.nan, method='%s')", m),
     jl = sprintf("result = L.optim([1.0, 1.0], x -> NaN; method = \"%s\")", m))
cs("fehler_gradient_start", r = "sl$.sl_optim(c(1, 1), function(x) 1, function(x) c(NaN, 1), method = 'BFGS')",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 1.0, lambda x: np.array([math.nan, 1.0]), method='BFGS')",
   jl = "result = L.optim([1.0, 1.0], x -> 1.0, x -> [NaN, 1.0]; method = \"BFGS\")")
cs("fehler_schranken_bfgs", r = "sl$.sl_optim(c(1, 1), function(x) 1, method = 'BFGS', lower = 0)",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 1.0, method='BFGS', lower=0.0)",
   jl = "result = L.optim([1.0, 1.0], x -> 1.0; method = \"BFGS\", lower = 0.0)")
cs("fehler_schranken_kreuz", r = "sl$.sl_optim(c(1, 1), function(x) 1, method = 'L-BFGS-B', lower = c(0, 3), upper = 2)",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 1.0, method='L-BFGS-B', lower=[0.0, 3.0], upper=2.0)",
   jl = "result = L.optim([1.0, 1.0], x -> 1.0; method = \"L-BFGS-B\", lower = [0.0, 3.0], upper = 2.0)")
cs("fehler_steuerwert", r = "sl$.sl_optim(c(1, 1), function(x) 1, control = list(abstol = 1))",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 1.0, control={'abstol': 1})",
   jl = "result = L.optim([1.0, 1.0], x -> 1.0; control = Dict{String,Any}(\"abstol\" => 1))")
cs("fehler_factr_reltol", r = "sl$.sl_optim(c(1, 1), function(x) 1, method = 'L-BFGS-B', control = list(factr = 1, reltol = 1))",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 1.0, method='L-BFGS-B', control={'factr': 1, 'reltol': 1})",
   jl = "result = L.optim([1.0, 1.0], x -> 1.0; method = \"L-BFGS-B\", control = Dict{String,Any}(\"factr\" => 1, \"reltol\" => 1))")
cs("fehler_zielfunktion_laenge", r = "sl$.sl_optim(c(1, 1), function(x) c(1, 2), method = 'BFGS')",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: np.array([1.0, 2.0]), method='BFGS')",
   jl = "result = L.optim([1.0, 1.0], x -> [1.0, 2.0]; method = \"BFGS\")")
cs("fehler_gradient_laenge", r = "sl$.sl_optim(c(1, 1), function(x) 1, function(x) 1, method = 'BFGS')",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 1.0, lambda x: np.array([1.0]), method='BFGS')",
   jl = "result = L.optim([1.0, 1.0], x -> 1.0, x -> [1.0]; method = \"BFGS\")")
cs("fehler_startwert", r = "sl$.sl_optim(c(1, Inf), function(x) 1, method = 'BFGS')",
   py = "result = L.optim(np.array([1.0, math.inf]), lambda x: 1.0, method='BFGS')",
   jl = "result = L.optim([1.0, Inf], x -> 1.0; method = \"BFGS\")")
cs("fehler_parscale", r = "sl$.sl_optim(c(1, 1), function(x) 1, control = list(parscale = c(1, 0)))",
   py = "result = L.optim(np.array([1.0, 1.0]), lambda x: 1.0, control={'parscale': [1.0, 0.0]})",
   jl = "result = L.optim([1.0, 1.0], x -> 1.0; control = Dict{String,Any}(\"parscale\" => [1.0, 0.0]))")
# Prueffunktionen und numerischer Gradient (B.9), auch an Schranken
set.seed(931)
pts <- list(list(1, stats::rnorm(6)), list(2, c(1.3, -0.4)), list(3, stats::rnorm(4)), list(4, stats::rnorm(4)),
            list(5, stats::rnorm(5)), list(6, c(0.5, 0.2, 3)), list(7, c(0.2, 1, 2)), list(7, c(-1, 1)), list(8, stats::rnorm(6)))
for (k in seq_along(pts)) {
  q <- pts[[k]]
  cs(sprintf("testfn_%d_%d", q[[1]], k), r = sprintf("list(sl$.sl_opt_testfn(%d, x, TRUE), sl$.sl_numgrad_test(%d, x))", q[[1]], q[[1]]),
     py = sprintf("result = [L.opt_testfn(%d, x, True), L.numgrad_test(%d, x)]", q[[1]], q[[1]]),
     jl = sprintf("result = Any[L.opt_testfn(%d, x; grad = true), L.numgrad_test(%d, x)]", q[[1]], q[[1]]), inputs = list(x = q[[2]]))
}
cs("numgrad_schranken", r = "sl$.sl_numgrad_test(8, c(1, 0.5, -1, 2, 0.3), lower = c(1, -2, -1 - 1e-12, 2 - 1e-9, 0.3), upper = c(3, 0.5, 2, 2 + 1e-9, 0.3))",
   py = "result = L.numgrad_test(8, [1.0, 0.5, -1.0, 2.0, 0.3], lower=[1.0, -2.0, -1 - 1e-12, 2 - 1e-9, 0.3], upper=[3.0, 0.5, 2.0, 2 + 1e-9, 0.3])",
   jl = "result = L.numgrad_test(8, [1.0, 0.5, -1.0, 2.0, 0.3]; lower = [1.0, -2.0, -1 - 1e-12, 2 - 1e-9, 0.3], upper = [3.0, 0.5, 2.0, 2 + 1e-9, 0.3])")
cs("numgrad_nan_seite", r = "sl$.sl_numgrad_test(7, c(1e-7, 1, 2))",
   py = "result = L.numgrad_test(7, [1e-7, 1.0, 2.0])", jl = "result = L.numgrad_test(7, [1e-7, 1.0, 2.0])")

ref_done()
