#!/bin/sh
set -eu

laix_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$laix_dir")
mkdir -p "$laix_dir/build"

python3 "$laix_dir/tools/pack_unifont.py" \
    "${LAIX_FONT:-$repo_dir/vendor/SDL/test/unifont-15.1.05.hex}" \
    "$laix_dir/fonts/unifont-console.laf" --index "$laix_dir/fonts/unifont-index.laf"

# m.py's image mode always adds crt0/trap. Compile modules separately and
# link our start object first. Same-name module .asm files are included by M.
obj_dir="$laix_dir/build/obj"
mkdir -p "$obj_dir/font"
python3 "$repo_dir/tools/asm.py" -c "$laix_dir/src/start.asm" -o "$obj_dir/start.o"
set -- "$obj_dir/start.o"
python3 "$repo_dir/tools/m.py" -c "${LAIX_MAIN:-$laix_dir/src/main.m}" -o "$obj_dir/main.o"
set -- "$@" "$obj_dir/main.o"
for module in boot trap_frame trap panic debug_uart console rnd font/font font/glyph_cache font/data; do
    python3 "$repo_dir/tools/m.py" -c "$laix_dir/src/$module.m" -o "$obj_dir/$module.o"
    set -- "$@" "$obj_dir/$module.o"
done
python3 "$repo_dir/tools/asm.py" -c "$repo_dir/m/runtime/mem.asm" -o "$obj_dir/mem.o"
python3 "$repo_dir/tools/ld.py" --layout boot "$@" "$obj_dir/mem.o" \
    -o "$laix_dir/build/laix.img" --map "$laix_dir/build/laix.map"

python3 "$laix_dir/tools/append_font.py" \
    "$laix_dir/build/laix.img" "$laix_dir/fonts/unifont-console.laf"

printf 'Boot image: %s\n' "$laix_dir/build/laix.img"
