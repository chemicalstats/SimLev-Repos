/* core/slc_ctx.c – Kontext: Fehler, Warnungen, Benutzerabbruch (SimLev core, Etappe 9)
 * Verfahren:  Statuscode und Text im Kontext statt longjmp; Warnungen werden gesammelt (gleiche
 *             Texte nur einmal, höchstens SL_WARN_MAX) und vom Host nach dem Aufruf ausgegeben;
 *             der Abbruch wird über einen Rückruf des Hosts erfragt (B.0, C.4).
 * Quellen:    ISO/IEC 9899:1999 (C99), 7.15 (stdarg.h), 7.19.6.12 (vsnprintf), 7.20.3 (malloc).
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: –
 */
#include "slc_internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void sl_ctx_init(sl_ctx *cx)
{
    memset(cx, 0, sizeof *cx);
    cx->interrupted = NULL;
    cx->host = NULL;
}

sl_ctx *sl_ctx_alloc(void)
{
    sl_ctx *cx = (sl_ctx *) malloc(sizeof *cx);
    if (cx) sl_ctx_init(cx);
    return cx;
}

void sl_ctx_free(sl_ctx *cx) { free(cx); }

void sl_ctx_reset(sl_ctx *cx)
{
    cx->status = SL_OK;
    cx->msg[0] = '\0';
    cx->n_warn = 0;
}

int sl_ctx_status(const sl_ctx *cx) { return cx->status; }
const char *sl_ctx_msg(const sl_ctx *cx) { return cx->msg; }
int sl_ctx_nwarn(const sl_ctx *cx) { return cx->n_warn; }

const char *sl_ctx_warn(const sl_ctx *cx, int i)
{
    return (i >= 0 && i < cx->n_warn) ? cx->warn[i] : "";
}

const char *sl_version(void) { return SLC_VERSION; }

int sl_fail(sl_ctx *cx, int code, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cx->msg, SL_MSG_LEN, fmt, ap);
    va_end(ap);
    cx->status = code;
    return code;
}

void sl_warn(sl_ctx *cx, const char *fmt, ...)
{
    char buf[SL_WARN_LEN];
    int i;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, SL_WARN_LEN, fmt, ap);
    va_end(ap);
    for (i = 0; i < cx->n_warn; i++)
        if (strcmp(cx->warn[i], buf) == 0) return;
    if (cx->n_warn < SL_WARN_MAX) {
        memcpy(cx->warn[cx->n_warn], buf, SL_WARN_LEN);
        cx->n_warn++;
    }
}

int sl_interrupted(sl_ctx *cx)
{
    if (cx == NULL || cx->interrupted == NULL) return 0;
    if (cx->interrupted(cx->host)) {
        sl_fail(cx, SL_EINTR, "Benutzerabbruch");
        return 1;
    }
    return 0;
}
