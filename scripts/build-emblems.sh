#!/bin/bash
# Writes what sessions' emblems are drawn with into the asset catalog (Codealong/Assets.xcassets/
# Emblems), from the main repo at the commit core/Cargo.toml pins, so they're the Mac's own: the
# icons Jev picks from (emblems.rs `ICONS`) as Tabler draws them (Tabler Icons, MIT; the Mac's
# src/ui/icons.ts), and the thirteen colors with the ink the icon is mixed with, light and dark
# (design/tokens.json). build-core.sh runs it, so moving the pin brings any change to them.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

# Cargo's checkout of the pinned commit, not a main checkout's working files.
peer=$(cd core && cargo metadata --format-version 1 | python3 -c 'import json,sys; print(next(p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"] == "codealong-peer"))')
root=$(dirname "$(dirname "$(dirname "$peer")")")

python3 - "$root" Codealong/Assets.xcassets/Emblems <<'EOF'
import json, os, re, shutil, sys

root, out = sys.argv[1], sys.argv[2]

emblems = open(os.path.join(root, "src-tauri/src/emblems.rs")).read()
block = emblems[emblems.index("pub const ICONS"):]
block = block[:block.index("];")]
names = re.findall(r'^\s*\("([a-z0-9-]+)",', block, re.M)

icons_ts = open(os.path.join(root, "src/ui/icons.ts")).read()
paths = json.loads(icons_ts[icons_ts.index("= {") + 2:icons_ts.rindex("};") + 1])
missing = [n for n in names if n not in paths]
if missing:
    sys.exit(f"No Tabler paths for emblem icons: {', '.join(missing)}")

tokens = {t["name"]: t["value"] for t in json.load(open(os.path.join(root, "design/tokens.json")))["color"]["tokens"]}
def themed(name):
    v = tokens[name]
    while isinstance(v, str):
        v = tokens[v.strip("{}")]
    return v
colors = {n[len("emblem-"):]: themed(n) for n in tokens if n.startswith("emblem-")}
colors["ink"] = themed("ink")

shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
def contents(path, body):
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "Contents.json"), "w") as f:
        json.dump({**body, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
contents(out, {})

# Stroked as the Mac strokes an emblem's icon (primitives.tsx `SessionEmblem`), a template the
# app tints.
for name in names:
    d = os.path.join(out, f"emblem-icon-{name}.imageset")
    contents(d, {"images": [{"filename": f"{name}.svg", "idiom": "universal"}], "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}})
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">'
    svg += "".join(f'<path d="{p}"/>' for p in paths[name]) + "</svg>\n"
    with open(os.path.join(d, f"{name}.svg"), "w") as f:
        f.write(svg)

def components(hex):
    r, g, b = (int(hex.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    return {"color-space": "srgb", "components": {"red": f"0x{r:02X}", "green": f"0x{g:02X}", "blue": f"0x{b:02X}", "alpha": "1.000"}}
for name, v in colors.items():
    contents(os.path.join(out, f"emblem-{name}.colorset"), {"colors": [
        {"idiom": "universal", "color": components(v["light"])},
        {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": components(v["dark"])},
    ]})
print(f"Wrote {len(names)} emblem icons and {len(colors)} colors into {out}")
EOF
