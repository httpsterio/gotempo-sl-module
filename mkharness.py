import io, re, sys
src = io.open("/home/sami/gotempo-sl-module/gotempo.lua", encoding="utf-8").read()

def grab(name):
    m = re.search(r"^local function %s\(.*?^end$" % re.escape(name), src, re.M | re.S)
    assert m, "could not extract " + name
    return m.group(0)

names = ["ReadDevices", "StrapOwners", "PickerRows", "SideRows", "ShowNav",
         "FinishSide", "SaveSide", "Confirm", "Move", "PickerAllDone",
         "WriteProfileSettings", "NormalizeHex", "ParseColor", "ParseThickness",
         "ProfileStyle"]
out = ["-- generated: real function bodies lifted from gotempo.lua"]
for n in names:
    out.append(grab(n).replace("local function ", "function ", 1))
# A later "local function Foo" silently shadows an earlier one for everything
# below it, which is legal Lua and invisible to luac. It cost us the gameplay
# panel once: a picker frame named Panel() took over from the one the gameplay
# screen had been calling for months, which also stopped heart-rate samples
# being collected and so blanked the evaluation graph too.
defs = {}
for m in re.finditer(r"^local function (\w+)", src, re.M):
    defs.setdefault(m.group(1), []).append(src[:m.start()].count("\n") + 1)
clashes = {n: ls for n, ls in defs.items() if len(ls) > 1}
if clashes:
    for name, lines in sorted(clashes.items()):
        print("SHADOWED: %s defined at lines %s" % (name, ", ".join(map(str, lines))))
    raise SystemExit("duplicate top-level function names")

io.open("extracted.lua", "w", encoding="utf-8").write("\n\n".join(out) + "\n")
print("extracted", len(names), "functions")
