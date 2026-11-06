#!/bin/sh
# Off-car test of the Wireless mod on the patch engine, against a car's real
# stock files (kept privately: STOCK, default ~/hmg-private/stock/ev6 with app/,
# lib/, onebin/, permissions/). Every part on: each rebuilt file must match the
# set's expect list (the engine checks), props go live, nothing touches
# build.prop; restore must give back every stock byte.
#   mods/wireless-carplay-aa/test.sh [stock dir] [product] [onebin]
set -e
cd "$(dirname "$0")/../.."
REPO=$PWD
S=${1:-$HOME/hmg-private/stock/ev6}
PRODUCT=${2:-CVEV.USA.0000.V015.012.260507}
ONEBIN=${3:-cvev_us}
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: wanted [$2], got [$3]"; fail=1; fi; }
has() { case "$3" in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: wanted [$2] in [$3]"; fail=1 ;; esac; }
check "CEEV USA 260903 is supported" 1 "$(jq '[.system[] | select((.model == "CEEV" or (.model | arrays and index("CEEV"))) and .region == "USA" and .firmware == "260903" and (.features | index("hmgapi.wifi")))] | length' mods/wireless-carplay-aa/mod.json)"
check "CEEV USA uses the validated EV patch set" ev6 "$(jq -r '.cars["CEEV.USA."]' mods/wireless-carplay-aa/patches.json)"
check "CEEV Android Auto turn-by-turn recipe is included" 1 "$(jq '[.hooks.native["libautoreceiver_infobank.so"][] | select(. == "recipes/aa-tbt-dbfe7bd2.recipe")] | length' mods/wireless-carplay-aa/mod.json)"
CEEV_TBT=mods/wireless-carplay-aa/recipes/aa-tbt-dbfe7bd2.recipe
check "CEEV TBT hooks routeMessage's unknown-message path" \
    "branch 0xb7f38 0x0" "$(grep '^branch ' "$CEEV_TBT")"
check "CEEV TBT returns to routeMessage cleanup" \
    "rel32 0x50 0x40 0xb7f3d" "$(grep '^rel32 0x50 ' "$CEEV_TBT")"
check "CEEV TBT uses its callback thunks and string helpers" \
    "rel32 0x40 0x40 0xa7211
rel32 0x44 0x40 0xa715b
rel32 0x48 0x40 0xa679d
rel32 0x4c 0x40 0xa7efd" "$(grep '^rel32 0x4[048c] ' "$CEEV_TBT")"
[ -d "$S/app" ] || { echo "no stock tree at $S (stock-file checks skipped)"; exit $fail; }
[ -x out/lpatch-host ] || { echo "run ./build.sh lpatch first"; exit 1; }
CP=$(mktemp -d); T=$(mktemp -d); trap 'rm -rf "$T" "$CP"' EXIT
javac --release 8 -Xlint:-options -nowarn -d "$CP" core/runtime/java/hmgapi/engine/*.java 2>/dev/null
R=$T/root
eng() { set +e; out=$(HMGAPI_ROOT=$R HMGAPI_HOST=1 HMGAPI_TEST_ANY_CAR=1 HMGAPI_PRODUCT=$PRODUCT HMGAPI_ONEBIN=$ONEBIN \
        HMGAPI_LPATCH=$REPO/out/lpatch-host java -cp "$CP" hmgapi.engine.Engine "$@" 2>&1); rc=$?; set -e; }
tree() { (cd $R/system && find . -type f | sort | while read f; do echo "$(md5sum < "$f" | cut -c1-32) $f"; done) }

mkdir -p $R/system/app $R/system/lib $R/system/etc/permissions $R/system/onebin/$ONEBIN $R/sys/bus/sdio/devices/mmc1:0001:1 $R/data/hmgapi/mods $R/data/hmgapi/settings
cp $S/app/* $R/system/app/; cp $S/lib/* $R/system/lib/
cp $S/onebin/$ONEBIN/featurexml.cfg $R/system/onebin/$ONEBIN/
[ -d $S/permissions ] && cp $S/permissions/* $R/system/etc/permissions/
printf 'ro.build.product=%s\npersist.ium.support=none\n' "$PRODUCT" > $R/system/build.prop
printf 'ro.build.product=%s\nro.board.platform=tcc803x\nro.build.version.release=4.4.2\nro.mobis.onebindir=%s\n' "$PRODUCT" "$ONEBIN" > $R/props.txt
cp -r mods/wireless-carplay-aa $R/data/hmgapi/mods/
rm -f $R/data/hmgapi/mods/wireless-carplay-aa/test.sh
BEFORE=$(tree)

eng plan
check "plan has no problems" 0 $rc
[ $rc = 0 ] || echo "$out"
has "plan opens GPM's wireless Android Auto port on the hotspot" \
    "network  firewall filter input: accept tcp port 40515 in hotspot (IPv4, 1 rule) [wireless-carplay-aa]" "$out"
eng apply
check "apply (every part)" 0 $rc
[ $rc = 0 ] || echo "$out"
has "wireless Android Auto reaches GPM through the stock firewall" \
    "ipt 4 filter HMGAPI_IN -i wlan0 -s 192.168.0.0/24 -p tcp --dport 40515 -j ACCEPT" \
    "$(cat $R/data/hmgapi/state/net.rules)"
check "turn-by-turn GPM is hooks now: GPM untouched" "" "$(echo "$out" | grep HKMC_GPM)"
check "AA and CarPlay libraries are patched in memory now: files untouched" "" "$(echo "$out" | grep 'libautoreceiver\|libCarPlay')"
has "audio converter added" "/system/lib/libleafiaaac.so" "$out"
check "menu fix is a hook now: BtSettings untouched" "" "$(echo "$out" | grep HKMC_BtSettings)"
has "props live" "prop/persist.ium.support=carplay" "$(cat $R/settings.txt)"
has "bridge props live" "prop/persist.iap2.iden.wireless=t" "$(cat $R/settings.txt)"
check "build.prop untouched" "persist.ium.support=none" "$(grep persist.ium $R/system/build.prop)"
has "feature flag: CarPlay wireless file" '<feature name="com.hkmc.software.connectivity.carplay_wireless" />' "$(cat $R/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml 2>/dev/null)"
has "featurexml: AA wireless line commented" "#-/system/etc/permissions/com.hkmc.software.connectivity.androidauto_wireless.xml" "$(cat $R/system/onebin/$ONEBIN/featurexml.cfg)"
check "turn-by-turn and bridge are hooks now: DiPO untouched" "" "$(echo "$out" | grep HKMC_DiPO)"

printf '{"bridge": false}\n' > $R/data/hmgapi/settings/wireless-carplay-aa.json
eng apply
check "settings change rebuilds" 0 $rc
[ $rc = 0 ] || echo "$out"
check "no Wi-Fi client feature" no "$([ -f $R/system/etc/permissions/android.hardware.wifi.xml ] && echo yes || echo no)"
has "bridge off: its props back" "prop/persist.ium.support=carplay" "$(cat $R/settings.txt)"
check "bridge off: iap2 prop gone" "" "$(grep iap2.iden $R/settings.txt || true)"

eng restore
check "restore exit" 0 $rc
check "/system byte-identical to stock" "$BEFORE" "$(tree)"
check "props back to stock" "" "$(cat $R/settings.txt)"
exit $fail
