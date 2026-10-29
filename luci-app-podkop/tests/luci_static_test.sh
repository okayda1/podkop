#!/bin/sh
# Static checks for the luci-app-podkop changes (DNS failover field):
# syntax of every view module + structural asserts on the widget and ru locale.
# Run in a container with node and gettext:
#   docker run --rm -v /path/to/fork:/repo:ro node:22-alpine \
#       sh -c 'apk add -q gettext && sh /repo/podkop/../luci-app-podkop/tests/luci_static_test.sh'
# (adjust the path below when copying; TESTS_DIR is resolved from this file)

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$TESTS_DIR/../htdocs/luci-static/resources/view/podkop"
PO="$TESTS_DIR/../po/ru/podkop.po"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }
assert_has() { grep -q -- "$2" "$1" 2>/dev/null && ok || bad "$3: [$2] not found in $1"; }

command -v node >/dev/null || { echo "node required" >&2; exit 1; }

# --- syntax of every view module ---------------------------------------------
for js in "$APP"/*.js; do
    node --check "$js" 2>/dev/null && ok || bad "syntax error in $js: $(node --check "$js" 2>&1 | head -2)"
done

# --- the fallback widget is wired like its siblings ---------------------------
assert_has "$APP/settings.js" '"fallback_dns_server"' "widget uci option name"
assert_has "$APP/settings.js" 'form.Value' "widget type"
assert_has "$APP/settings.js" 'o.default = "77.88.8.8,dhcp"' "widget default"
assert_has "$APP/settings.js" '"dhcp", _("Provider DNS (from DHCP)")' "dhcp suggestion"
assert_has "$APP/settings.js" '"0", _("Disabled")' "disable suggestion"
assert_has "$APP/settings.js" 'main.validateDNS(entry)' "validator reuses main.validateDNS"
assert_has "$APP/settings.js" 'o.rmempty = false' "rmempty=false"
# the widget sits in the settings tab next to the other DNS fields
dns_block=$(grep -n 'bootstrap_dns_server\|fallback_dns_server\|dns_rewrite_ttl' "$APP/settings.js" | cut -d: -f2)
echo "$dns_block" | grep -q 'bootstrap_dns_server' && \
    echo "$dns_block" | grep -q 'fallback_dns_server' && ok || bad "fallback not alongside DNS fields"
n_bootstrap=$(grep -c '"bootstrap_dns_server"' "$APP/settings.js")
n_fallback=$(grep -c '"fallback_dns_server"' "$APP/settings.js")
[ "$n_bootstrap" -ge 1 ] && [ "$n_fallback" -ge 1 ] && ok || bad "option counts ($n_bootstrap/$n_fallback)"

# --- ru locale: new msgids present and compiled cleanly ------------------------
for msgid in "DNS failover chain" "Yandex + provider (recommended)" \
    "Set a resolver chain or 0 to disable failover" "Invalid entry %s: %s"; do
    grep -q "msgid \"$msgid\"" "$PO" && ok || bad "po missing msgid: $msgid"
done
if command -v msgfmt >/dev/null; then
    msgfmt --check -o /dev/null "$PO" 2>/dev/null && ok || bad "msgfmt check failed: $(msgfmt --check -o /dev/null "$PO" 2>&1 | head -2)"
else
    bad "msgfmt not installed (apk add gettext)"
fi

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
