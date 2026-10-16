#!/usr/bin/env python3
"""Print the public signatures of the vendored libraries (eval/libs): one line per `pub fn` / `pub struct`, no comments and no prose. Arm C of the
library-use measurement ("signatures only"): the language page followed by this text.

    python3 eval/libsigs.py > sigs.md"""
import os, re
HERE = os.path.dirname(os.path.abspath(__file__))
out = ["# Library signatures (cancho-web, cancho-schema)", "",
       "Two libraries are compiled into the program (`import schema;`, `import web;`). These are their public items, exactly as declared; nothing else is documented.", ""]
for name, mod, path in (("cancho-schema", "schema", "libs/cancho-schema/src/schema.cho"), ("cancho-web", "web", "libs/cancho-web/src/web.cho")):
    out.append("## module `%s` (%s)" % (mod, name)); out.append(""); out.append("```cancho")
    text = open(os.path.join(HERE, path)).read()
    for m in re.finditer(r"^pub (?:res )?(?:fn|struct)[^{;]*?(?=\s*\{|;)", text, re.M | re.S):
        out.append(" ".join(m.group(0).split()))
    out.append("```"); out.append("")
print("\n".join(out))
