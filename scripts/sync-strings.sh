#!/bin/zsh
# Updates App/Edwell/Localizable.xcstrings from the code, the way Xcode does for its own targets: the
# compiler lists every localizable string in EddieKit and xcstringstool merges them into the catalog.
# Strings no longer in the code are dropped. A new string arrives without its Danish translation, and
# the self test fails until it has one. Needs Xcode (xcstringstool).
#   scripts/sync-strings.sh
set -euo pipefail
cd "$(dirname "$0")/.."

out=.build/localized-strings
mkdir -p $out
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$out" >/dev/null

# The build also compiles the design system's sources; only EddieKit's strings belong in the catalog.
data=()
for file in Sources/EddieKit/**/*.swift; do
    name=$out/${file:t:r}.stringsdata
    [ -f $name ] && data+=($name)
done

catalog=App/Edwell/Localizable.xcstrings
xcrun xcstringstool sync $catalog --stringsdata $data
python3 -I - $catalog <<'PY'
import json, sys
path = sys.argv[1]
catalog = json.load(open(path, encoding="utf-8"))
strings = catalog["strings"]
for key in [k for k, v in strings.items() if v.get("extractionState") == "stale"]:
    del strings[key]
missing = [k for k, v in strings.items()
           if v.get("shouldTranslate") is not False and "da" not in v.get("localizations", {})]
with open(path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    f.write("\n")
print(f"{len(strings)} strings, {len(missing)} without Danish")
for key in missing:
    print("  ", json.dumps(key, ensure_ascii=False))
PY
