# Lifts the real function bodies out of gotempo.lua into extracted.lua, so
# picker_test.lua exercises the shipping source rather than a copy of it.
#
# Paths are resolved against this file, not the working directory: it runs from
# the Makefile, from CI, and by hand, and a hardcoded path broke the first
# release build.
import io, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "gotempo.lua")
TARGET = os.path.join(HERE, "extracted.lua")

src = io.open(SOURCE, encoding="utf-8").read()

def grab(name):
    # A one-line function has its own end on the same line. Matching it as a
    # multi-line one would run on to the next function's end and swallow that
    # function as a local, which then shadows the real one.
    one = re.search(r"^local function %s\([^\n]*\bend$" % re.escape(name), src, re.M)
    if one:
        return one.group(0)
    m = re.search(r"^local function %s\(.*?^end$" % re.escape(name), src, re.M | re.S)
    assert m, "could not extract " + name
    body = m.group(0)
    assert body.count("\nlocal function ") == 0, "extracting %s ran into the next function" % name
    return body

names = ["ReadDevices", "StrapOwners", "PickerRows", "SideRows", "ShowNav",
         "FinishSide", "SaveSide", "Confirm", "Move", "PickerAllDone",
         "SameMAC", "WriteProfileSettings", "NormalizeHex", "ParseColor",
         "ParseThickness", "ProfileStyle", "ColorIndex", "ColorPool",
         "AssignColors", "Adjust", "GiveUpScan", "PickerPoll",
         "ForgetProfileDevices", "RememberProfileDevice", "ProfileDevice",
         "PlayerLines", "WritePlayers", "ReadHeartRate", "FreshHeartRate"]
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

# Lua 5.1 allows 200 locals in one scope. Past that the game refuses to load
# the module at all; luac5.1 catches it, but only once it has happened, so warn
# while there is still room to group constants into a table instead.
count = 0
for line in src.splitlines():
    m = re.match(r"^local\s+(?:function\s+\w+|([\w\s,]+?)\s*(?:=|$))", line)
    if m:
        count += len([x for x in (m.group(1) or "f").split(",") if x.strip()])
print("top-level locals: %d / 200" % count)
if count >= 190:
    print("WARNING: close to Lua 5.1's limit of 200 locals; group new constants into a table")

io.open(TARGET, "w", encoding="utf-8").write("\n\n".join(out) + "\n")
print("extracted", len(names), "functions")
