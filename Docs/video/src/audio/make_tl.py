"""timeline.json -> web/data_tl.js"""
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
tl = json.load(open(os.path.join(HERE, "build", "timeline.json")))
out = os.path.join(HERE, "..", "data_tl.js")
open(out, "w").write("window.TL = " + json.dumps(tl, ensure_ascii=False) + ";\n")
print("data_tl.js:", tl["duration"], "s,", len(tl["lines"]), "lines")
