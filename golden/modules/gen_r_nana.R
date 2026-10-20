# Referenzfälle: NA/NaN-Kombinationen in den long-double-Kumulationen von R
# (sum, mean, prod, cumsum, cumprod, cummax, cummin, var, sd, colSums, rowSums,
# colMeans, rowMeans – je mit und ohne na.rm). Auf x86-64 entscheidet die
# x87-Regel für zwei NaN (ruhiges NaN schlägt signalisierendes Speicher-NA,
# sonst größere Mantisse), ob NA oder NaN herauskommt; cumsum/cumprod/cummax/
# cummin setzen das Ergebnis über handleNaN (cum.c).
# Python bildet die x87-Regel in simlev._rnum._x87_nan bzw. handleNaN nach (NA = NA_REAL).
source("golden/modules/ref_tools.R"); ref_init("r_nana")

v5 <- c(2, NA_real_, NaN, Inf, -Inf)
v3 <- c(-1.5, NA_real_, NaN)
comb <- function(v, k) {
  g <- as.matrix(expand.grid(rep(list(seq_along(v)), k)))
  lapply(seq_len(nrow(g)), function(i) v[g[i, ]])
}
xs <- c(comb(v5, 1), comb(v5, 2), comb(v5, 3), comb(v3, 4),
        list(c(1, NaN, 3, NA), c(1, NA, 3, NaN), c(0, Inf, NA), c(0, NA, Inf), c(Inf, 0, NaN, NA),
             c(1e308, 1e308, NA), c(1e308, 1e308, NaN), c(-1e308, -1e308, NA, NaN)))
ms <- c(lapply(comb(v3, 4), matrix, nrow = 2),
        lapply(comb(v5, 3), matrix, nrow = 3), lapply(comb(v5, 3), matrix, nrow = 1),
        list(matrix(c(NaN, NA, NA, NaN, 1, NaN), 2), matrix(c(Inf, -Inf, NA, NaN, NA, Inf), 3)))

P <- "import numpy as np\nfrom simlev._r import base as B\nwith np.errstate(all='ignore'):\n    "
J <- "B = SL.RBase\n"
vf <- function(id, rf, pyf, jlf) {
  ref_case(id, sprintf("lapply(xs, %s)", rf),
           paste0(P, sprintf("result = [%s for x in xs]", pyf)),
           inputs = list(xs = xs),
           jl = paste0(J, sprintf("result = Any[%s for x in (vcat(x) for x in xs)]", jlf)))
}
vf("sum", "sum", "B.r_sum(x)", "B.r_sum(x)")
vf("sum_narm", "sum, na.rm = TRUE", "B.r_sum(x, na_rm=True)", "B.r_sum(x; na_rm = true)")
vf("mean", "mean", "B.r_mean(x)", "B.r_mean(x)")
vf("mean_narm", "mean, na.rm = TRUE", "B.r_mean(x, na_rm=True)", "B.r_mean(x; na_rm = true)")
vf("mean_all", "mean", "B.mean(x)", "B.mean(x)")
vf("prod", "prod", "B.r_prod(x)", "B.r_prod(x)")
vf("prod_narm", "prod, na.rm = TRUE", "B.r_prod(x, na_rm=True)", "B.r_prod(x; na_rm = true)")
vf("cumsum", "cumsum", "B.r_cumsum(x)", "B.r_cumsum(x)")
vf("cumprod", "cumprod", "B.cumprod(x)", "B.r_cumprod(x)")
vf("cumprod_engine", "cumprod", "simlev._rnum.r_cumprod(x)", "SL.r_cumprod(x)")
vf("cummax", "cummax", "B.cummax(x)", "B.r_cummax(x)")
vf("cummin", "cummin", "B.cummin(x)", "B.r_cummin(x)")
vf("var", "var", "B.r_var(x)", "B.r_var(x)")
vf("var_narm", "var, na.rm = TRUE", "B.r_var(x, na_rm=True)", "B.r_var(x; na_rm = true)")
vf("sd", "sd", "B.r_sd(x)", "B.r_sd(x)")
vf("sd_narm", "sd, na.rm = TRUE", "B.r_sd(x, na_rm=True)", "B.r_sd(x; na_rm = true)")

mf <- function(id, rf, narm) {
  ra <- if (narm) ", na.rm = TRUE" else ""
  pa <- if (narm) ", na_rm=True" else ""
  ja <- if (narm) "; na_rm = true" else ""
  ref_case(id, sprintf("lapply(ms, %s%s)", rf, ra),
           paste0(P, sprintf("result = [B.%s(m%s) for m in ms]", rf, pa)),
           inputs = list(ms = ms),
           jl = paste0(J, sprintf("result = Any[B.%s(m%s) for m in ms]", rf, ja)))
}
for (f in c("colSums", "rowSums", "colMeans", "rowMeans")) {
  mf(f, f, FALSE)
  mf(paste0(f, "_narm"), f, TRUE)
}
ref_case("rowsums_engine", "lapply(ms, function(m) rowSums(m))",
         paste0(P, "result = [simlev._rnum.r_rowsums(np.asarray(m, dtype=float)) for m in ms]"),
         inputs = list(ms = ms),
         jl = paste0(J, "result = Any[SL.r_rowsums([m[:, j] for j in 1:size(m, 2)]) for m in ms]"))
ref_done()
