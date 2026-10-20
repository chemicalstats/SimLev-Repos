# Referenzfälle für simlev._r.linalg (R-Matrixprodukte, LAPACK/LINPACK-Pfade).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_r_linalg.R
source("golden/modules/ref_tools.R")
ref_init("r_linalg")

HDR <- "import simlev._r.linalg as la\n"
JHDR <- "const la = SL.RLinalg\n"
cs <- function(id, r, py, inputs = list(), jl = NULL, ...)
  ref_case(id, r = r, py = paste0(HDR, py), inputs = inputs, jl = if (is.null(jl)) NULL else paste0(JHDR, jl), ...)

set.seed(23)
A <- matrix(rnorm(35), 7, 5); B <- matrix(rnorm(20), 5, 4); v5 <- rnorm(5); v7 <- rnorm(7)
Ann <- A; Ann[2, 3] <- NaN; Ainf <- A; Ainf[4, 1] <- Inf
Anm <- `dimnames<-`(A, list(paste0("r", 1:7), paste0("c", 1:5)))
Bnm <- `dimnames<-`(B, list(paste0("c", 1:5), paste0("k", 1:4)))
G <- matrix(rnorm(200 * 70), 200, 70)
S4 <- crossprod(matrix(rnorm(24), 6, 4)); S70 <- crossprod(G) / 200 + diag(70)
Sq <- matrix(rnorm(36), 6, 6); Sq70 <- matrix(rnorm(4900), 70, 70)
Sing <- cbind(Sq[, 1:5], Sq[, 1] + Sq[, 2])
Z <- matrix(0, 3, 3)

## ── %*% / crossprod / tcrossprod / outer ────────────────────────────────
cs("matprod_mm", "A %*% B", "result = la.matprod(A, B)", list(A = A, B = B), jl = "result = la.matprod(A, B)")
cs("matprod_mv", "A %*% v", "result = la.matprod(A, v)", list(A = A, v = v5), jl = "result = la.matprod(A, v)")
cs("matprod_vm", "v %*% A", "result = la.matprod(v, A)", list(A = A, v = v7), jl = "result = la.matprod(v, A)")
cs("matprod_vv", "v %*% v", "result = la.matprod(v, v)", list(v = v5), jl = "result = la.matprod(v, v)")
cs("matprod_vv_outer", "v %*% t(w)", "result = la.matprod(v.reshape(-1, 1), w.reshape(1, -1))", list(v = v5, w = v7), jl = "result = la.matprod(reshape(v, :, 1), reshape(w, 1, :))")
cs("matprod_nan", "A %*% B", "result = la.matprod(A, B)", list(A = Ann, B = B), jl = "result = la.matprod(A, B)")
cs("matprod_inf", "A %*% B", "result = la.matprod(A, B)", list(A = Ainf, B = B), jl = "result = la.matprod(A, B)")
cs("matprod_names", "A %*% B", "result = la.matprod(A, B)", list(A = Anm, B = Bnm), jl = "result = la.matprod(A, B)")
cs("matprod_big", "G %*% t(G[1:9, ])", "result = la.matprod(G, G[:9].T)", list(G = G), jl = "result = la.matprod(G, permutedims(G[1:9, :]))")
cs("matprod_err", "A %*% A", "result = la.matprod(A, A)", list(A = A), jl = "result = la.matprod(A, A)")
cs("matprod_empty", "dim(matrix(0, 3, 0) %*% matrix(0, 0, 2))", "result = list(la.matprod(np.zeros((3, 0)), np.zeros((0, 2))).shape)", jl = "result = collect(size(la.matprod(zeros(3, 0), zeros(0, 2))))")
cs("crossprod_x", "crossprod(A)", "result = la.crossprod(A)", list(A = A), jl = "result = la.crossprod(A)")
cs("crossprod_xy", "crossprod(A, v)", "result = la.crossprod(A, v)", list(A = A, v = v7), jl = "result = la.crossprod(A, v)")
cs("crossprod_names", "crossprod(A)", "result = la.crossprod(A)", list(A = Anm), jl = "result = la.crossprod(A)")
cs("crossprod_nan", "crossprod(A)", "result = la.crossprod(A)", list(A = Ann), jl = "result = la.crossprod(A)")
cs("crossprod_big", "crossprod(G)", "result = la.crossprod(G)", list(G = G), jl = "result = la.crossprod(G)")
cs("crossprod_vec", "crossprod(v)", "result = la.crossprod(v)", list(v = v7), jl = "result = la.crossprod(v)")
cs("tcrossprod_x", "tcrossprod(A)", "result = la.tcrossprod(A)", list(A = A), jl = "result = la.tcrossprod(A)")
cs("tcrossprod_xy", "tcrossprod(A, B[1:3, ])", "result = la.tcrossprod(A, B[:3])", list(A = A, B = t(B)), jl = "result = la.tcrossprod(A, B[1:3, :])")
cs("tcrossprod_inf", "tcrossprod(A)", "result = la.tcrossprod(A)", list(A = Ainf), jl = "result = la.tcrossprod(A)")
cs("tcrossprod_vec", "tcrossprod(v)", "result = la.tcrossprod(v)", list(v = v5), jl = "result = la.tcrossprod(v)")
cs("tcrossprod_err", "tcrossprod(A, B)", "result = la.tcrossprod(A, B)", list(A = A, B = B), jl = "result = la.tcrossprod(A, B)")
cs("outer_mul", "outer(v, w)", "result = la.outer(v, w)", list(v = v5, w = v7), jl = "result = la.outer(v, w)")
cs("outer_minus", "outer(v, w, '-')", "result = la.outer(v, w, '-')", list(v = v5, w = v7), jl = "result = la.outer(v, w, \"-\")")
cs("outer_pow", "outer(v, 1:3, '^')", "result = la.outer(v, np.arange(1, 4), '^')", list(v = abs(v5)), jl = "result = la.outer(v, [1, 2, 3], \"^\")")
cs("outer_names", "outer(v, w, '+')", "result = la.outer(v, w, '+')", list(v = c(a = 1, b = 2), w = c(x = 0.5, y = 3, z = -1)), jl = "result = la.outer(v, w, \"+\")")

## ── solve ────────────────────────────────────────────────────────────────
cs("solve_inv", "solve(S)", "result = la.solve(S)", list(S = Sq), jl = "result = la.solve(S)")
cs("solve_b", "solve(S, b)", "result = la.solve(S, b)", list(S = Sq, b = rnorm(6)), jl = "result = la.solve(S, b)")
cs("solve_B", "solve(S, B)", "result = la.solve(S, B)", list(S = Sq, B = matrix(rnorm(18), 6, 3)), jl = "result = la.solve(S, B)")
cs("solve_70", "solve(S, b)", "result = la.solve(S, b)", list(S = Sq70, b = rnorm(70)), jl = "result = la.solve(S, b)")
cs("solve_inv70", "solve(S)", "result = la.solve(S)", list(S = Sq70), jl = "result = la.solve(S)")
cs("solve_names", "solve(S)", "result = la.solve(S)", list(S = `dimnames<-`(S4, list(letters[1:4], LETTERS[1:4]))), jl = "result = la.solve(S)")
cs("solve_1x1", "solve(matrix(4))", "result = la.solve(np.array([[4.0]]))", jl = "result = la.solve(fill(4.0, 1, 1))")
cs("solve_scalar", "solve(2.5, 5)", "result = la.solve(2.5, 5.0)", jl = "result = la.solve(2.5, 5.0)")
cs("solve_err_sing", "solve(S)", "result = la.solve(S)", list(S = Sing), jl = "result = la.solve(S)")
cs("solve_err_exact", "solve(Z)", "result = la.solve(Z)", list(Z = Z), jl = "result = la.solve(Z)")
cs("solve_err_cond", "solve(matrix(c(1, 1, 1, 1 + 1e-17), 2))", "result = la.solve(np.array([[1, 1], [1, 1 + 1e-17]]))", jl = "result = la.solve([1.0 1.0; 1.0 1.0+1e-17])")
cs("solve_err_illcond", "solve(matrix(c(1, 1, 1, 1 + 1e-14), 2))", "result = la.solve(np.array([[1, 1], [1, 1 + 1e-14]]))", jl = "result = la.solve([1.0 1.0; 1.0 1.0+1e-14])")
cs("solve_tol", "solve(matrix(c(1, 1, 1, 1 + 1e-14), 2), tol = 1e-20)", "result = la.solve(np.array([[1, 1], [1, 1 + 1e-14]]), tol=1e-20)", jl = "result = la.solve([1.0 1.0; 1.0 1.0+1e-14]; tol = 1e-20)")
cs("solve_err_sq", "solve(A)", "result = la.solve(A)", list(A = A), jl = "result = la.solve(A)")
cs("solve_err_dim", "solve(S, rnorm(5))", "result = la.solve(S, np.ones(5))", list(S = Sq), jl = "result = la.solve(S, ones(5))")
cs("solve_int", "solve(matrix(c(2L, 1L, 1L, 3L), 2))", "result = la.solve(np.array([[2, 1], [1, 3]]))", jl = "result = la.solve([2 1; 1 3])")

## ── chol / chol2inv / backsolve / forwardsolve ───────────────────────────
cs("chol_4", "chol(S)", "result = la.chol(S)", list(S = S4), jl = "result = la.chol(S)")
cs("chol_70", "chol(S)", "result = la.chol(S)", list(S = S70), jl = "result = la.chol(S)")
cs("chol_names", "chol(S)", "result = la.chol(S)", list(S = `dimnames<-`(S4, list(letters[1:4], letters[1:4]))), jl = "result = la.chol(S)")
cs("chol_1", "chol(matrix(9))", "result = la.chol(np.array([[9.0]]))", jl = "result = la.chol(fill(9.0, 1, 1))")
cs("chol_err_pd", "chol(S)", "result = la.chol(S)", list(S = Sq + t(Sq)), jl = "result = la.chol(S)")
cs("chol_err_sq", "chol(A)", "result = la.chol(A)", list(A = A), jl = "result = la.chol(A)")
cs("chol_err_na", "chol(S)", "result = la.chol(S)", list(S = replace(S4, 6, NA)), jl = "result = la.chol(S)")
cs("chol2inv_4", "chol2inv(chol(S))", "result = la.chol2inv(la.chol(S))", list(S = S4), jl = "result = la.chol2inv(la.chol(S))")
cs("chol2inv_70", "chol2inv(chol(S))", "result = la.chol2inv(la.chol(S))", list(S = S70), jl = "result = la.chol2inv(la.chol(S))")
cs("chol2inv_size", "chol2inv(chol(S), size = 2)", "result = la.chol2inv(la.chol(S), size=2)", list(S = S4), jl = "result = la.chol2inv(la.chol(S); size = 2)")
cs("chol2inv_err", "chol2inv(chol(S), size = 5)", "result = la.chol2inv(la.chol(S), size=5)", list(S = S4), jl = "result = la.chol2inv(la.chol(S); size = 5)")
R4 <- chol(S4)
cs("backsolve_v", "backsolve(R, b)", "result = la.backsolve(R, b)", list(R = R4, b = rnorm(4)), jl = "result = la.backsolve(R, b)")
cs("backsolve_M", "backsolve(R, B)", "result = la.backsolve(R, B)", list(R = R4, B = matrix(rnorm(12), 4, 3)), jl = "result = la.backsolve(R, B)")
cs("backsolve_t", "backsolve(R, B, transpose = TRUE)", "result = la.backsolve(R, B, transpose=True)", list(R = R4, B = matrix(rnorm(12), 4, 3)), jl = "result = la.backsolve(R, B; transpose = true)")
cs("backsolve_k", "backsolve(R, b, k = 2)", "result = la.backsolve(R, b, k=2)", list(R = R4, b = rnorm(4)), jl = "result = la.backsolve(R, b; k = 2)")
cs("backsolve_lower", "backsolve(L, b, upper.tri = FALSE)", "result = la.backsolve(L, b, upper_tri=False)", list(L = t(R4), b = rnorm(4)), jl = "result = la.backsolve(L, b; upper_tri = false)")
cs("backsolve_70", "backsolve(R, B)", "result = la.backsolve(R, B)", list(R = chol(S70), B = matrix(rnorm(140), 70, 2)), jl = "result = la.backsolve(R, B)")
cs("backsolve_err_sing", "backsolve(R, 1:3)", "result = la.backsolve(R, np.arange(1, 4))", list(R = diag(c(1, 0, 2))), jl = "result = la.backsolve(R, [1, 2, 3])")
cs("forwardsolve_v", "forwardsolve(L, b)", "result = la.forwardsolve(L, b)", list(L = t(R4), b = rnorm(4)), jl = "result = la.forwardsolve(L, b)")
cs("forwardsolve_t", "forwardsolve(L, B, transpose = TRUE)", "result = la.forwardsolve(L, B, transpose=True)", list(L = t(R4), B = matrix(rnorm(8), 4, 2)), jl = "result = la.forwardsolve(L, B; transpose = true)")

## ── determinant / det ───────────────────────────────────────────────────
cs("det_6", "det(S)", "result = la.det(S)", list(S = Sq), jl = "result = la.det(S)")
cs("det_70", "det(S)", "result = la.det(S)", list(S = Sq70), jl = "result = la.det(S)")
cs("det_sing", "det(Z)", "result = la.det(Z)", list(Z = Z), jl = "result = la.det(Z)")
cs("det_1", "det(matrix(-3))", "result = la.det(np.array([[-3.0]]))", jl = "result = la.det(fill(-3.0, 1, 1))")
cs("det_0x0", "det(matrix(0, 0, 0))", "result = la.det(np.zeros((0, 0)))", jl = "result = la.det(zeros(0, 0))")
cs("determinant_log", "d <- determinant(S); list(modulus = as.vector(d$modulus), sign = d$sign)",
   "d = la.determinant(S)\nresult = {'modulus': d['modulus'], 'sign': d['sign']}", list(S = Sq), jl = "d = la.determinant(S)\nresult = RList(\"modulus\" => d[\"modulus\"], \"sign\" => d[\"sign\"])")
cs("determinant_nolog", "d <- determinant(S, logarithm = FALSE); list(modulus = as.vector(d$modulus), sign = d$sign)",
   "d = la.determinant(S, logarithm=False)\nresult = {'modulus': d['modulus'], 'sign': d['sign']}", list(S = Sq70), jl = "d = la.determinant(S; logarithm = false)\nresult = RList(\"modulus\" => d[\"modulus\"], \"sign\" => d[\"sign\"])")
cs("det_err_sq", "det(A)", "result = la.det(A)", list(A = A), jl = "result = la.det(A)")

## ── eigen ────────────────────────────────────────────────────────────────
for (nm in c("S4", "S70")) {
  S <- get(nm)
  cs(paste0("eigen_vals_", nm), "eigen(S, only.values = TRUE)$values", "result = la.eigen(S, only_values=True)['values']", list(S = S),
     jl = "result = la.eigen(S; only_values = true)[\"values\"]")
  cs(paste0("eigen_", nm), "e <- eigen(S); list(values = e$values, vectors = e$vectors)",
     "e = la.eigen(S)\nresult = {'values': e['values'], 'vectors': e['vectors']}", list(S = S),
     jl = "e = la.eigen(S)\nresult = RList(\"values\" => e[\"values\"], \"vectors\" => e[\"vectors\"])")
}
cs("eigen_vals_degen", "eigen(S, only.values = TRUE)$values", "result = la.eigen(S, only_values=True)['values']",
   list(S = tcrossprod(c(1, 2, 3, 4))), jl = "result = la.eigen(S; only_values = true)[\"values\"]")
cs("eigen_ties", "e <- eigen(diag(c(2, 5, 2, 1))); list(values = e$values, vectors = e$vectors)",
   "e = la.eigen(np.diag([2.0, 5, 2, 1]))\nresult = {'values': e['values'], 'vectors': e['vectors']}", jl = "e = la.eigen(la.diag([2.0, 5, 2, 1]))\nresult = RList(\"values\" => e[\"values\"], \"vectors\" => e[\"vectors\"])")
cs("eigen_1", "e <- eigen(matrix(3)); list(values = e$values, vectors = e$vectors)",
   "e = la.eigen(np.array([[3.0]]))\nresult = {'values': e['values'], 'vectors': e['vectors']}", jl = "e = la.eigen(fill(3.0, 1, 1))\nresult = RList(\"values\" => e[\"values\"], \"vectors\" => e[\"vectors\"])")
cs("eigen_sym_flag", "eigen(S, symmetric = TRUE, only.values = TRUE)$values",
   "result = la.eigen(S, symmetric=True, only_values=True)['values']", list(S = Sq), jl = "result = la.eigen(S; symmetric = true, only_values = true)[\"values\"]")
cs("eigen_cor", "eigen(C, only.values = TRUE)$values", "result = la.eigen(C, only_values=True)['values']",
   list(C = cor(matrix(rnorm(400), 50, 8))), jl = "result = la.eigen(C; only_values = true)[\"values\"]")
cs("eigen_err_inf", "eigen(S)", "result = la.eigen(S)", list(S = replace(S4, 1, Inf)), jl = "result = la.eigen(S)")
cs("eigen_err_sq", "eigen(A)", "result = la.eigen(A)", list(A = A), jl = "result = la.eigen(A)")
cs("isSymmetric_a", "c(isSymmetric(S), isSymmetric(A2), isSymmetric(S + 1e-9))",
   "result = np.array([la.is_symmetric(S), la.is_symmetric(A2), la.is_symmetric(S + 1e-9)])", list(S = S4, A2 = Sq), jl = "result = [la.is_symmetric(S), la.is_symmetric(A2), la.is_symmetric(S .+ 1e-9)]")

## ── qr (LINPACK dqrdc2) ─────────────────────────────────────────────────
Xq <- cbind(1, rnorm(12), rnorm(12)); Xd <- cbind(Xq, Xq[, 2] * 2, rnorm(12)); yq <- rnorm(12)
cs("qr_full", "unclass(qr(X))", "q = la.qr(X)\nresult = {k: q[k] for k in ['qr', 'rank', 'qraux', 'pivot']}", list(X = Xq), jl = "result = la.qr(X)")
cs("qr_rankdef", "unclass(qr(X))", "q = la.qr(X)\nresult = {k: q[k] for k in ['qr', 'rank', 'qraux', 'pivot']}", list(X = Xd), jl = "result = la.qr(X)")
cs("qr_tol", "qr(X, tol = 0.5)$rank", "result = la.qr(X, tol=0.5)['rank']", list(X = Xq), jl = "result = la.qr(X; tol = 0.5)[\"rank\"]")
cs("qr_wide", "unclass(qr(X))", "q = la.qr(X)\nresult = {k: q[k] for k in ['qr', 'rank', 'qraux', 'pivot']}", list(X = t(Xq)[, 1:5]), jl = "result = la.qr(X)")
cs("qr_coef", "qr.coef(qr(X), y)", "result = la.qr_coef(la.qr(X), y)", list(X = Xd, y = yq), jl = "result = la.qr_coef(la.qr(X), y)")
cs("qr_coef_M", "qr.coef(qr(X), cbind(y, -y))", "result = la.qr_coef(la.qr(X), np.column_stack([y, -y]))", list(X = Xq, y = yq), jl = "result = la.qr_coef(la.qr(X), hcat(y, -y))")
cs("qr_qty", "qr.qty(qr(X), y)", "result = la.qr_qty(la.qr(X), y)", list(X = Xd, y = yq), jl = "result = la.qr_qty(la.qr(X), y)")
cs("qr_qy", "qr.qy(qr(X), y)", "result = la.qr_qy(la.qr(X), y)", list(X = Xd, y = yq), jl = "result = la.qr_qy(la.qr(X), y)")
cs("qr_resid", "qr.resid(qr(X), y)", "result = la.qr_resid(la.qr(X), y)", list(X = Xd, y = yq), jl = "result = la.qr_resid(la.qr(X), y)")
cs("qr_fitted", "qr.fitted(qr(X), y)", "result = la.qr_fitted(la.qr(X), y)", list(X = Xq, y = yq), jl = "result = la.qr_fitted(la.qr(X), y)")
cs("qr_fitted_k", "qr.fitted(qr(X), y, k = 2)", "result = la.qr_fitted(la.qr(X), y, k=2)", list(X = Xq, y = yq), jl = "result = la.qr_fitted(la.qr(X), y; k = 2)")
cs("qr_solve", "qr.solve(X, y)", "result = la.qr_solve(X, y)", list(X = Xq, y = yq), jl = "result = la.qr_solve(X, y)")
cs("qr_solve_inv", "qr.solve(S)", "result = la.qr_solve(S)", list(S = Sq), jl = "result = la.qr_solve(S)")
cs("qr_solve_err", "qr.solve(X, y)", "result = la.qr_solve(X, y)", list(X = Xd, y = yq), jl = "result = la.qr_solve(X, y)")
cs("solve_qr", "solve(qr(S), b)", "result = la.solve_qr(la.qr(S), b)", list(S = Sq, b = rnorm(6)), jl = "result = la.solve_qr(la.qr(S), b)")
cs("qr_R", "qr.R(qr(X))", "result = la.qr_R(la.qr(X))", list(X = Xd), jl = "result = la.qr_R(la.qr(X))")
cs("qr_Q", "qr.Q(qr(X))", "result = la.qr_Q(la.qr(X))", list(X = Xd), jl = "result = la.qr_Q(la.qr(X))")
cs("qr_names", "qr.coef(qr(X), y)", "result = la.qr_coef(la.qr(X), y)", list(X = `colnames<-`(Xq, c("i", "a", "b")), y = yq), jl = "result = la.qr_coef(la.qr(X), y)")

## ── diag ────────────────────────────────────────────────────────────────
cs("diag_get", "diag(A)", "result = la.diag(A)", list(A = A), jl = "result = la.diag(A)")
cs("diag_names", "diag(S)", "result = la.diag(S)", list(S = `dimnames<-`(S4, list(letters[1:4], letters[1:4]))), jl = "result = la.diag(S)")
cs("diag_vec", "diag(c(1, 2, 3))", "result = la.diag(np.array([1.0, 2, 3]))", jl = "result = la.diag([1.0, 2, 3])")
cs("diag_n", "diag(3)", "result = la.diag(3)", jl = "result = la.diag(3)")
cs("diag_nrow", "diag(2, 3, 4)", "result = la.diag(2.0, 3, 4)", jl = "result = la.diag(2.0; nrow = 3, ncol = 4)")
cs("diag_1", "diag(5.5)", "result = la.diag(5.5)", jl = "result = la.diag(5.5)")

ref_done()
