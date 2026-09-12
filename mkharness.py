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
io.open("extracted.lua", "w", encoding="utf-8").write("\n\n".join(out) + "\n")
print("extracted", len(names), "functions")
