#!/bin/sh
# Package-level integration test for the podkop DNS-failover feature.
# Unpacks the built apk, fakes the OpenWrt environment (uci mocks, dig/pidof/
# logger stubs, reload interception) and drives the real shipped code:
#   P0: package layout and build substitutions
#   P1: /usr/bin/podkop dns-health end-to-end (hysteresis + reload trigger)
#   P2: real sing_box_configure_dns under every failover scenario, jq asserts
#       on the generated DNS section
# Must run as root in a disposable container (files are installed into /):
#   docker run --rm \
#       -v /path/to/fork:/repo:ro \
#       -v /path/to/firmware:/fw:ro \
#       alpine:edge sh /repo/podkop/tests/pkg_dns_failover_test.sh \
#       /fw/local/podkop-0.7.24_p2-r1.apk

APK="${1:?usage: pkg_dns_failover_test.sh <podkop.apk>}"
[ -r "$APK" ] || { echo "apk not readable: $APK" >&2; exit 1; }

apk add -q jq >/dev/null 2>&1 || { echo "jq install failed" >&2; exit 1; }

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

assert_eq() { [ "$1" = "$2" ] && ok || bad "$3: expected [$2] got [$1]"; }
assert_rc() { [ "$1" -eq "$2" ] && ok || bad "$3: expected rc=$2 got rc=$1"; }
assert_file_has() { grep -q "$2" "$1" 2>/dev/null && ok || bad "$3: [$2] not found in $1"; }
assert_file_lacks() { grep -q "$2" "$1" 2>/dev/null && bad "$3: [$2] unexpectedly in $1" || ok; }

PT=/tmp/pt
rm -rf "$PT" /tmp/pkg
mkdir -p "$PT"

# --- P0: unpack and check the package ----------------------------------------

mkdir /tmp/pkg || exit 1
cd /tmp/pkg || exit 1
apk extract --allow-untrusted "$APK" >/dev/null 2>&1
[ -d /tmp/pkg/usr ] || { echo "extract failed" >&2; exit 1; }

[ -x usr/bin/podkop ] && ok || bad "P0 podkop binary not executable"
for f in constants.sh helpers.sh sing_box_config_manager.sh \
    sing_box_config_facade.sh logging.sh nft.sh rulesets.sh; do
    [ -f "usr/lib/podkop/$f" ] && ok || bad "P0 missing usr/lib/podkop/$f"
done
[ -f etc/config/podkop ] && ok || bad "P0 missing etc/config/podkop"
[ -f etc/init.d/podkop ] && ok || bad "P0 missing etc/init.d/podkop"
assert_file_has usr/lib/podkop/constants.sh 'DEFAULT_FALLBACK_DNS=' "P0 failover constants"
assert_file_has usr/lib/podkop/constants.sh 'SB_FALLBACK_DNS_SERVER_TAG=' "P0 failover tag"
assert_file_has usr/lib/podkop/helpers.sh 'fallback_chain_pick' "P0 helpers"
assert_file_has etc/config/podkop 'fallback_dns_server' "P0 default config option"
assert_file_has usr/bin/podkop 'dns-health' "P0 subcommand shipped"
assert_file_has usr/bin/podkop 'podkop_dns_health' "P0 watchdog function"
assert_file_lacks usr/lib/podkop/constants.sh '__COMPILED_VERSION_VARIABLE__' "P0 version substituted"

# --- install the package + mocks into the container root ---------------------

cp -r usr etc /
mv /usr/bin/podkop /usr/bin/podkop.real

cat > /usr/bin/podkop <<'EOF'
#!/bin/sh
echo "$@" >> /tmp/pt/podkop_calls
case "$1" in
dns-health) exec /usr/bin/podkop.real "$@" ;;
*) exit 0 ;;
esac
EOF
chmod +x /usr/bin/podkop

mkdir -p /lib/config /lib/functions
: > /lib/config/uci.sh
: > /lib/functions/network.sh

cat > /lib/functions.sh <<'EOF'
_uci_option() {
    UCI_SEC="$1" UCI_OPT="$2" awk '
        function clean(s) { gsub(/'\''/, "", s); return s }
        /^config[ \t]/ { cur = clean($3); ins = (cur == ENVIRON["UCI_SEC"]) }
        ins && $1 == "option" && $2 == ENVIRON["UCI_OPT"] {
            sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, ""); print clean($0); exit
        }' /etc/config/podkop 2>/dev/null
}
config_load() { :; }
config_get() {
    local _v
    _v="$(_uci_option "$2" "$3")"
    eval "$1=\"\${_v:-\$4}\""
}
config_get_bool() {
    local _v
    _v="$(_uci_option "$2" "$3")"
    [ "$_v" = "1" ] && { eval "$1=1"; return; }
    eval "$1=\${4:-0}"
}
EOF

mkdir -p /stubbin

cat > /stubbin/dig <<EOF
#!/bin/sh
echo "\$*" >> "$PT/dig_calls"
server=""
for a in "\$@"; do
    case "\$a" in @*) server="\${a#@}" ;; esac
done
line=\$(grep -m1 "^\$server|" "$PT/dig_policy" 2>/dev/null || true)
[ -z "\$line" ] && exit 1
rc=\$(echo "\$line" | cut -d'|' -f2)
out=\$(echo "\$line" | cut -d'|' -f3-)
[ -n "\$out" ] && echo "\$out"
exit "\$rc"
EOF

cat > /stubbin/pidof <<EOF
#!/bin/sh
cat "$PT/pidof_out" 2>/dev/null
EOF

cat > /stubbin/logger <<EOF
#!/bin/sh
echo "\$*" >> "$PT/logger_log"
EOF

chmod +x /stubbin/dig /stubbin/pidof /stubbin/logger
PATH="/stubbin:/usr/bin:/bin"
export PATH

: > "$PT/dig_calls"
: > "$PT/dig_policy"
: > "$PT/podkop_calls"
: > "$PT/logger_log"
: > "$PT/pidof_out"

cat > "$PT/resolv.auto" <<'EOF'
# Interface wan
nameserver 217.14.192.175
nameserver 217.14.201.11
EOF

write_cfg() { # dns_server dns_type bootstrap fallback
    cat > /etc/config/podkop <<EOF
config settings 'settings'
        option dns_type '$2'
        option dns_server '$1'
        option bootstrap_dns_server '$3'
        option fallback_dns_server '$4'
        option ipv6 '0'
EOF
}

dig_set() { echo "$1|$2|${3-}" >> "$PT/dig_policy"; }
dig_reset() { : > "$PT/dig_policy"; : > "$PT/dig_calls"; }
pidof_set() { echo "$1" > "$PT/pidof_out"; }

state() { cat /tmp/podkop_dns_health 2>/dev/null || echo NONE; }
reload_count() { local n; n=$(grep -c '^reload$' "$PT/podkop_calls" 2>/dev/null); echo "${n:-0}"; }

# --- P1: dns-health end-to-end ------------------------------------------------

RUN=/usr/bin/podkop

# S1: sing-box not running -> no-op
write_cfg 8.8.8.8 udp 77.88.8.8 "77.88.8.8,dhcp"
dig_reset; dig_set 8.8.8.8 0 "1.2.3.4"
rm -f /tmp/podkop_dns_health
pidof_set ""
"$RUN" dns-health; assert_rc $? 0 "S1 rc"
assert_eq "$(state)" "NONE" "S1 no state when sing-box down"
assert_eq "$(reload_count)" "0" "S1 no reload"

# S2..S7: full hysteresis cycle, sing-box running
pidof_set 1234
dig_reset; dig_set 8.8.8.8 0 "1.2.3.4"
rm -f /tmp/podkop_dns_health

"$RUN" dns-health; assert_eq "$(state)" "ok 0" "S2 fresh alive"

dig_reset; dig_set 8.8.8.8 9
"$RUN" dns-health; assert_eq "$(state)" "ok 1" "S3 first dead"
"$RUN" dns-health; assert_eq "$(state)" "ok 2" "S3 second dead"
assert_eq "$(reload_count)" "0" "S3 no premature reload"

"$RUN" dns-health; assert_eq "$(state)" "fail 0" "S4 flips to fail"
assert_eq "$(reload_count)" "1" "S4 reload fired"
assert_file_has "$PT/logger_log" "switching to fallback" "S4 warn logged"
"$RUN" dns-health; assert_eq "$(state)" "fail 0" "S5 stays fail"
assert_eq "$(reload_count)" "1" "S5 no extra reload"

dig_reset; dig_set 8.8.8.8 0 "1.2.3.4"
"$RUN" dns-health; assert_eq "$(state)" "fail 1" "S6 first recovery"
"$RUN" dns-health; assert_eq "$(state)" "fail 2" "S6 second recovery"
assert_eq "$(reload_count)" "1" "S6 no premature reload"
"$RUN" dns-health; assert_eq "$(state)" "ok 0" "S7 flips back to ok"
assert_eq "$(reload_count)" "2" "S7 reload fired"
assert_file_has "$PT/logger_log" "has recovered" "S7 recovery logged"

# S8: fallback disabled -> no-op even with dead main
write_cfg 8.8.8.8 udp 77.88.8.8 "0"
dig_reset; dig_set 8.8.8.8 9
rm -f /tmp/podkop_dns_health
"$RUN" dns-health; assert_rc $? 0 "S8 rc"
assert_eq "$(state)" "NONE" "S8 disabled writes no state"
assert_eq "$(reload_count)" "2" "S8 no reload when disabled"

# S9: hostname main resolves through bootstrap, then probe
write_cfg dns.google doh 77.88.8.8 "77.88.8.8,dhcp"
dig_reset; dig_set 77.88.8.8 0 "8.8.8.8"
rm -f /tmp/podkop_dns_health
"$RUN" dns-health
assert_eq "$(state)" "ok 1" "S9 hostname main counted dead"
assert_file_has "$PT/dig_calls" "@77.88.8.8 dns.google" "S9 resolved via bootstrap"

# --- P2: real sing_box_configure_dns under all scenarios ----------------------

. /lib/functions.sh
. /usr/lib/podkop/constants.sh
. /usr/lib/podkop/helpers.sh
. /usr/lib/podkop/sing_box_config_manager.sh
. /usr/lib/podkop/sing_box_config_facade.sh
. /usr/lib/podkop/logging.sh
RESOLV_CONF_AUTO="$PT/resolv.auto"
export RESOLV_CONF_AUTO

eval "$(sed -n '/^sing_box_configure_dns()/,/^}/p' /usr/bin/podkop.real)"
eval "$(sed -n '/^ipv6_enabled()/,/^}/p' /usr/bin/podkop.real)"

jq_get() { echo "$config" | jq -r "$1"; }

generate() { # dns_server dns_type bootstrap fallback — dig policy is set by the scenario
    write_cfg "$1" "$2" "$3" "$4"
    config='{}'
    sing_box_configure_dns > "$PT/gen_out" 2> "$PT/gen_err"
    [ -s "$PT/gen_err" ] && bad "generate($1,$4) stderr: $(head -3 "$PT/gen_err")"
}

# G1: main alive -> plain layout, no fallback object
dig_reset
dig_set 8.8.8.8 0 "1.2.3.4"
generate 8.8.8.8 udp 77.88.8.8 "77.88.8.8,dhcp"
assert_eq "$(jq_get '.dns.final')" "dns-server" "G1 final=main"
assert_eq "$(jq_get '.dns.servers | length')" "3" "G1 servers bootstrap+main+fakeip"
assert_eq "$(jq_get '[.dns.servers[] | select(.tag=="fallback-dns-server")] | length')" "0" "G1 no fallback object"
assert_eq "$(jq_get '[.dns.servers[] | select(.type=="fakeip")] | length')" "1" "G1 fakeip server kept"
assert_eq "$(jq_get '[.dns.rules[] | select(.action=="reject" and .domain_suffix=="use-application-dns.net")] | length')" "1" "G1 canary rule kept"

# G2: main dead, first chain entry alive
dig_reset
dig_set 8.8.8.8 9
dig_set 77.88.8.8 0 "5.255.255.242"
generate 8.8.8.8 udp 77.88.8.8 "77.88.8.8,dhcp"
assert_eq "$(jq_get '.dns.final')" "fallback-dns-server" "G2 final=fallback"
assert_eq "$(jq_get '.dns.servers[] | select(.tag=="fallback-dns-server") | .type + " " + .server + ":" + (.server_port|tostring)')" \
    "udp 77.88.8.8:53" "G2 fallback object"
assert_eq "$(jq_get '.dns.servers | length')" "4" "G2 servers count"
assert_file_has "$PT/logger_log" "using fallback '77.88.8.8'" "G2 warn logged"

# G3: main and yandex dead, second WAN resolver alive
dig_reset
dig_set 8.8.8.8 9
dig_set 77.88.8.8 9
dig_set 217.14.201.11 0 "5.255.255.242"
generate 8.8.8.8 udp 77.88.8.8 "77.88.8.8,dhcp"
assert_eq "$(jq_get '.dns.final')" "fallback-dns-server" "G3 final=fallback"
assert_eq "$(jq_get '.dns.servers[] | select(.tag=="fallback-dns-server") | .server')" "217.14.201.11" "G3 dhcp entry picked"

# G4: everything dead -> keep main, log error
dig_reset
generate 8.8.8.8 udp 77.88.8.8 "77.88.8.8,dhcp"
assert_eq "$(jq_get '.dns.final')" "dns-server" "G4 final stays main"
assert_eq "$(jq_get '.dns.servers | length')" "3" "G4 no fallback object"
assert_file_has "$PT/logger_log" "no fallback" "G4 error logged"

# G5: failover disabled -> never switches
dig_reset
dig_set 8.8.8.8 9
generate 8.8.8.8 udp 77.88.8.8 "0"
assert_eq "$(jq_get '.dns.final')" "dns-server" "G5 disabled keeps main"
assert_eq "$(jq_get '.dns.servers | length')" "3" "G5 no fallback object"

# G6: hostname main (DoH) resolves via bootstrap, that IP probed
dig_reset
dig_set 77.88.8.8 0 "8.8.8.8"
dig_set 8.8.8.8 0 "1.2.3.4"
generate dns.google doh 77.88.8.8 "77.88.8.8,dhcp"
assert_eq "$(jq_get '.dns.final')" "dns-server" "G6 hostname main alive"
assert_file_has "$PT/dig_calls" "@77.88.8.8 dns.google" "G6 main resolved via bootstrap"

# --- summary --------------------------------------------------------------------

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
