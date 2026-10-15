#!/bin/sh
# pieces.sh REFERENCE PIECES UNIT: print the top-level items (functions, structs, with the comments above them) of the reference application
# that PIECES assigns to UNIT. PIECES has one line per unit, `<unit>: <name> <name> ...`; the unit `app: *` gets every item no other line names.
# This is the stand-in agent's source of answers (eval/services/standin.sh): it proves a service plan is buildable by the pieces of a working
# application, with no model.
awk -v unit="$3" -v pieces="$2" '
BEGIN {
    while ((getline line < pieces) > 0) {
        c = index(line, ":"); u = substr(line, 1, c - 1); rest = substr(line, c + 1)
        n = split(rest, w, " ")
        for (i = 1; i <= n; i++) { if (w[i] == "*") star[u] = 1; else owner[w[i]] = u }
    }
}
function flush_item() { if (cur != "") { names[++nitems] = cur; text[nitems] = body; } cur = ""; body = "" }
/^(pub )?(fn|struct|enum|res struct) / {
    s = $0; sub(/^pub /, "", s); sub(/^res /, "", s); sub(/^(fn|struct|enum) /, "", s)
    match(s, /^[A-Za-z0-9_]+/); nm = substr(s, 1, RLENGTH)
    flush_item(); cur = nm; body = pend $0 "\n"; pend = ""; next
}
/^import / || /^edition / { flush_item(); pend = ""; next }
/^\/\// || /^$/ { pend = pend $0 "\n"; next }
{ body = body pend $0 "\n"; pend = "" }
END {
    flush_item()
    for (i = 1; i <= nitems; i++) {
        o = (names[i] in owner) ? owner[names[i]] : "*"
        if (o == unit || (o == "*" && star[unit])) { printf "\n%s", text[i] }
    }
}' "$1"
