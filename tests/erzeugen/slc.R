# tests/erzeugen/slc.R – Referenzfälle des Bereichs slc: Kerne der C-Bibliothek slc: Zufall, Verteilungen, lineare Algebra, Optimierer, Modelle.
# Module: slc, slc_linalg, slc_opt, slc_models (bis T20 je ein Generator gen_<modul>.R, hier wörtlich hintereinander).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/erzeugen/slc.R
# Ausgabe tests/faelle/slc.jsonl.gz (Format und Umgebung: tests/erzeugen/ref_tools.R).
source("tests/erzeugen/ref_tools.R")
ref_bereich("slc")

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul slc
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Zusatzfaelle der Gleichlaufpruefung (Etappe 9.1, Entwurf C.8): Exporte und interne Huellen ohne
# Fall in den Generatoren tests/erzeugen/*.R. Modul "slc": simlev_seed() und die Ziehungen und
# Verteilungen der C-Bibliothek slc (.sl_* in R, simlev._lib in Python, SimLev.SLib in Julia).
#
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
ref_init("slc")

P <- "import numpy as np\nimport simlev._lib as L\n"
J <- "const L = SL.SLib\n"
cs <- function(id, r, py, jl, inputs = list())
  ref_case(id, r = paste0("sl <- asNamespace('SimLev')\n", r), py = paste0(P, py), jl = paste0(J, jl), inputs = inputs)

# ── simlev_seed, Testvektoren, Zustand ──
for (s in c(0, 1, -1, 42, 2^53 - 1, -(2^53 - 1), 123456789)) {
  id <- paste0("seed_", gsub("-", "m", format(s, scientific = FALSE)))
  cs(id, r = sprintf("simlev_seed(%s); list(sl$.sl_state_hex(), sl$.sl_u64(5))", format(s, scientific = FALSE)),
     py = sprintf("simlev.simlev_seed(%s); result = [L.state_hex(), L.u64(5)]", format(s, scientific = FALSE)),
     jl = sprintf("simlev_seed(%s); result = Any[L.state_hex(), L.u64(5)]", format(s, scientific = FALSE)))
}
cs("seed_rueckgabe", r = "simlev_seed(17)", py = "result = simlev.simlev_seed(17)", jl = "result = simlev_seed(17)")
cs("seed_fehler_bruch", r = "simlev_seed(1.5)", py = "result = simlev.simlev_seed(1.5)", jl = "result = simlev_seed(1.5)")
cs("seed_fehler_gross", r = "simlev_seed(2^53)", py = "result = simlev.simlev_seed(2**53)", jl = "result = simlev_seed(2^53)")
cs("next_seed", r = "simlev_seed(5); c(sl$.sl_next_seed(), sl$.sl_next_seed(), sl$.sl_next_seed())",
   py = "simlev.simlev_seed(5); result = np.array([L.next_seed(), L.next_seed(), L.next_seed()], dtype=np.int32)",
   jl = "simlev_seed(5); result = Int32[L.next_seed(), L.next_seed(), L.next_seed()]")
cs("einheit_sperre", r = "sl$.sl_in_unit(sl$.sl_runif(1))",
   py = "with L.in_unit():\n    result = L.runif(1)", jl = "result = L.in_unit(() -> L.runif(1))")

# ── Stroeme je Einheit ──
cs("stroeme", r = "u <- sl$.sl_streams(sl$.sl_stream(9), 4); lapply(u, function(s) c(sl$.sl_state_hex(s), sl$.sl_u64(2, stream = s)))",
   py = "u = L.streams(L.Stream(9), 4)\nresult = [L.state_hex(s) + L.u64(2, stream=s) for s in u]",
   jl = "u = L.streams(L.Stream(9), 4)\nresult = Any[vcat(L.state_hex(s), L.u64(2; stream = s)) for s in u]")
cs("strom_und_global", r = "simlev_seed(3); s <- sl$.sl_stream(3); list(sl$.sl_runif(3, stream = s), sl$.sl_runif(3), sl$.sl_state_hex(s), sl$.sl_state_hex())",
   py = "simlev.simlev_seed(3); s = L.Stream(3)\nresult = [L.runif(3, stream=s), L.runif(3), L.state_hex(s), L.state_hex()]",
   jl = "simlev_seed(3); s = L.Stream(3)\nresult = Any[L.runif(3; stream = s), L.runif(3), L.state_hex(s), L.state_hex()]")

# ── Ziehungen ──
draws <- list(
  runif = list(r = "sl$.sl_runif(200, -2, 3)", py = "L.runif(200, -2.0, 3.0)", jl = "L.runif(200, -2.0, 3.0)"),
  runif_gleich = list(r = "sl$.sl_runif(3, 2, 2)", py = "L.runif(3, 2.0, 2.0)", jl = "L.runif(3, 2.0, 2.0)"),
  runif_nan = list(r = "sl$.sl_runif(3, 3, 2)", py = "L.runif(3, 3.0, 2.0)", jl = "L.runif(3, 3.0, 2.0)"),
  rnorm = list(r = "sl$.sl_rnorm(300, 1, 2)", py = "L.rnorm(300, 1.0, 2.0)", jl = "L.rnorm(300, 1.0, 2.0)"),
  rnorm_sd0 = list(r = "sl$.sl_rnorm(3, 1, 0)", py = "L.rnorm(3, 1.0, 0.0)", jl = "L.rnorm(3, 1.0, 0.0)"),
  rnorm_nan = list(r = "sl$.sl_rnorm(2, 0, -1)", py = "L.rnorm(2, 0.0, -1.0)", jl = "L.rnorm(2, 0.0, -1.0)"),
  rexp = list(r = "sl$.sl_rexp(200, 0.5)", py = "L.rexp(200, 0.5)", jl = "L.rexp(200, 0.5)"),
  rgeom = list(r = "sl$.sl_rgeom(200, 0.05)", py = "L.rgeom(200, 0.05)", jl = "L.rgeom(200, 0.05)"),
  rgeom_eins = list(r = "sl$.sl_rgeom(3, 1)", py = "L.rgeom(3, 1.0)", jl = "L.rgeom(3, 1.0)"),
  rgeom_nan = list(r = "sl$.sl_rgeom(2, 0)", py = "L.rgeom(2, 0.0)", jl = "L.rgeom(2, 0.0)"),
  rgamma_klein = list(r = "sl$.sl_rgamma(200, 0.3)", py = "L.rgamma(200, 0.3)", jl = "L.rgamma(200, 0.3)"),
  rgamma = list(r = "sl$.sl_rgamma(200, 4.5, 2)", py = "L.rgamma(200, 4.5, 2.0)", jl = "L.rgamma(200, 4.5, 2.0)"),
  rchisq = list(r = "sl$.sl_rchisq(200, 5)", py = "L.rchisq(200, 5.0)", jl = "L.rchisq(200, 5.0)"),
  rchisq_nan = list(r = "sl$.sl_rchisq(2, -1)", py = "L.rchisq(2, -1.0)", jl = "L.rchisq(2, -1.0)"),
  sample_perm = list(r = "sl$.sl_sample(50)", py = "L.sample(50)", jl = "L.sample(50)"),
  sample_teil = list(r = "sl$.sl_sample(1000, 7)", py = "L.sample(1000, 7)", jl = "L.sample(1000, 7)"),
  sample_rep = list(r = "sl$.sl_sample(6, 100, TRUE)", py = "L.sample(6, 100, True)", jl = "L.sample(6, 100; replace = true)"),
  sample_prob = list(r = "sl$.sl_sample(5, 100, TRUE, c(0.1, 0, 2, 0.5, 1.4))",
                     py = "L.sample(5, 100, True, [0.1, 0.0, 2.0, 0.5, 1.4])",
                     jl = "L.sample(5, 100; replace = true, prob = [0.1, 0.0, 2.0, 0.5, 1.4])"),
  sample_prob_ohne = list(r = "sl$.sl_sample(5, 3, FALSE, c(0.1, 0, 2, 0.5, 1.4))",
                          py = "L.sample(5, 3, False, [0.1, 0.0, 2.0, 0.5, 1.4])",
                          jl = "L.sample(5, 3; replace = false, prob = [0.1, 0.0, 2.0, 0.5, 1.4])"),
  sample_fehler = list(r = "sl$.sl_sample(3, 5)", py = "L.sample(3, 5)", jl = "L.sample(3, 5)"),
  sample_gewichte = list(r = "sl$.sl_sample(3, 2, TRUE, c(1, -1, 1))", py = "L.sample(3, 2, True, [1.0, -1.0, 1.0])",
                         jl = "L.sample(3, 2; replace = true, prob = [1.0, -1.0, 1.0])")
)
for (nm in names(draws)) {
  d <- draws[[nm]]
  cs(paste0("zieh_", nm), r = sprintf("simlev_seed(2026); x <- %s; list(x, sl$.sl_state_hex())", d$r),
     py = sprintf("simlev.simlev_seed(2026); x = %s\nresult = [x, L.state_hex()]", d$py),
     jl = sprintf("simlev_seed(2026); x = %s\nresult = Any[x, L.state_hex()]", d$jl))
}

# ── Verteilungen (Eingaben als Baeume: in allen Sprachen dieselben double-Werte) ──
xs <- c(NA, NaN, -Inf, -40, -38.4, -37.6, -20, -5.01, -5, -1, -0.3, -0, 0, 1e-300, 0.25, 1, 4.99, 5, 8.3, 30, Inf)
ps <- c(NA, NaN, -0.1, 0, 4.9e-324, 1e-300, 1e-20, 2.8e-7, 0.01, 0.075, 0.3, 0.5, 0.7, 0.925, 1 - 1e-10, 1 - 2^-53, 1, 1.5)
pos <- c(NA, NaN, -1, 0, 1e-300, 1e-10, 0.3, 0.5, 1, 1.5, 2, 2.5, 3.7, 9.99, 10, 10.01, 171.5, 1e6, 1e300, Inf)
ts <- c(NA, NaN, -Inf, -1e200, -1e10, -50, -5, -2, -0.3, 0, 0.3, 2, 5, 50, 1e10, Inf)
bx <- c(NA, NaN, -0.5, 0, 1e-300, 1e-10, 0.01, 0.3, 0.5, 0.88, 0.97, 0.999999, 1, 1.5)
dist <- list(
  pnorm = c("sl$.sl_pnorm(x)", "L.pnorm(x)", "L.pnorm(x)", "xs"),
  pnorm_oben = c("sl$.sl_pnorm(x, lower.tail = FALSE)", "L.pnorm(x, lower_tail=False)", "L.pnorm(x; lower_tail = false)", "xs"),
  pnorm_musd = c("sl$.sl_pnorm(x, 1, 2)", "L.pnorm(x, 1.0, 2.0)", "L.pnorm(x, 1.0, 2.0)", "xs"),
  pnorm_sd0 = c("sl$.sl_pnorm(x, 0.25, 0)", "L.pnorm(x, 0.25, 0.0)", "L.pnorm(x, 0.25, 0.0)", "xs"),
  pnorm_sdneg = c("sl$.sl_pnorm(x, 0, -1)", "L.pnorm(x, 0.0, -1.0)", "L.pnorm(x, 0.0, -1.0)", "xs"),
  qnorm = c("sl$.sl_qnorm(x)", "L.qnorm(x)", "L.qnorm(x)", "ps"),
  qnorm_oben = c("sl$.sl_qnorm(x, 2, 3, lower.tail = FALSE)", "L.qnorm(x, 2.0, 3.0, lower_tail=False)", "L.qnorm(x, 2.0, 3.0; lower_tail = false)", "ps"),
  qnorm_sd0 = c("sl$.sl_qnorm(x, 1, 0)", "L.qnorm(x, 1.0, 0.0)", "L.qnorm(x, 1.0, 0.0)", "ps"),
  dnorm = c("sl$.sl_dnorm(x)", "L.dnorm(x)", "L.dnorm(x)", "xs"),
  dnorm_log = c("sl$.sl_dnorm(x, 1, 2, log = TRUE)", "L.dnorm(x, 1.0, 2.0, log=True)", "L.dnorm(x, 1.0, 2.0; log = true)", "xs"),
  erfc = c("sl$.sl_erfc(x)", "L.erfc(x)", "L.erfc(x)", "xs"),
  lgamma = c("sl$.sl_lgamma(x)", "L.lgamma(x)", "L.lgamma(x)", "pos"),
  pt_3 = c("sl$.sl_pt(x, 3)", "L.pt(x, 3.0)", "L.pt(x, 3.0)", "ts"),
  pt_05_oben = c("sl$.sl_pt(x, 0.5, lower.tail = FALSE)", "L.pt(x, 0.5, lower_tail=False)", "L.pt(x, 0.5; lower_tail = false)", "ts"),
  pt_gross = c("sl$.sl_pt(x, 4e5)", "L.pt(x, 4e5)", "L.pt(x, 4e5)", "ts"),
  pt_inf = c("sl$.sl_pt(x, Inf)", "L.pt(x, np.inf)", "L.pt(x, Inf)", "ts"),
  pt_nan = c("sl$.sl_pt(x, -1)", "L.pt(x, -1.0)", "L.pt(x, -1.0)", "ts"),
  qt_1 = c("sl$.sl_qt(x, 1)", "L.qt(x, 1.0)", "L.qt(x, 1.0)", "ps"),
  qt_2 = c("sl$.sl_qt(x, 2)", "L.qt(x, 2.0)", "L.qt(x, 2.0)", "ps"),
  qt_5 = c("sl$.sl_qt(x, 5.5)", "L.qt(x, 5.5)", "L.qt(x, 5.5)", "ps"),
  qt_30_oben = c("sl$.sl_qt(x, 30, lower.tail = FALSE)", "L.qt(x, 30.0, lower_tail=False)", "L.qt(x, 30.0; lower_tail = false)", "ps"),
  qt_klein = c("sl$.sl_qt(x, 0.5)", "L.qt(x, 0.5)", "L.qt(x, 0.5)", "ps"),
  pbeta = c("sl$.sl_pbeta(x, 2, 3)", "L.pbeta(x, 2.0, 3.0)", "L.pbeta(x, 2.0, 3.0)", "bx"),
  pbeta_klein = c("sl$.sl_pbeta(x, 6.4, 0.0118, lower.tail = FALSE)", "L.pbeta(x, 6.4, 0.0118, lower_tail=False)", "L.pbeta(x, 6.4, 0.0118; lower_tail = false)", "bx"),
  pbeta_gross = c("sl$.sl_pbeta(x, 1e5, 3)", "L.pbeta(x, 1e5, 3.0)", "L.pbeta(x, 1e5, 3.0)", "bx"),
  pbeta_beide = c("sl$.sl_pbeta(x, 30, 40)", "L.pbeta(x, 30.0, 40.0)", "L.pbeta(x, 30.0, 40.0)", "bx"),
  pbeta_nan = c("sl$.sl_pbeta(x, 0, 1)", "L.pbeta(x, 0.0, 1.0)", "L.pbeta(x, 0.0, 1.0)", "bx"),
  plogis = c("sl$.sl_plogis(x)", "L.plogis(x)", "L.plogis(x)", "xs"),
  qlogis = c("sl$.sl_qlogis(x)", "L.qlogis(x)", "L.qlogis(x)", "ps")
)
grids <- list(xs = xs, ps = ps, pos = pos, ts = ts, bx = bx)
for (nm in names(dist)) {
  d <- dist[[nm]]
  cs(paste0("vert_", nm), r = d[1], py = paste0("result = ", d[2]), jl = paste0("result = ", d[3]),
     inputs = list(x = grids[[d[4]]]))
}

# ── zufaellige Gitter (dicht) ──
set.seed(91)
gx <- c(stats::runif(400, -40, 9), stats::rnorm(200))
gp <- c(10^stats::runif(300, -300, 0), stats::runif(200))
for (nu in c(1.5, 4, 25)) {
  cs(sprintf("gitter_pt_%s", sub("\\.", "_", format(nu))), r = sprintf("sl$.sl_pt(x, %s)", format(nu)),
     py = sprintf("result = L.pt(x, %s)", format(nu)), jl = sprintf("result = L.pt(x, %s)", format(nu)), inputs = list(x = gx))
  cs(sprintf("gitter_qt_%s", sub("\\.", "_", format(nu))), r = sprintf("sl$.sl_qt(x, %s)", format(nu)),
     py = sprintf("result = L.qt(x, %s)", format(nu)), jl = sprintf("result = L.qt(x, %s)", format(nu)), inputs = list(x = gp))
}
cs("gitter_pnorm", r = "sl$.sl_pnorm(x)", py = "result = L.pnorm(x)", jl = "result = L.pnorm(x)", inputs = list(x = gx))
cs("gitter_qnorm", r = "sl$.sl_qnorm(x)", py = "result = L.qnorm(x)", jl = "result = L.qnorm(x)", inputs = list(x = gp))
cs("gitter_lgamma", r = "sl$.sl_lgamma(abs(x))", py = "result = L.lgamma(np.abs(x))", jl = "result = L.lgamma(abs.(x))", inputs = list(x = gx))

ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul slc_linalg
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Zusatzfaelle der Gleichlaufpruefung, Etappe 9.2 (Entwurf C.8/C.9): Modul "slc_linalg" mit den
# Huellen der Kerne aus 9.2 (.sl_* in R, simlev._lib in Python, SimLev.SLib in Julia): Cholesky,
# Band-Cholesky, Dreiecksloeser, SPD-Loeser, log det, Eigenwerte, Matrixprodukt, kleinste
# Quadrate, Logit-IRLS, Stineman, Glaettungsspline, Kerndichte; je mit Randfaellen (singulaer,
# rangdefizient, fast singulaer, 1x1, leer, NA) und Fehlertexten.
#
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
ref_init("slc_linalg")

P <- "import numpy as np\nimport simlev._lib as L\n"
J <- "const L = SL.SLib\n"
cs <- function(id, r, py, jl, inputs = list())
  ref_case(id, r = paste0("sl <- asNamespace('SimLev')\n", r), py = paste0(P, "result = ", py),
           jl = paste0(J, "result = ", jl), inputs = inputs)

set.seed(9202)
rorth <- function(n) qr.Q(qr(matrix(rnorm(n * n), n)))
spd <- function(n, lc = 2) { Q <- rorth(n); A <- Q %*% diag(10^seq(0, -lc, length.out = n), n) %*% t(Q); (A + t(A)) / 2 }
sym <- function(n) { A <- matrix(rnorm(n * n), n); (A + t(A)) / 2 }

# ── Cholesky, Dreiecksloeser, SPD-Loeser, log det ──
mats <- list(m1 = matrix(4, 1), m3 = spd(3), m7 = spd(7, 6), m20 = spd(20, 9), e0 = matrix(numeric(0), 0, 0),
             sing = matrix(c(1, 2, 2, 4), 2), indef = matrix(c(1, 2, 2, 1), 2), fast = matrix(c(1, 1, 1, 1 + 1e-15), 2),
             na = matrix(c(1, NA, NA, 1), 2), nan = matrix(c(1, NaN, NaN, 1), 2), inf = matrix(c(Inf, 0, 0, 1), 2),
             rect = matrix(1:6 + 0, 2))
for (nm in names(mats)) {
  inp <- list(A = mats[[nm]])
  cs(paste0("chol_", nm), "sl$.sl_chol(A)", "L.chol(A)", "L.chol(A)", inp)
  if (nm %in% c("rect")) next
  n <- nrow(mats[[nm]])
  inp$b <- rnorm(n); inp$B <- matrix(rnorm(n * 2), n)
  cs(paste0("solve_vec_", nm), "sl$.sl_solve_spd(A, b)", "L.solve_spd(A, b)", "L.solve_spd(A, b)", inp)
  cs(paste0("solve_mat_", nm), "sl$.sl_solve_spd(A, B)", "L.solve_spd(A, B)", "L.solve_spd(A, B)", inp)
  cs(paste0("solve_inv_", nm), "sl$.sl_solve_spd(A)", "L.solve_spd(A)", "L.solve_spd(A)", inp)
  cs(paste0("logdet_", nm), "sl$.sl_logdet_spd(A)", "L.logdet_spd(A)", "L.logdet_spd(A)", inp)
}
cs("solve_na_b", "sl$.sl_solve_spd(A, b)", "L.solve_spd(A, b)", "L.solve_spd(A, b)", list(A = spd(3), b = c(1, NA, 2)))
cs("solve_dim", "sl$.sl_solve_spd(A, b)", "L.solve_spd(A, b)", "L.solve_spd(A, b)", list(A = spd(3), b = c(1, 2)))
R6 <- chol(spd(6)); b6 <- rnorm(6); B6 <- matrix(rnorm(18), 6)
for (up in c(TRUE, FALSE)) for (tr in c(TRUE, FALSE)) {
  T6 <- if (up) R6 else t(R6)
  id <- sprintf("backsolve_%s_%s", if (up) "oben" else "unten", if (tr) "trans" else "plain")
  rr <- sprintf("list(sl$.sl_backsolve(T, b, upper.tri = %s, transpose = %s), sl$.sl_backsolve(T, B, upper.tri = %s, transpose = %s))", up, tr, up, tr)
  py <- sprintf("[L.backsolve(T, b, upper_tri=%s, transpose=%s), L.backsolve(T, B, upper_tri=%s, transpose=%s)]",
                if (up) "True" else "False", if (tr) "True" else "False", if (up) "True" else "False", if (tr) "True" else "False")
  jl <- sprintf("Any[L.backsolve(T, b; upper_tri = %s, transpose = %s), L.backsolve(T, B; upper_tri = %s, transpose = %s)]",
                tolower(up), tolower(tr), tolower(up), tolower(tr))
  cs(id, rr, py, jl, list(T = T6, b = b6, B = B6))
}
cs("backsolve_diag0", "sl$.sl_backsolve(T, b)", "L.backsolve(T, b)", "L.backsolve(T, b)", list(T = matrix(c(1, 0, 1, 0), 2), b = c(1, 1)))
cs("backsolve_na", "sl$.sl_backsolve(T, b)", "L.backsolve(T, b)", "L.backsolve(T, b)", list(T = matrix(c(1, 0, 1, 2), 2), b = c(NA, 1)))
cs("backsolve_1x1", "sl$.sl_backsolve(T, b)", "L.backsolve(T, b)", "L.backsolve(T, b)", list(T = matrix(3, 1), b = 2))
ab <- rbind(c(4, 5, 6, 7, 8), c(1, 1, 1, 1, 0), c(0.5, 0.5, 0.5, 0, 0))
cs("chol_band", "sl$.sl_chol_band(AB, 2)", "L.chol_band(AB, 2)", "L.chol_band(AB, 2)", list(AB = ab))
cs("chol_band_indef", "sl$.sl_chol_band(AB, 1)", "L.chol_band(AB, 1)", "L.chol_band(AB, 1)", list(AB = rbind(c(1, 1, 1), c(2, 2, 0))))

# ── Eigenwerte ──
eig <- list(s3 = spd(3), s12 = spd(12, 8), i9 = sym(9), i40 = sym(40), m1 = matrix(-2, 1), e0 = matrix(numeric(0), 0, 0),
            mehrfach = diag(c(2, 2, 1, 2)), sing = matrix(c(1, 2, 2, 4), 2), null = matrix(0, 3, 3),
            unsym = matrix(c(1, 5, 2, 1), 2), na = matrix(c(1, NA, NA, 1), 2), gross = sym(5) * 1e200, klein = sym(5) * 1e-200)
for (nm in names(eig)) {
  cs(paste0("eigen_", nm), "sl$.sl_eigen_sym(A)", "L.eigen_sym(A)", "L.eigen_sym(A)", list(A = eig[[nm]]))
}
cs("eigen_nur_werte", "sl$.sl_eigen_sym(A, only.values = TRUE)", "L.eigen_sym(A, only_values=True)",
   "L.eigen_sym(A; only_values = true)", list(A = sym(6)))

# ── Matrixprodukt ──
A <- matrix(rnorm(35), 5); B <- matrix(rnorm(21), 7); Z <- matrix(rnorm(12), 3)
cs("mm_mat", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = A, B = B))
cs("mm_gross", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = matrix(rnorm(40 * 300), 40), B = matrix(rnorm(300 * 3), 300)))
An <- A; An[2, 3] <- NA; An[4, 1] <- Inf; Bn <- B; Bn[5, 2] <- NaN; Bn[1, 1] <- 0
cs("mm_nan", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = An, B = Bn))
cs("mm_vv", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = rnorm(4), y = rnorm(4)))
cs("mm_v1", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = 2.5, y = rnorm(4)))
cs("mm_1v", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = rnorm(4), y = -1.5))
cs("mm_vM", "sl$.sl_matmul(x, B)", "L.matmul(x, B)", "L.matmul(x, B)", list(x = rnorm(7), B = B))
cs("mm_Mv", "sl$.sl_matmul(A, x)", "L.matmul(A, x)", "L.matmul(A, x)", list(A = A, x = rnorm(7)))
cs("mm_vzeile", "sl$.sl_matmul(x, R1)", "L.matmul(x, R1)", "L.matmul(x, R1)", list(x = rnorm(3), R1 = matrix(rnorm(4), 1)))
cs("mm_leer", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = matrix(numeric(0), 0, 3), B = matrix(1, 3, 2)))
cs("mm_innen0", "sl$.sl_matmul(A, B)", "L.matmul(A, B)", "L.matmul(A, B)", list(A = matrix(numeric(0), 2, 0), B = matrix(numeric(0), 0, 2)))
cs("mm_fehler", "sl$.sl_matmul(A, A)", "L.matmul(A, A)", "L.matmul(A, A)", list(A = A))
cs("mm_fehler_vv", "sl$.sl_matmul(x, y)", "L.matmul(x, y)", "L.matmul(x, y)", list(x = rnorm(3), y = rnorm(4)))
cs("cp_x", "sl$.sl_crossprod(A)", "L.crossprod(A)", "L.crossprod(A)", list(A = A))
cs("cp_xy", "sl$.sl_crossprod(A, Y)", "L.crossprod(A, Y)", "L.crossprod(A, Y)", list(A = A, Y = matrix(rnorm(10), 5)))
cs("cp_vec", "sl$.sl_crossprod(x)", "L.crossprod(x)", "L.crossprod(x)", list(x = rnorm(6)))
cs("cp_lang", "sl$.sl_crossprod(X)", "L.crossprod(X)", "L.crossprod(X)", list(X = matrix(rnorm(3000 * 4), 3000)))
cs("tcp_x", "sl$.sl_tcrossprod(A)", "L.tcrossprod(A)", "L.tcrossprod(A)", list(A = A))
cs("tcp_xy", "sl$.sl_tcrossprod(A, Z)", "L.tcrossprod(A, Z)", "L.tcrossprod(A, Z)", list(A = matrix(rnorm(20), 5), Z = Z))
cs("tcp_vec", "sl$.sl_tcrossprod(x)", "L.tcrossprod(x)", "L.tcrossprod(x)", list(x = rnorm(4)))
cs("cp_fehler", "sl$.sl_crossprod(A, Z)", "L.crossprod(A, Z)", "L.crossprod(A, Z)", list(A = A, Z = Z))

# ── kleinste Quadrate ──
x <- rnorm(40); z <- rnorm(40); y <- 1 + 2 * x - z + rnorm(40, sd = 0.3)
X3 <- cbind(1, x, z); X6 <- cbind(1, x, 2 * x, z, x + z, rnorm(40)); Xf <- cbind(1, x, x + 1e-9 * rnorm(40))
lsc <- list(voll = list(X3, y, NULL, 1), defizient = list(X6, y, NULL, 1), fast = list(Xf, y, NULL, 1),
            gewichtet = list(X3, y, runif(40, 0.2, 2), 1), gewichte0 = list(X3, y, c(0, 0, runif(38)), 1),
            voll_piv2 = list(X6, y, NULL, 2), eins = list(matrix(2, 1), 3, NULL, 1), breit = list(matrix(rnorm(6), 2), c(1, 2), NULL, 1),
            nullspalte = list(cbind(1, 0, 1:4), c(1, 3, 2, 5), NULL, 1), konst = list(cbind(1, rep(3, 5)), 1:5 + 0, NULL, 1),
            lang = list(cbind(1, rnorm(3000)), rnorm(3000), NULL, 1))
for (nm in names(lsc)) {
  a <- lsc[[nm]]
  inp <- list(X = a[[1]], y = a[[2]]); if (!is.null(a[[3]])) inp$w <- a[[3]]
  wr <- if (is.null(a[[3]])) "NULL" else "w"; wp <- if (is.null(a[[3]])) "None" else "w"; wj <- if (is.null(a[[3]])) "nothing" else "w"
  cs(paste0("lsfit_", nm), sprintf("sl$.sl_lsfit(X, y, %s, pivot = %d)", wr, a[[4]]),
     sprintf("L.lsfit(X, y, %s, pivot=%d)", wp, a[[4]]), sprintf("L.lsfit(X, y; w = %s, pivot = %d)", wj, a[[4]]), inp)
}
cs("lsfit_na", "sl$.sl_lsfit(X, y)", "L.lsfit(X, y)", "L.lsfit(X, y)", list(X = X3, y = replace(y, 3, NA)))
cs("lsfit_nan_x", "sl$.sl_lsfit(X, y)", "L.lsfit(X, y)", "L.lsfit(X, y)", list(X = replace(X3, 5, NaN), y = y))
cs("lsfit_leer", "sl$.sl_lsfit(X, y)", "L.lsfit(X, y)", "L.lsfit(X, y)", list(X = matrix(numeric(0), 0, 2), y = numeric(0)))
cs("lsfit_negw", "sl$.sl_lsfit(X, y, w)", "L.lsfit(X, y, w)", "L.lsfit(X, y; w = w)", list(X = X3, y = y, w = c(-1, rep(1, 39))))
xl <- rnorm(300); yl <- as.numeric(runif(300) < plogis(0.4 - 1.3 * xl))
cs("logit", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, xl), y = yl))
cs("logit_trennung", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)",
   list(X = cbind(1, c(-2, -1, -0.5, 0.5, 1, 2)), y = c(0, 0, 0, 1, 1, 1)))
cs("logit_maxit", "sl$.sl_logit_irls(X, y, maxit = 2)", "L.logit_irls(X, y, maxit=2)", "L.logit_irls(X, y; maxit = 2)",
   list(X = cbind(1, xl), y = yl))
cs("logit_anteil", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, 1:6 + 0), y = c(0.1, 0.2, 0.5, 0.4, 0.8, 0.9)))
cs("logit_kollinear", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, xl, 2 * xl), y = yl))
cs("logit_fehler_y", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, 1:3 + 0), y = c(0, 2, 1)))
cs("logit_fehler_na", "sl$.sl_logit_irls(X, y)", "L.logit_irls(X, y)", "L.logit_irls(X, y)", list(X = cbind(1, 1:3 + 0), y = c(0, NA, 1)))

# ── Stineman ──
xs <- cumsum(runif(30, 0.2, 2)); ys <- cumsum(rnorm(30)); xo <- c(xs[1] - 1, seq(xs[1], xs[30], length.out = 77), xs[30] + 0.5, NA, NaN)
cs("stine", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = xs, y = ys, xo = xo))
cs("stine_skaliert_aus", "sl$.sl_stineman_slopes(x, y, scale = FALSE)", "L.stineman_slopes(x, y, scale=False)",
   "L.stineman_slopes(x, y; scale = false)", list(x = xs, y = ys * 1e3))
cs("stine_steigungen", "sl$.sl_stineman_slopes(x, y)", "L.stineman_slopes(x, y)", "L.stineman_slopes(x, y)", list(x = xs, y = ys))
cs("stine_eval", "sl$.sl_stineman_eval(x, y, yp, xo)", "L.stineman_eval(x, y, yp, xo)", "L.stineman_eval(x, y, yp, xo)",
   list(x = 1:5 + 0, y = c(1, 3, 2, 2, 5), yp = c(0, 1, -1, 0, 2), xo = seq(1, 5, by = 0.25)))
cs("stine_n1", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = 2, y = 5, xo = c(1, 2, 3)))
cs("stine_n2", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = c(1, 3), y = c(1, 4), xo = c(1, 1.5, 3)))
cs("stine_konst", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = 1:4 + 0, y = rep(7, 4), xo = c(1.5, 3.2)))
cs("stine_monoton", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)",
   list(x = c(1, 2, 4, 5, 8, 9), y = c(0, 0, 1, 1, 5, 5.1), xo = seq(1, 9, by = 0.5)))
cs("stine_fehler_x", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = c(1, 3, 2), y = 1:3 + 0, xo = 2.5))
cs("stine_fehler_y", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = 1:3 + 0, y = c(1, NA, 3), xo = 2.5))
cs("stine_leer", "sl$.sl_stineman(x, y, xo)", "L.stineman(x, y, xo)", "L.stineman(x, y, xo)", list(x = numeric(0), y = numeric(0), xo = 1))

# ── Glaettungsspline ──
xsp <- rnorm(300, 0, 0.01); ysp <- 2 * xsp + 40 * xsp^2 + rnorm(300, sd = 0.002)
xo <- c(-0.05, seq(min(xsp), max(xsp), length.out = 50), 0.05, NA)
cs("spline_gcv", "f <- sl$.sl_smspline_fit(x, y); list(f, sl$.sl_smspline_predict(f, xo))",
   "f = L.smspline_fit(x, y)\nresult = [f, L.smspline_predict(f, xo)]", "(f = L.smspline_fit(x, y); Any[f, L.smspline_predict(f, xo)])",
   list(x = xsp, y = ysp, xo = xo))
xt <- round(runif(60), 1); yt <- sin(3 * xt) + rnorm(60, sd = 0.1)
cs("spline_bindungen", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = xt, y = yt))
cs("spline_gewichte", "sl$.sl_smspline_fit(x, y, w)", "L.smspline_fit(x, y, w)", "L.smspline_fit(x, y; w = w)",
   list(x = xsp[1:80], y = ysp[1:80], w = runif(80, 0.5, 2)))
cs("spline_lambda", "sl$.sl_smspline_fit(x, y, lambda = 1e-3)", "L.smspline_fit(x, y, lam=1e-3)", "L.smspline_fit(x, y; lambda = 1e-3)",
   list(x = 1:20 + 0, y = sin(1:20 / 3)))
cs("spline_n4", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = c(1, 2, 4, 7), y = c(1, 3, 2, 5)))
cs("spline_linear", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = 1:30 + 0, y = 2 * (1:30) + 1))
xl2 <- rnorm(4000, 0, 0.01)
cs("spline_lang", "f <- sl$.sl_smspline_fit(x, y); list(f$df, f$lambda, f$gcv, sl$.sl_smspline_predict(f, xo))",
   "f = L.smspline_fit(x, y)\nresult = [f['df'], f['lambda'], f['gcv'], L.smspline_predict(f, xo)]",
   "(f = L.smspline_fit(x, y); Any[f[\"df\"], f[\"lambda\"], f[\"gcv\"], L.smspline_predict(f, xo)])",
   list(x = xl2, y = 2 * xl2 + rnorm(4000, sd = 0.002), xo = seq(-0.04, 0.04, by = 0.001)))
cs("spline_fehler_3", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = c(1, 2, 3, 3), y = 1:4 + 0))
cs("spline_fehler_na", "sl$.sl_smspline_fit(x, y)", "L.smspline_fit(x, y)", "L.smspline_fit(x, y)", list(x = c(1, 2, NA, 4, 5), y = 1:5 + 0))
cs("spline_fehler_w", "sl$.sl_smspline_fit(x, y, w)", "L.smspline_fit(x, y, w)", "L.smspline_fit(x, y; w = w)",
   list(x = 1:5 + 0, y = 1:5 + 0, w = c(1, 0, 1, 1, 1)))

# ── Kerndichte ──
cs("kde", "sl$.sl_kde(x)", "L.kde(x)", "L.kde(x)", list(x = rnorm(500)))
cs("kde_bw", "sl$.sl_bw_silverman(x)", "L.bw_silverman(x)", "L.bw_silverman(x)", list(x = rexp(200)))
cs("kde_gewichte", "sl$.sl_kde(x, weights = w, n = 64)", "L.kde(x, weights=w, n=64)", "L.kde(x; weights = w, n = 64)",
   list(x = rnorm(50), w = rep(1 / 50, 50) * runif(50, 0.5, 1.5)))
cs("kde_grenzen", "sl$.sl_kde(x, bw = 0.3, n = 100, from = -1, to = 1)", "L.kde(x, bw=0.3, n=100, from_=-1.0, to=1.0)",
   "L.kde(x; bw = 0.3, n = 100, from = -1.0, to = 1.0)", list(x = rnorm(100)))
cs("kde_binning", "k <- sl$.sl_kde(x); list(k$bw, k$y)", "k = L.kde(x)\nresult = [k['bw'], k['y']]", "(k = L.kde(x); Any[k[\"bw\"], k[\"y\"]])",
   list(x = rnorm(30000)))
cs("kde_konstant", "sl$.sl_kde(x, n = 16)", "L.kde(x, n=16)", "L.kde(x; n = 16)", list(x = rep(2, 10)))
cs("kde_fehler_n1", "sl$.sl_kde(x)", "L.kde(x)", "L.kde(x)", list(x = 3))
cs("kde_fehler_na", "sl$.sl_kde(x)", "L.kde(x)", "L.kde(x)", list(x = c(1, NA, 3)))
cs("kde_fehler_bw", "sl$.sl_kde(x, bw = -1)", "L.kde(x, bw=-1.0)", "L.kde(x; bw = -1.0)", list(x = c(1, 2, 3)))

ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul slc_opt
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Zusatzfaelle der Gleichlaufpruefung (Etappe 9.3, Entwurf C.8/C.9): Optimierer der C-Bibliothek
# slc. Modul "slc_opt": .sl_optim in R, simlev._lib.optim in Python, SimLev.SLib.optim in Julia,
# jeweils mit derselben C-Zielfunktion (.sl_opt_testfn) ueber die Rueckfrage an den Host, dazu der
# direkte C-Weg (sl_minimize), der numerische Gradient und die Fehlertexte. Mit trace = TRUE
# werden alle Auswertungspunkte und Funktionswerte verglichen (Hex-Vergleich der Iterationsfolge).
#
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
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

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul slc_models
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Zusatzfaelle der Gleichlaufpruefung (Etappe 9.4, Entwurf C.8/C.9): Modelle der C-Bibliothek
# slc. Modul "slc_models": GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne in R
# (.sl_*), Python (simlev._lib) und Julia (SimLev.SLib), jeweils mit denselben Eingaben; die
# Bootstrap-Kerne ziehen aus Stroemen bzw. dem globalen Zustand (Hex-Vergleich der Zustaende).
#
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
ref_init("slc_models")

P <- "import math\nimport numpy as np\nimport simlev\nimport simlev._lib as L\n"
J <- "const L = SL.SLib\n"
cs <- function(id, r, py, jl, inputs = list())
  ref_case(id, r = paste0("sl <- asNamespace('SimLev')\n", r), py = paste0(P, py), jl = paste0(J, jl), inputs = inputs)

# ── Daten ───────────────────────────────────────────────────────────────────
sim_garch <- function(n, mu, om, al, ga, be, seed) {
  set.seed(seed); s2 <- om / (1 - al - ga / 2 - be); e <- numeric(n); ep <- 0
  for (t in 1:n) { if (t > 1) s2 <- om + (al + ga * (ep < 0)) * ep^2 + be * s2; ep <- sqrt(s2) * rnorm(1); e[t] <- mu + ep }
  e
}
sim_ms <- function(n, om, al, ga, be, P, seed) {
  set.seed(seed); K <- length(om); hk <- om / (1 - al - ga / 2 - be); s <- 1L; y <- numeric(n)
  for (t in seq_len(n)) {
    if (t > 1) { s <- sample.int(K, 1, prob = P[s, ]); e <- y[t - 1]; hk <- om + (al + ga * (e < 0)) * e^2 + be * hk }
    y[t] <- sqrt(hk[s]) * rnorm(1)
  }
  y
}
I <- list(
  g1 = sim_garch(800, 3e-4, 2e-6, 0.08, 0, 0.9, 1),
  g2 = sim_garch(600, 1e-4, 3e-6, 0.03, 0.10, 0.88, 2),
  ms2 = sim_ms(500, c(2e-6, 2e-5), c(0.02, 0.05), c(0.04, 0.10), c(0.92, 0.85), matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE), 7),
  ms3 = sim_ms(400, c(1e-6, 4e-6, 2e-5), c(0.03, 0.05, 0.08), c(0, 0, 0), c(0.94, 0.90, 0.85),
               matrix(c(0.99, 0.007, 0.003, 0.01, 0.98, 0.01, 0.005, 0.025, 0.97), 3, byrow = TRUE), 1))
set.seed(5)
I$xg <- 0.01 * ((1 - runif(250))^(-0.2) - 1) / 0.2
I$xn <- 0.02 * ((1 - runif(120))^(0.3) - 1) / (-0.3)
I$xe <- rexp(200, 80)
I$xs <- I$xg[1:15]
I$Z <- cbind(rnorm(300), rnorm(300), rnorm(300)); I$Z[, 2] <- 0.6 * I$Z[, 1] + 0.8 * I$Z[, 2]
I$Q <- cor(I$Z)
I$Qbad <- matrix(c(1, 0.99, 0.2, 0.99, 1, 0.9, 0.2, 0.9, 1), 3)
I$X <- cbind(1 + rnorm(300, 4e-4, 0.011), 1 + rnorm(300, 2e-4, 0.006), 1 + rnorm(300, 0, 0.02))
I$reg <- sample(1:3, 300, TRUE)
I$tr <- matrix(c(.9, .05, .05, .1, .8, .1, .2, .2, .6), 3, byrow = TRUE)
I$zb <- rnorm(300); I$Zc <- matrix(rnorm(600), 300)
I$delta <- matrix(c(0, 0.5, -0.3, 0), 2)
I$P2 <- matrix(c(.95, .05, .1, .9), 2, byrow = TRUE)

case3 <- function(id, r, py, jl, inp) cs(id, r = r, py = paste0("result = ", py), jl = paste0("result = ", jl), inputs = I[inp])

# ── GARCH ───────────────────────────────────────────────────────────────────
case3("garch_filter", "sl$.sl_garch11_filter(g1 - 3e-4, 2e-6, 0.08, 0.9, 0.04, 1e-4)",
      "L.garch11_filter(g1 - 3e-4, 2e-6, 0.08, 0.9, 0.04, 1e-4)", "L.garch11_filter(g1 .- 3e-4, 2e-6, 0.08, 0.9, 0.04, 1e-4)", "g1")
case3("garch_nll", "c(sl$.sl_garch11_nll(g1, c(3e-4, 2e-6, 0.08, 0.9)), sl$.sl_garch11_nll(g2, c(1e-4, 3e-6, 0.03, 0.88, 0.1), TRUE, 1e-4))",
      "[L.garch11_nll(g1, [3e-4, 2e-6, 0.08, 0.9]), L.garch11_nll(g2, [1e-4, 3e-6, 0.03, 0.88, 0.1], True, 1e-4)]",
      "[L.garch11_nll(g1, [3e-4, 2e-6, 0.08, 0.9]), L.garch11_nll(g2, [1e-4, 3e-6, 0.03, 0.88, 0.1]; gjr = true, s2_init = 1e-4)]", c("g1", "g2"))
for (nm in c("g1", "g2")) for (gj in c(FALSE, TRUE)) {
  case3(sprintf("garch_fit_%s_%s", nm, if (gj) "gjr" else "s"), sprintf("sl$.sl_garch11_fit(%s, %s)", nm, gj),
        sprintf("L.garch11_fit(%s, %s)", nm, if (gj) "True" else "False"), sprintf("L.garch11_fit(%s; gjr = %s)", nm, tolower(gj)), nm)
  case3(sprintf("fit_garch11_%s_%s", nm, if (gj) "gjr" else "s"), sprintf("sl$.sl_fit_garch11(%s, %s)", nm, gj),
        sprintf("L.fit_garch11(%s, %s)", nm, if (gj) "True" else "False"), sprintf("L.fit_garch11(%s; gjr = %s)", nm, tolower(gj)), nm)
}
case3("fit_garch11_konstant", "sl$.sl_fit_garch11(rep(0.001, 50))", "L.fit_garch11(np.full(50, 0.001))", "L.fit_garch11(fill(0.001, 50))", character(0))
case3("fit_garch11_kurz_momente", "sl$.sl_fit_garch11(g1[1:6])", "L.fit_garch11(g1[:6])", "L.fit_garch11(g1[1:6])", "g1")
case3("fit_garch11_kurz_leise", "sl$.sl_fit_garch11(g1[1:6], quiet = TRUE)", "L.fit_garch11(g1[:6], quiet=True)", "L.fit_garch11(g1[1:6]; quiet = true)", "g1")
case3("garch_fit_err_kurz", "sl$.sl_garch11_fit(g1[1:9])", "L.garch11_fit(g1[:9])", "L.garch11_fit(g1[1:9])", "g1")
case3("garch_fit_err_nan", "sl$.sl_garch11_fit(c(g1[1:20], NaN))", "L.garch11_fit(np.append(g1[:20], math.nan))", "L.garch11_fit(vcat(g1[1:20], NaN))", "g1")

# ── GPD ─────────────────────────────────────────────────────────────────────
for (nm in c("xg", "xn", "xe", "xs"))
  case3(paste0("gpd_", nm), sprintf("list(sl$.sl_gpd_fit(%s), sl$.sl_gpd_pwm(%s), sl$.sl_gpd_nll(%s, 0.01, 0.1), sl$.sl_gpd_nll(%s, 0.01, 0))", nm, nm, nm, nm),
        sprintf("[L.gpd_fit(%s), L.gpd_pwm(%s), L.gpd_nll(%s, 0.01, 0.1), L.gpd_nll(%s, 0.01, 0.0)]", nm, nm, nm, nm),
        sprintf("Any[L.gpd_fit(%s), L.gpd_pwm(%s), L.gpd_nll(%s, 0.01, 0.1), L.gpd_nll(%s, 0.01, 0.0)]", nm, nm, nm, nm), nm)
case3("gpd_nll_traeger", "c(sl$.sl_gpd_nll(xn, 0.001, -0.5), sl$.sl_gpd_nll(xn, 0.01, 1e-12))",
      "[L.gpd_nll(xn, 0.001, -0.5), L.gpd_nll(xn, 0.01, 1e-12)]", "[L.gpd_nll(xn, 0.001, -0.5), L.gpd_nll(xn, 0.01, 1e-12)]", "xn")
case3("gpd_err_wenige", "sl$.sl_gpd_fit(xg[1:5])", "L.gpd_fit(xg[:5])", "L.gpd_fit(xg[1:5])", "xg")
case3("gpd_err_negativ", "sl$.sl_gpd_fit(c(-1, xg[1:20]))", "L.gpd_fit(np.append(-1.0, xg[:20]))", "L.gpd_fit(vcat(-1.0, xg[1:20]))", "xg")
case3("gpd_err_konstant", "sl$.sl_gpd_fit(rep(0.01, 30))", "L.gpd_fit(np.full(30, 0.01))", "L.gpd_fit(fill(0.01, 30))", character(0))

# ── DCC ─────────────────────────────────────────────────────────────────────
case3("dcc_filter", "list(sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, TRUE), sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, FALSE))",
      "[L.dcc_filter(Z, 0.03, 0.95, Q, True), L.dcc_filter(Z, 0.03, 0.95, Q, False)]",
      "Any[L.dcc_filter(Z, 0.03, 0.95, Q, true), L.dcc_filter(Z, 0.03, 0.95, Q, false)]", c("Z", "Q"))
case3("dcc_filter_nicht_pd", "sl$.sl_dcc_filter(Z, 0.03, 0.95, Qbad, TRUE)", "L.dcc_filter(Z, 0.03, 0.95, Qbad, True)",
      "L.dcc_filter(Z, 0.03, 0.95, Qbad, true)", c("Z", "Qbad"))
case3("dcc_fit", "sl$.sl_dcc_fit(Z, Q)", "L.dcc_fit(Z, Q)", "L.dcc_fit(Z, Q)", c("Z", "Q"))
case3("dcc_fit_2", "sl$.sl_dcc_fit(Z[, 1:2], Q[1:2, 1:2])", "L.dcc_fit(Z[:, :2], Q[:2, :2])", "L.dcc_fit(Z[:, 1:2], Q[1:2, 1:2])", c("Z", "Q"))
case3("dcc_err_nan", "sl$.sl_dcc_fit(rbind(Z, NA), Q)", "L.dcc_fit(np.vstack([Z, np.full((1, 3), math.nan)]), Q)",
      "L.dcc_fit(vcat(Z, fill(NaN, 1, 3)), Q)", c("Z", "Q"))

# ── MS-GARCH und HMM ────────────────────────────────────────────────────────
case3("ms_filter", "sl$.sl_ms_garch_filter(ms2, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(.02, .05), P2, c(2/3, 1/3), 1e-4)",
      "L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)",
      "L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)", c("ms2", "P2"))
# 9.6c: Randfälle des gestrichenen Moduls bootstrap_core (früherer Filter .ms_garch_filter), neu gefasst
# für den slc-Filter: K = 3 mit GJR und eine Beobachtung mit Dichte 0 in allen Regimen (loglik = -Inf)
set.seed(11); I$ym <- rnorm(60, 0, 0.01); I$ym0 <- I$ym; I$ym0[20] <- 1
I$P3 <- matrix(c(.9, .05, .05, .1, .8, .1, .02, .08, .9), 3, byrow = TRUE)
case3("ms_filter_K3_gjr", "sl$.sl_ms_garch_filter(ym, c(1e-6, 3e-6, 1e-5), c(.03, .06, .1), c(.95, .9, .8), c(0, .04, .1), P3, c(.5, .3, .2), 1e-4)",
      "L.ms_garch_filter(ym, [1e-6, 3e-6, 1e-5], [.03, .06, .1], [.95, .9, .8], [0, .04, .1], P3, [.5, .3, .2], 1e-4)",
      "L.ms_garch_filter(ym, [1e-6, 3e-6, 1e-5], [.03, .06, .1], [.95, .9, .8], [0, .04, .1], P3, [.5, .3, .2], 1e-4)", c("ym", "P3"))
case3("ms_filter_neginf", "sl$.sl_ms_garch_filter(ym0, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(.02, .05), P2, c(.5, .5), 1e-4)",
      "L.ms_garch_filter(ym0, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [.5, .5], 1e-4)",
      "L.ms_garch_filter(ym0, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [.5, .5], 1e-4)", c("ym0", "P2"))
case3("ms_nll", "c(sl$.sl_ms_garch_nll(c(-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3), ms2, 2, 'gjrGARCH'), sl$.sl_ms_garch_nll(c(-12, -3, 2, -11, -2, 1.5, -4, -3), ms2, 2, 'sGARCH', 1e-4))",
      "[L.ms_garch_nll([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, 'gjrGARCH'), L.ms_garch_nll([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, 'sGARCH', 1e-4)]",
      "[L.ms_garch_nll([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, \"gjrGARCH\"), L.ms_garch_nll([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, \"sGARCH\"; h1 = 1e-4)]", "ms2")
for (cf in list(c("ms2", 2, "sGARCH"), c("ms2", 2, "gjrGARCH"), c("ms3", 3, "sGARCH"), c("ms3", 2, "gjrGARCH"))) {
  id <- sprintf("ms_%s_K%s_%s", cf[1], cf[2], cf[3])
  case3(paste0(id, "_starts"), sprintf("list(sl$.sl_ms_garch_starts(%s, %s, '%s'), sl$.sl_ms_garch_starts(%s, %s, '%s', all = TRUE))", cf[1], cf[2], cf[3], cf[1], cf[2], cf[3]),
        sprintf("[L.ms_garch_starts(%s, %s, '%s'), L.ms_garch_starts(%s, %s, '%s', all=True)]", cf[1], cf[2], cf[3], cf[1], cf[2], cf[3]),
        sprintf("Any[L.ms_garch_starts(%s, %s, \"%s\"), L.ms_garch_starts(%s, %s, \"%s\"; all = true)]", cf[1], cf[2], cf[3], cf[1], cf[2], cf[3]), cf[1])
  case3(paste0(id, "_fit"), sprintf("sl$.sl_ms_garch_fit(%s, %s, '%s')", cf[1], cf[2], cf[3]),
        sprintf("L.ms_garch_fit(%s, %s, '%s')", cf[1], cf[2], cf[3]), sprintf("L.ms_garch_fit(%s, %s, \"%s\")", cf[1], cf[2], cf[3]), cf[1])
}
case3("ms_fitstarts", "sl$.sl_ms_garch_fitstarts(ms2, 2, 'sGARCH', cbind(c(-12, -3, 2, -11, -2, 1.5, -4, -3), c(-13, -2, 3, -10, -2, 2, -5, -4)))",
      "L.ms_garch_fitstarts(ms2, 2, 'sGARCH', np.array([[-12, -3, 2, -11, -2, 1.5, -4, -3], [-13, -2, 3, -10, -2, 2, -5, -4]], dtype=float).T)",
      "L.ms_garch_fitstarts(ms2, 2, \"sGARCH\", [-12.0 -13; -3 -2; 2 3; -11 -10; -2 -2; 1.5 2; -4 -5; -3 -4])", "ms2")
case3("ms_fit_err_K1", "sl$.sl_ms_garch_fit(ms2, 1, 'sGARCH')", "L.ms_garch_fit(ms2, 1, 'sGARCH')", "L.ms_garch_fit(ms2, 1, \"sGARCH\")", "ms2")
case3("ms_fit_err_model", "sl$.sl_ms_garch_fit(ms2, 2, 'eGARCH')", "L.ms_garch_fit(ms2, 2, 'eGARCH')", "L.ms_garch_fit(ms2, 2, \"eGARCH\")", "ms2")
case3("hmm_em", "list(sl$.sl_hmm_em_univ(ms2, 2), sl$.sl_hmm_em_univ(ms3, 3, 10L, 50L, 1e-9))",
      "[L.hmm_em_univ(ms2, 2), L.hmm_em_univ(ms3, 3, 10, 50, 1e-9)]",
      "Any[L.hmm_em_univ(ms2, 2), L.hmm_em_univ(ms3, 3; win = 10, max_iter = 50, tol = 1e-9)]", c("ms2", "ms3"))
case3("hmm_viterbi", "f <- sl$.sl_ms_garch_filter(ms2, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(.02, .05), P2, c(2/3, 1/3), 1e-4); sl$.sl_hmm_viterbi(f$lB, log(P2), log(c(2/3, 1/3)))",
      "L.hmm_viterbi(L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)['lB'], np.log(P2), np.log([2/3, 1/3]))",
      "L.hmm_viterbi(L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)[\"lB\"], log.(P2), log.([2/3, 1/3]))", c("ms2", "P2"))

# ── N1: GJR mit gamma < 0 (alpha + gamma >= 0) und analytischer MS-GARCH-Gradient ─────────────
I$gneg <- sim_garch(1000, 3e-4, 2e-6, 0.10, -0.06, 0.88, 3)
I$msneg <- sim_ms(600, c(2e-6, 2e-5), c(0.08, 0.12), c(-0.05, -0.06), c(0.90, 0.80), matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE), 8)
case3("n1_garch_fit_gneg_gjr", "sl$.sl_garch11_fit(gneg, TRUE)", "L.garch11_fit(gneg, True)", "L.garch11_fit(gneg; gjr = true)", "gneg")
case3("n1_fit_garch11_gneg_gjr", "sl$.sl_fit_garch11(gneg, TRUE)", "L.fit_garch11(gneg, True)", "L.fit_garch11(gneg; gjr = true)", "gneg")
case3("n1_garch_fit_gneg_s", "sl$.sl_garch11_fit(gneg, FALSE)", "L.garch11_fit(gneg, False)", "L.garch11_fit(gneg; gjr = false)", "gneg")
case3("n1_garch_nll_gneg", "c(sl$.sl_garch11_nll(gneg, c(3e-4, 2e-6, 0.1, 0.88, -0.06), TRUE), sl$.sl_garch11_nll(gneg, c(3e-4, 2e-6, 0.1, 0.88, -0.1), TRUE, 1e-4))",
      "[L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.06], True), L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.1], True, 1e-4)]",
      "[L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.06]; gjr = true), L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.1]; gjr = true, s2_init = 1e-4)]", "gneg")
case3("n1_ms_grad", "list(sl$.sl_ms_garch_grad(c(-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3), ms2, 2, 'gjrGARCH'), sl$.sl_ms_garch_grad(c(-12, -3, 2, -11, -2, 1.5, -4, -3), ms2, 2, 'sGARCH', 1e-4), sl$.sl_ms_garch_grad(c(-13, -3, 2, -12, -2, 1.5, -10, -2, 1, -5, -6, -4, -5, -3, -4), ms3, 3, 'sGARCH'))",
      "[L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, 'gjrGARCH'), L.ms_garch_grad([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, 'sGARCH', 1e-4), L.ms_garch_grad([-13, -3, 2, -12, -2, 1.5, -10, -2, 1, -5, -6, -4, -5, -3, -4], ms3, 3, 'sGARCH')]",
      "Any[L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, \"gjrGARCH\"), L.ms_garch_grad([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, \"sGARCH\"; h1 = 1e-4), L.ms_garch_grad([-13, -3, 2, -12, -2, 1.5, -10, -2, 1, -5, -6, -4, -5, -3, -4], ms3, 3, \"sGARCH\")]", c("ms2", "ms3"))
case3("n1_ms_grad_symm_P", "sl$.sl_ms_garch_grad(c(-12, -3, -4, 2, -11, -2, -3, 1.5, -4.6, -4.6), msneg, 2, 'gjrGARCH')",
      "L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4.6, -4.6], msneg, 2, 'gjrGARCH')",
      "L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4.6, -4.6], msneg, 2, \"gjrGARCH\")", "msneg")
case3("n1_ms_grad_inf", "sl$.sl_ms_garch_grad(c(-12, -3, 2, -800, -2, 1.5, -4, -3), ms2, 2, 'sGARCH', 1e-300)",
      "L.ms_garch_grad([-12, -3, 2, -800, -2, 1.5, -4, -3], ms2, 2, 'sGARCH', 1e-300)",
      "L.ms_garch_grad([-12, -3, 2, -800, -2, 1.5, -4, -3], ms2, 2, \"sGARCH\"; h1 = 1e-300)", "ms2")
case3("n1_ms_msneg_K2_gjrGARCH_starts", "sl$.sl_ms_garch_starts(msneg, 2, 'gjrGARCH', all = TRUE)", "L.ms_garch_starts(msneg, 2, 'gjrGARCH', all=True)",
      "L.ms_garch_starts(msneg, 2, \"gjrGARCH\"; all = true)", "msneg")
case3("n1_ms_msneg_K2_gjrGARCH_fit", "sl$.sl_ms_garch_fit(msneg, 2, 'gjrGARCH')", "L.ms_garch_fit(msneg, 2, 'gjrGARCH')", "L.ms_garch_fit(msneg, 2, \"gjrGARCH\")", "msneg")
case3("n1_ms_msneg_K3_gjrGARCH_fit", "sl$.sl_ms_garch_fit(msneg, 3, 'gjrGARCH')", "L.ms_garch_fit(msneg, 3, 'gjrGARCH')", "L.ms_garch_fit(msneg, 3, \"gjrGARCH\")", "msneg")
case3("n1_ms_fitstarts_gjr", "sl$.sl_ms_garch_fitstarts(msneg, 2, 'gjrGARCH', cbind(c(-12, -3, -2.5, 2, -11, -2, -1.5, 1.5, -4, -3)))",
      "L.ms_garch_fitstarts(msneg, 2, 'gjrGARCH', np.array([[-12, -3, -2.5, 2, -11, -2, -1.5, 1.5, -4, -3]], dtype=float).T)",
      "L.ms_garch_fitstarts(msneg, 2, \"gjrGARCH\", reshape([-12.0, -3, -2.5, 2, -11, -2, -1.5, 1.5, -4, -3], :, 1))", "msneg")

# ── N3: analytischer Gradient der GJR-NLL (wie im GJR-Fit) ──────────────────────────────────────
I$gflat <- c(rep(3e-4, 40), I$g1[1:100])
case3("n3_garch_grad", "list(sl$.sl_garch11_grad(c(3e-4, -13.1, -3.2, -4.5, 2), gneg), sl$.sl_garch11_grad(c(1e-4, -12.7, -4, -2.5, 2.2), g2, TRUE, 1e-4), sl$.sl_garch11_grad(c(1e-3, -11.5, 1, 1.5, -3), g1))",
      "[L.garch11_grad([3e-4, -13.1, -3.2, -4.5, 2], gneg), L.garch11_grad([1e-4, -12.7, -4, -2.5, 2.2], g2, True, 1e-4), L.garch11_grad([1e-3, -11.5, 1, 1.5, -3], g1)]",
      "Any[L.garch11_grad([3e-4, -13.1, -3.2, -4.5, 2], gneg), L.garch11_grad([1e-4, -12.7, -4, -2.5, 2.2], g2; gjr = true, s2_init = 1e-4), L.garch11_grad([1e-3, -11.5, 1, 1.5, -3], g1)]", c("gneg", "g2", "g1"))
case3("n3_garch_grad_untergrenze", "sl$.sl_garch11_grad(c(3e-4, -40, -6, -5, -4), gflat, TRUE, 1e-13)",
      "L.garch11_grad([3e-4, -40, -6, -5, -4], gflat, True, 1e-13)", "L.garch11_grad([3e-4, -40, -6, -5, -4], gflat; gjr = true, s2_init = 1e-13)", "gflat")
case3("n3_garch_grad_inf", "sl$.sl_garch11_grad(c(3e-4, 800, -3, -4, 2), gneg)", "L.garch11_grad([3e-4, 800, -3, -4, 2], gneg)",
      "L.garch11_grad([3e-4, 800, -3, -4, 2], gneg)", "gneg")
case3("n3_garch_grad_err_nan", "sl$.sl_garch11_grad(c(3e-4, -13, -3, -4, 2), c(g1[1:20], NaN))", "L.garch11_grad([3e-4, -13, -3, -4, 2], np.append(g1[:20], math.nan))",
      "L.garch11_grad([3e-4, -13, -3, -4, 2], vcat(g1[1:20], NaN))", "g1")

# ── N4: derselbe Gradient für sGARCH (theta = (mu, log omega, a, b)); bis N3 Fehler (Fall n3_garch_grad_err_sgarch entfällt)
case3("n4_garch_grad_s", "list(sl$.sl_garch11_grad(c(3e-4, -13.1, -2.6, 2.3), gneg, FALSE), sl$.sl_garch11_grad(c(1e-4, -12.7, -4, 2.2), g2, FALSE, 1e-4), sl$.sl_garch11_grad(c(1e-3, -11.5, 1, -3), g1, FALSE))",
      "[L.garch11_grad([3e-4, -13.1, -2.6, 2.3], gneg, False), L.garch11_grad([1e-4, -12.7, -4, 2.2], g2, False, 1e-4), L.garch11_grad([1e-3, -11.5, 1, -3], g1, False)]",
      "Any[L.garch11_grad([3e-4, -13.1, -2.6, 2.3], gneg; gjr = false), L.garch11_grad([1e-4, -12.7, -4, 2.2], g2; gjr = false, s2_init = 1e-4), L.garch11_grad([1e-3, -11.5, 1, -3], g1; gjr = false)]", c("gneg", "g2", "g1"))
case3("n4_garch_grad_s_untergrenze", "sl$.sl_garch11_grad(c(3e-4, -40, -6, -4), gflat, FALSE, 1e-13)",
      "L.garch11_grad([3e-4, -40, -6, -4], gflat, False, 1e-13)", "L.garch11_grad([3e-4, -40, -6, -4], gflat; gjr = false, s2_init = 1e-13)", "gflat")
case3("n4_garch_grad_s_inf", "sl$.sl_garch11_grad(c(3e-4, 800, -3, 2), gneg, FALSE)", "L.garch11_grad([3e-4, 800, -3, 2], gneg, False)",
      "L.garch11_grad([3e-4, 800, -3, 2], gneg; gjr = false)", "gneg")
case3("n4_garch_grad_s_err_nan", "sl$.sl_garch11_grad(c(3e-4, -13, -3, 2), c(g1[1:20], NaN), FALSE)", "L.garch11_grad([3e-4, -13, -3, 2], np.append(g1[:20], math.nan), False)",
      "L.garch11_grad([3e-4, -13, -3, 2], vcat(g1[1:20], NaN); gjr = false)", "g1")
case3("n4_garch_fit_gflat_s", "sl$.sl_garch11_fit(gflat, FALSE)", "L.garch11_fit(gflat, False)", "L.garch11_fit(gflat; gjr = false)", "gflat")
case3("n4_fit_garch11_gneg_s", "sl$.sl_fit_garch11(gneg, FALSE)", "L.fit_garch11(gneg, False)", "L.fit_garch11(gneg; gjr = false)", "gneg")
# ── N6: sGARCH-Fit mit zweitem Start bei Randlösung alpha < 0.01 (bis 1.1.0 am Rand beta -> 1, LL um 1,29 kleiner);
#        MS-GARCH mit mehreren Threads (Ergebnis gleich dem Lauf mit einem Thread, ms_ms2_K2_*_fit)
I$grand <- sim_garch(600, 3e-4, 2e-5, 0.03, 0, 0.6, 4)
case3("n6_garch_fit_rand_s", "sl$.sl_garch11_fit(grand, FALSE)", "L.garch11_fit(grand, False)", "L.garch11_fit(grand; gjr = false)", "grand")
case3("n6_fit_garch11_rand_s", "sl$.sl_fit_garch11(grand, FALSE)", "L.fit_garch11(grand, False)", "L.fit_garch11(grand; gjr = false)", "grand")
case3("n6_ms_fit_threads", "list(sl$.sl_ms_garch_fit(ms2, 2, 'sGARCH', cores = 3), sl$.sl_ms_garch_fit(ms2, 2, 'gjrGARCH', cores = 2), sl$.sl_ms_garch_fit(ms3, 3, 'sGARCH', cores = 64))",
      "[L.ms_garch_fit(ms2, 2, 'sGARCH', cores=3), L.ms_garch_fit(ms2, 2, 'gjrGARCH', cores=2), L.ms_garch_fit(ms3, 3, 'sGARCH', cores=64)]",
      "Any[L.ms_garch_fit(ms2, 2, \"sGARCH\"; cores = 3), L.ms_garch_fit(ms2, 2, \"gjrGARCH\"; cores = 2), L.ms_garch_fit(ms3, 3, \"sGARCH\"; cores = 64)]", c("ms2", "ms3"))
case3("n6_ms_fit_threads_ungueltig", "list(sl$.sl_ms_garch_fit(ms2, 2, 'sGARCH', cores = 0), sl$.sl_ms_garch_fit(ms2, 2, 'sGARCH', cores = NA), sl$.sl_ms_garch_fit(ms2, 2, 'sGARCH', cores = 2.7))",
      "[L.ms_garch_fit(ms2, 2, 'sGARCH', cores=0), L.ms_garch_fit(ms2, 2, 'sGARCH', cores=math.nan), L.ms_garch_fit(ms2, 2, 'sGARCH', cores=2.7)]",
      "Any[L.ms_garch_fit(ms2, 2, \"sGARCH\"; cores = 0), L.ms_garch_fit(ms2, 2, \"sGARCH\"; cores = NaN), L.ms_garch_fit(ms2, 2, \"sGARCH\"; cores = 2.7)]", "ms2")

# ── Bootstrap-Kerne (Strom aus Seed; danach Zustand als Hex) ──────────────────
bc <- function(id, seed, r, py, jl, inp = character(0))
  cs(id, r = sprintf("s <- sl$.sl_stream(%d); list(%s, sl$.sl_state_hex(s))", seed, r),
     py = sprintf("s = L.Stream(%d)\nresult = [%s, L.state_hex(s)]", seed, py),
     jl = sprintf("s = L.Stream(%d)\nresult = Any[%s, L.state_hex(s)]", seed, jl), inputs = I[inp])
bc("boot_iid", 1, "sl$.sl_boot_idx_iid(300, 500, stream = s)", "L.boot_idx_iid(300, 500, stream=s)", "L.boot_idx_iid(300, 500; stream = s)")
bc("boot_block", 2, "sl$.sl_boot_idx_block(300, 500, 20, FALSE, stream = s), sl$.sl_boot_idx_block(300, 77, 13, TRUE, stream = s)",
   "L.boot_idx_block(300, 500, 20, False, stream=s), L.boot_idx_block(300, 77, 13, True, stream=s)",
   "L.boot_idx_block(300, 500, 20, false; stream = s), L.boot_idx_block(300, 77, 13, true; stream = s)")
bc("boot_stationary", 3, "sl$.sl_boot_idx_stationary(300, 1000, 15.5, stream = s), sl$.sl_boot_idx_stationary(50, 30, 1, stream = s)",
   "L.boot_idx_stationary(300, 1000, 15.5, stream=s), L.boot_idx_stationary(50, 30, 1, stream=s)",
   "L.boot_idx_stationary(300, 1000, 15.5; stream = s), L.boot_idx_stationary(50, 30, 1; stream = s)")
bc("boot_regime", 4, "sl$.sl_boot_idx_regime(reg, tr, 400, stream = s)", "L.boot_idx_regime(reg, tr, 400, stream=s)",
   "L.boot_idx_regime(reg, tr, 400; stream = s)", c("reg", "tr"))
bc("boot_tails", 5, "sl$.sl_boot_idx_tails(500, 0.05, 0.07, 11:280, 1:10, 281:300, stream = s)",
   "L.boot_idx_tails(500, 0.05, 0.07, np.arange(11, 281), np.arange(1, 11), np.arange(281, 301), stream=s)",
   "L.boot_idx_tails(500, 0.05, 0.07, 11:280, 1:10, 281:300; stream = s)")
bc("boot_wild", 6, "sl$.sl_boot_wild(X, 0L, stream = s), sl$.sl_boot_wild(X, 1L, stream = s), sl$.sl_boot_wild(X, 2L, stream = s)",
   "L.boot_wild(X, 0, stream=s), L.boot_wild(X, 1, stream=s), L.boot_wild(X, 2, stream=s)",
   "L.boot_wild(X, 0; stream = s), L.boot_wild(X, 1; stream = s), L.boot_wild(X, 2; stream = s)", "X")
bc("boot_reset", 7, "sl$.sl_boot_reset(X, 0.02, stream = s)", "L.boot_reset(X, 0.02, stream=s)", "L.boot_reset(X, 0.02; stream = s)", "X")
bc("boot_evt", 8, "sl$.sl_boot_evt(X, 0L, 400L, 0.05, 0.98, 0.006, 0.2, 1:15, 0.05, 1.02, 0.005, 0, 286:300, 16:285, stream = s)",
   "L.boot_evt(X, 0, 400, 0.05, 0.98, 0.006, 0.2, np.arange(1, 16), 0.05, 1.02, 0.005, 0, np.arange(286, 301), np.arange(16, 286), stream=s)",
   "L.boot_evt(X, 0, 400, 0.05, 0.98, 0.006, 0.2, 1:15, 0.05, 1.02, 0.005, 0, 286:300, 16:285; stream = s)", "X")
bc("boot_garch", 9, "sl$.sl_boot_garch(500L, 0L, 3L, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, 1:300, c(1L, 2L), c(1e-4, 0), c(1e-6, 3e-6), c(.05, .1), c(.9, .85), c(TRUE, FALSE), c(5e-5, 2e-4), Zc, stream = s)",
   "L.boot_garch(500, 0, 3, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, np.arange(1, 301), [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [True, False], [5e-5, 2e-4], Zc, stream=s)",
   "L.boot_garch(500, 0, 3, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, 1:300, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [true, false], [5e-5, 2e-4], Zc; stream = s)", c("zb", "Zc"))
bc("boot_garch_ohne_kopplung", 19, "sl$.sl_boot_garch(100L, 0L, 1L, 3e-4, 2e-6, 0.08, 0.9, 0, 1e-4, zb, 1:300, integer(0), numeric(0), numeric(0), numeric(0), numeric(0), logical(0), numeric(0), NULL, stream = s)",
   "L.boot_garch(100, 0, 1, 3e-4, 2e-6, 0.08, 0.9, 0, 1e-4, zb, np.arange(1, 301), [], [], [], [], [], [], [], None, stream=s)",
   "L.boot_garch(100, 0, 1, 3e-4, 2e-6, 0.08, 0.9, 0, 1e-4, zb, 1:300, Int[], Float64[], Float64[], Float64[], Float64[], Bool[], Float64[], nothing; stream = s)", "zb")
bc("boot_ms_garch", 10, "sl$.sl_boot_ms_garch(400L, 0L, 3L, 2L, c(5e-4, -1e-3), c(1e-6, 5e-6), c(.05, .1), c(.9, .85), c(0, .1), c(0, .05), c(0, .1), matrix(c(.97, .05, .03, .95), 2), delta, c(1e-4, 4e-4), c(.6, .4), list(1:200, 201:300), zb, c(1L, 2L), c(1e-4, 0), c(1e-6, 3e-6), c(.05, .1), c(.9, .85), c(TRUE, FALSE), c(5e-5, 2e-4), Zc, stream = s)",
   "L.boot_ms_garch(400, 0, 3, 2, [5e-4, -1e-3], [1e-6, 5e-6], [.05, .1], [.9, .85], [0, .1], [0, .05], [0, .1], np.array([[.97, .03], [.05, .95]]), delta, [1e-4, 4e-4], [.6, .4], [np.arange(1, 201), np.arange(201, 301)], zb, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [True, False], [5e-5, 2e-4], Zc, stream=s)",
   "L.boot_ms_garch(400, 0, 3, 2, [5e-4, -1e-3], [1e-6, 5e-6], [.05, .1], [.9, .85], [0, .1], [0, .05], [0, .1], [.97 .03; .05 .95], delta, [1e-4, 4e-4], [.6, .4], [1:200, 201:300], zb, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [true, false], [5e-5, 2e-4], Zc; stream = s)",
   c("delta", "zb", "Zc"))
cs("boot_global", r = "simlev_seed(11); list(sl$.sl_boot_idx_iid(50, 20), sl$.sl_boot_wild(X[1:10, ], 2L), sl$.sl_state_hex())",
   py = "simlev.simlev_seed(11)\nresult = [L.boot_idx_iid(50, 20), L.boot_wild(X[:10, :], 2), L.state_hex()]",
   jl = "simlev_seed(11)\nresult = Any[L.boot_idx_iid(50, 20), L.boot_wild(X[1:10, :], 2), L.state_hex()]", inputs = I["X"])
cs("boot_stroeme", r = "u <- sl$.sl_streams(sl$.sl_stream(12), 3); lapply(u, function(s) sl$.sl_boot_idx_stationary(100, 30, 5, stream = s))",
   py = "u = L.streams(L.Stream(12), 3)\nresult = [L.boot_idx_stationary(100, 30, 5, stream=s) for s in u]",
   jl = "u = L.streams(L.Stream(12), 3)\nresult = Any[L.boot_idx_stationary(100, 30, 5; stream = s) for s in u]")
bc("boot_err_block", 13, "sl$.sl_boot_idx_block(10, 5, 20, FALSE, stream = s)", "L.boot_idx_block(10, 5, 20, False, stream=s)",
   "L.boot_idx_block(10, 5, 20, false; stream = s)")
bc("boot_err_wild", 14, "sl$.sl_boot_wild(X, 3L, stream = s)", "L.boot_wild(X, 3, stream=s)", "L.boot_wild(X, 3; stream = s)", "X")
bc("boot_err_index", 15, "sl$.sl_boot_garch(10L, 0L, 1L, 0, 1e-6, 0.1, 0.8, 0, 1e-4, zb, c(1L, 400L), integer(0), numeric(0), numeric(0), numeric(0), numeric(0), logical(0), numeric(0), NULL, stream = s)",
   "L.boot_garch(10, 0, 1, 0, 1e-6, 0.1, 0.8, 0, 1e-4, zb, [1, 400], [], [], [], [], [], [], [], None, stream=s)",
   "L.boot_garch(10, 0, 1, 0, 1e-6, 0.1, 0.8, 0, 1e-4, zb, [1, 400], Int[], Float64[], Float64[], Float64[], Float64[], Bool[], Float64[], nothing; stream = s)", "zb")
case3("boot_helfer", "v <- sl$.sl_rolling_vol(X[, 1], 21L); list(v, sl$.sl_rolling_vol(X[1:5, 2], 10L), sl$.sl_assign_regimes(v, c(0, 0.009, 0.0115, Inf)), sl$.sl_estimate_trans_mat(reg, 3L, 0.1))",
      "[L.rolling_vol(X[:, 0], 21), L.rolling_vol(X[:5, 1], 10), L.assign_regimes(L.rolling_vol(X[:, 0], 21), [0.0, 0.009, 0.0115, math.inf]), L.estimate_trans_mat(reg, 3, 0.1)]",
      "Any[L.rolling_vol(X[:, 1], 21), L.rolling_vol(X[1:5, 2], 10), L.assign_regimes(L.rolling_vol(X[:, 1], 21), [0.0, 0.009, 0.0115, Inf]), L.estimate_trans_mat(reg, 3, 0.1)]",
      c("X", "reg"))

# ── N5: GPD und DCC mit analytischem Gradienten, Backcast-Zielfunktion in C, Kendall ganzzahlig ─────
set.seed(55)
I$xe <- 0.01 * rexp(200)                                 # xi nahe 0
I$bx <- rnorm(240, 3e-4, 0.01); I$bx[c(1, 50)] <- NA
I$bc1 <- -2 / 100 / 360 * rep(1, 240); I$bc2 <- 0.5 / 100 / 365 * rep(1, 240)
I$bsp <- rep(1 / 100 / 360, 240); I$bdr <- rep(1 / 100 / 365, 240)
I$bpos <- sort(sample(240, 180)); I$bpos[1] <- 1L
I$blogp <- (log(50) + cumsum(log1p(2.02 * ifelse(is.na(I$bx), 0, I$bx) - 3e-5 + rnorm(240, 0, 3e-4))))[I$bpos]
I$breg <- I$bc1 + 2 * I$bx                               # Basis eines Regressionsmodells (NA bleibt)
I$kx <- c(1, 2, 2, 3, 3, 3, 4, 5, 5, 6); I$ky <- c(2, 1, 2, 5, 3, 3, 4, 6, 5, 5)
case3("n5_gpd_fit_xi0", "list(sl$.sl_gpd_fit(xe), sl$.sl_gpd_fit(xn))", "[L.gpd_fit(xe), L.gpd_fit(xn)]", "Any[L.gpd_fit(xe), L.gpd_fit(xn)]", c("xe", "xn"))
case3("n5_dcc_fit_rueckfall", "sl$.sl_dcc_fit(Z, Qbad)", "L.dcc_fit(Z, Qbad)", "L.dcc_fit(Z, Qbad)", c("Z", "Qbad"))
bcp <- function(o, l, h, lang) {
  tup <- if (lang == "r") "list(bx, bc1, bc2, 2, bsp, bdr, bpos, blogp, c(%dL, %dL, %dL), 0.4)" else "(bx, bc1, bc2, 2.0, bsp, bdr, bpos, blogp, (%d, %d, %d), 0.4)"
  sprintf(tup, o, l, h)
}
bin <- c("bx", "bc1", "bc2", "bsp", "bdr", "bpos", "blogp")
for (v in list(c(1, 1, 1), c(1, 2, 1), c(2, 1, 5), c(3, 1, 2), c(1, 3, 1), c(2, 4, 1), c(1, 5, 1))) {
  nm <- sprintf("n5_backcast_obj_%d%d%d", v[1], v[2], v[3])
  case3(nm, sprintf("list(sl$.sl_backcast_obj(%s, c(0.5, 0.2, 1.01), 1:3, TRUE), sl$.sl_backcast_obj(%s, c(-1, 0, 1), c(2L, 1L), TRUE))", bcp(v[1], v[2], v[3], "r"), bcp(v[1], v[2], v[3], "r")),
        sprintf("[L.backcast_obj(%s, [0.5, 0.2, 1.01], [1, 2, 3], True), L.backcast_obj(%s, [-1.0, 0.0, 1.0], [2, 1], True)]", bcp(v[1], v[2], v[3], "py"), bcp(v[1], v[2], v[3], "py")),
        sprintf("Any[L.backcast_obj(%s, [0.5, 0.2, 1.01], [1, 2, 3]; grad = true), L.backcast_obj(%s, [-1.0, 0.0, 1.0], [2, 1]; grad = true)]", bcp(v[1], v[2], v[3], "jl"), bcp(v[1], v[2], v[3], "jl")), bin)
}
for (v in list(c(1, 1, 1), c(2, 2, 3), c(3, 1, 1))) {
  nm <- sprintf("n5_backcast_fit_%d%d%d", v[1], v[2], v[3])
  case3(nm, sprintf("list(sl$.sl_backcast_fit(%s, c(0, 0, 1), 1:3, c(-10, -5, 0.5), c(10, 10, 1.5)), sl$.sl_backcast_fit(%s, c(0, 0.4, 1), c(1L, 3L), c(-10, 0.5), c(10, 1.5)))", bcp(v[1], v[2], v[3], "r"), bcp(v[1], v[2], v[3], "r")),
        sprintf("[L.backcast_fit(%s, [0.0, 0.0, 1.0], [1, 2, 3], [-10.0, -5.0, 0.5], [10.0, 10.0, 1.5]), L.backcast_fit(%s, [0.0, 0.4, 1.0], [1, 3], [-10.0, 0.5], [10.0, 1.5])]", bcp(v[1], v[2], v[3], "py"), bcp(v[1], v[2], v[3], "py")),
        sprintf("Any[L.backcast_fit(%s, [0.0, 0.0, 1.0], [1, 2, 3], [-10.0, -5.0, 0.5], [10.0, 10.0, 1.5]), L.backcast_fit(%s, [0.0, 0.4, 1.0], [1, 3], [-10.0, 0.5], [10.0, 1.5])]", bcp(v[1], v[2], v[3], "jl"), bcp(v[1], v[2], v[3], "jl")), bin)
}
case3("n5_backcast_fit_regression", "sl$.sl_backcast_fit(list(NULL, breg, NULL, 2, bsp, bdr, bpos, blogp, c(1L, 1L, 1L), 0.5), c(0, 0, 1), 1:2, c(-10, -5), c(10, 10))",
      "L.backcast_fit((None, breg, None, 2.0, bsp, bdr, bpos, blogp, (1, 1, 1), 0.5), [0.0, 0.0, 1.0], [1, 2], [-10.0, -5.0], [10.0, 10.0])",
      "L.backcast_fit((nothing, breg, nothing, 2.0, bsp, bdr, bpos, blogp, (1, 1, 1), 0.5), [0.0, 0.0, 1.0], [1, 2], [-10.0, -5.0], [10.0, 10.0])", c(bin, "breg"))
case3("n5_backcast_err_pos", "sl$.sl_backcast_obj(list(bx, bc1, bc2, 2, bsp, bdr, rev(bpos), blogp, c(1L, 1L, 1L), 0.5), c(0, 0, 1), 1L, TRUE)",
      "L.backcast_obj((bx, bc1, bc2, 2.0, bsp, bdr, bpos[::-1], blogp, (1, 1, 1), 0.5), [0.0, 0.0, 1.0], [1], True)",
      "L.backcast_obj((bx, bc1, bc2, 2.0, bsp, bdr, reverse(bpos), blogp, (1, 1, 1), 0.5), [0.0, 0.0, 1.0], [1]; grad = true)", bin)
cs("n5_kendall", r = "c(sl$.kendall_tau_core(kx, ky), sl$.kendall_tau_core(kx, rev(ky)), sl$.kendall_tau_core(c(1, 1, 1), c(1, 2, 3)), sl$.kendall_tau_core(1:2 + 0, c(2, 1)), sl$.kendall_tau_core(xg[1:200], xg[51:250]))",
   py = "import simlev._dependence_core as DC\nresult = [DC.kendall_tau_core(kx, ky), DC.kendall_tau_core(kx, ky[::-1]), DC.kendall_tau_core(np.array([1.0, 1, 1]), np.array([1.0, 2, 3])), DC.kendall_tau_core(np.array([1.0, 2]), np.array([2.0, 1])), DC.kendall_tau_core(xg[:200], xg[50:250])]",
   jl = "DC = SL.DependenceCore\nresult = Any[DC.kendall_tau_core(kx, ky), DC.kendall_tau_core(kx, reverse(ky)), DC.kendall_tau_core([1.0, 1, 1], [1.0, 2, 3]), DC.kendall_tau_core([1.0, 2], [2.0, 1]), DC.kendall_tau_core(xg[1:200], xg[51:250])]",
   inputs = I[c("kx", "ky", "xg")])

ref_done()

ref_schreiben()
