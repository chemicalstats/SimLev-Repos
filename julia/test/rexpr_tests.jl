# Tests des gemeinsamen R-Syntax-Auswerters SimLev.RExpr.
# Erwartete Werte mit R 4.3.3 geprüft (Rscript, LC_ALL=C.UTF-8):
#   a <- c(1, NA, 3, NaN); b <- c(2, 2, NA, 1); s <- c("x", "y", "z", "x")
#   eval(parse(text = <Ausdruck>))

using Test
using SimLev

const _E = SimLev.RExpr
const _NA_ = SimLev.NA

# Vergleich streng: NA ≠ NaN, missing nur gleich missing, Vorzeichen der Null
function _same(r, e)
    length(r) == length(e) || return false
    for (x, y) in zip(r, e)
        if y === missing
            x === missing || return false
        elseif y isa Float64 && isnan(y)
            (x isa Float64 && isnan(x) && SimLev.isna_strict(x) == SimLev.isna_strict(y)) || return false
        elseif y isa Float64
            (x isa Float64 && x === y) || return false
        else
            (x !== missing && x == y) || return false
        end
    end
    true
end

@testset "RExpr" begin
    d = SimLev.RFrame("a" => [1.0, _NA_, 3.0, NaN], "b" => [2.0, 2.0, _NA_, 1.0], "s" => ["x", "y", "z", "x"])
    ev(s) = _E.eval_r(s, d)
    cases = [
        # Vorrang (R: einstelliges ! bindet schwächer als Vergleich und Arithmetik)
        "!a > 1"                     => [true, missing, false, missing],
        "!a + 1"                     => [false, missing, false, missing],
        "a == !b"                    => [false, missing, missing, missing],
        "1 + !0 > 0"                 => [2.0],
        "!TRUE & FALSE"              => [false],
        "-2^2"                       => [-4.0],
        "2^-1"                       => [0.5],
        "-1:3"                       => [-1, 0, 1, 2, 3],
        "2 * 3 %% 4"                 => [6.0],
        "1 | 0 & 0"                  => [true],
        # dreiwertige NA-Logik
        "NA & FALSE"                 => [false],
        "NA | TRUE"                  => [true],
        "NA & TRUE"                  => [missing],
        "a > b | is.na(a)"           => [false, true, missing, true],
        "xor(TRUE, NA)"              => [missing],
        "a > 2 & b < 3"              => [false, missing, missing, missing],
        # %in%, %%, %/%, Zeichen
        "a %in% c(NaN)"              => [false, false, false, true],
        "NA %in% NaN"                => [false],
        "-0 %in% 0"                  => [true],
        "s %in% c(\"x\")"            => [true, false, false, true],
        "c(1,2) == \"1\""            => [true, false],
        "5 %% -3"                    => [-1.0],
        "-5 %/% 3"                   => [-2.0],
        "5L %/% 2L + 0.5"            => [2.5],
        # Funktionen
        "ifelse(c(TRUE,NA,FALSE), 1, \"a\")" => ["1", missing, "a"],
        "is.finite(c(TRUE,NA))"      => [true, false],
        "pmin(a, b)"                 => [1.0, _NA_, _NA_, NaN],
        "round(2.5) + signif(123456, 2)" => [120002.0],
        "max(a, na.rm = TRUE)"       => [3.0],
        "log(8, 2)"                  => [3.0],
        "T & !F"                     => [true],
        "pi > 3.14159 & Inf > 1e308" => [true],
    ]
    for (s, e) in cases
        @test _same(ev(s), e)
    end
    # Fehler wie in R
    @test_throws ErrorException ev("a < b < c")
    @test (try ev("\"a\" + 1"); "" catch e; e.msg end) == "non-numeric argument to binary operator"
    @test (try ev("!\"a\""); "" catch e; e.msg end) == "invalid argument type"
    @test (try ev("c(TRUE,FALSE) && TRUE"); "" catch e; e.msg end) == "'length = 2' in coercion to 'logical(1)'"
    @test (try ev("zz > 1"); "" catch e; e.msg end) == "object 'zz' not found"
    @test (try ev("foo(1)"); "" catch e; e.msg end) == "could not find function \"foo\""
    # Variablen aus env (Dict, NamedTuple, Modul) und Julia-Funktionen aus env
    @test _same(_E.eval_r("a > thr", d; env = Dict("thr" => 2)), [false, missing, true, missing])
    @test _same(_E.eval_r("a > thr", d; env = (thr = 0.5,)), [true, missing, true, missing])
    @test _same(_E.eval_r("dbl(b) > 3", d; env = (dbl = x -> 2 .* x,)), [true, true, missing, false])
    # die drei Aufrufstellen
    dd = (date = [SimLev.from_days(18000 + i) for i in 0:3], A = [1.0, 2.0, 3.0, 4.0], B = [2.0, 2.0, 2.0, 2.0])
    w = SimLev.Tactical.tactical_rules(dd, [SimLev.RList("when" => "!A > B", "weights" => SimLev.named("A" => 1))], SimLev.named("B" => 1))
    @test SimLev.attrs(w)["regime"] == [1, 1, 0, 0]
    rs = SimLev.Dependence.regime_subset(dd, "!A < 3")
    @test SimLev.nrow(rs) == 2
end
