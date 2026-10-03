#!/bin/sh
set -eu

laix_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$laix_dir")
mkdir -p "$laix_dir/build"

python3 "$laix_dir/tools/pack_unifont.py" \
    "${LAIX_FONT:-$repo_dir/vendor/SDL/test/unifont-15.1.05.hex}" \
    "$laix_dir/fonts/unifont-console.laf" --index "$laix_dir/fonts/unifont-index.laf"

# mc.py's image mode always adds crt0/trap. Compile modules separately and
# link our start object first. Same-name module .asm files are included by M.
obj_dir="$laix_dir/build/obj"
mkdir -p "$obj_dir"
python3 "$repo_dir/mc/asm.py" -c "$laix_dir/src/arch/wrm081632/start.asm" -o "$obj_dir/start.o"
set -- "$obj_dir/start.o"
main_source=${LAIX_MAIN:-$laix_dir/src/kernel/main.m}
python3 "$repo_dir/mc/mc.py" -c "$main_source" -o "$obj_dir/main.o"
set -- "$@" "$obj_dir/main.o"
# The MMU CPU probes share a test-only M module and its assembly companion.
case "$(basename -- "$main_source")" in
    mmu_remap.m|mmu_unmap.m|mmu_protect.m|asid_reuse.m)
        python3 "$repo_dir/mc/mc.py" -c "$laix_dir/tests/programs/mm/mmu_probe.m" -o "$obj_dir/mmu_probe.o"
        set -- "$@" "$obj_dir/mmu_probe.o"
        ;;
esac
for module in arch/wrm081632/defs kernel/boot mm/memory mm/mmu trap/trap_frame task/task trap/trap kernel/panic drivers/debug_uart drivers/videocard console/console drivers/rnd console/font/font console/font/glyph_cache console/font/data; do
    mkdir -p "$(dirname -- "$obj_dir/$module.o")"
    python3 "$repo_dir/mc/mc.py" -c "$laix_dir/src/$module.m" -o "$obj_dir/$module.o"
    set -- "$@" "$obj_dir/$module.o"
done
python3 "$repo_dir/mc/asm.py" -c "$repo_dir/mc/runtime/mem.asm" -o "$obj_dir/mem.o"
python3 "$repo_dir/mc/ld.py" --layout boot "$@" "$obj_dir/mem.o" \
    -o "$laix_dir/build/laix.img" --map "$laix_dir/build/laix.map"

python3 "$laix_dir/tools/append_font.py" \
    "$laix_dir/build/laix.img" "$laix_dir/fonts/unifont-console.laf"

printf 'Boot image: %s\n' "$laix_dir/build/laix.img"
