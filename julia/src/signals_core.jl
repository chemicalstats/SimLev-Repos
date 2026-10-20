# SignalsCore – .roll_mean_core, .roll_cov_core aus r/src/research_core.cpp
# (Vorlage python/simlev/_signals_core.py). double-Arithmetik in derselben
# Reihenfolge wie die C++-Fassungen.
module SignalsCore

import ..SimLev
using ..SimLev: NA
using Dates

export roll_mean_core, roll_cov_core

"""
    roll_mean_core(x, n)

`.roll_mean_core(x, n)`: rollierender Mittelwert mit kompensierter Summe
(Neumaier); Fenster der Länge `n` einschließlich der aktuellen Zeile, NA für
Fenster mit nicht endlichen Werten. Die Summe wird alle 4096 Schritte neu
aufgebaut.
"""
function roll_mean_core(x::AbstractVector, n::Integer)
    x = Float64.(x)
    m = length(x)
    n = Int(n)
    out = fill(NA, m)
    (n < 1 || n > m) && return out
    s = 0.0; comp = 0.0; bad = 0
    @inline function add(v)
        t = s + v
        if abs(s) >= abs(v)
            comp += (s - t) + v
        else
            comp += (v - t) + s
        end
        s = t
    end
    function rebuild(e)
        s = 0.0; comp = 0.0; bad = 0
        for k in e-n+1:e
            isfinite(x[k]) ? add(x[k]) : (bad += 1)
        end
    end
    rebuild(n)
    out[n] = bad > 0 ? NA : (s + comp) / n
    for i in n+1:m
        # C++: i0 = i - 1 (0-basiert); (i0 - n) % 4096 == 4095
        if (i - 1 - n) % 4096 == 4095
            rebuild(i)
        else
            isfinite(x[i]) ? add(x[i]) : (bad += 1)
            isfinite(x[i-n]) ? add(-x[i-n]) : (bad -= 1)
        end
        out[i] = bad > 0 ? NA : (s + comp) / n
    end
    return out
end

"""
    roll_cov_core(x, y, n)

`.roll_cov_core(x, y, n)`: rollierende Kovarianz (Populationsform,
Zwei-Pass) `(Σ dx dy - Σ dx Σ dy / n) / n`; NA, wenn das Fenster einen
nicht endlichen Wert enthält.
"""
function roll_cov_core(x::AbstractVector, y::AbstractVector, n::Integer)
    x = Float64.(x); y = Float64.(y)
    m = length(x)
    n = Int(n)
    out = fill(NA, m)
    (n < 1 || n > m || length(y) != m) && return out
    for i in n:m
        sx = 0.0; sy = 0.0; ok = true
        for k in i-n+1:i
            if !isfinite(x[k]) || !isfinite(y[k])
                ok = false; break
            end
            sx += x[k]; sy += y[k]
        end
        ok || continue
        mx = sx / n; my = sy / n
        c = 0.0; cx = 0.0; cy = 0.0
        for k in i-n+1:i
            dx = x[k] - mx; dy = y[k] - my
            c += dx * dy; cx += dx; cy += dy
        end
        out[i] = (c - cx * cy / n) / n
    end
    return out
end

end # module
