#!/bin/sh
# Unit tests for the podkop DNS-failover helpers plus the sing-box config glue.
# Runs under busybox ash (alpine container mirrors the OpenWrt shell):
#   docker run --rm -v /path/to/fork:/repo alpine:3.20 \
#       sh -c 'apk add -q jq && sh /repo/podkop/tests/dns_failover_test.sh'

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="$TEST_DIR/../files/usr/lib"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

assert_eq() { # actual expected label
    [ "$1" = "$2" ] && ok || bad "$3: expected [$2] got [$1]"
}

assert_rc() { # actual_rc expected_rc label
    [ "$1" -eq "$2" ] && ok || bad "$3: expected rc=$2 got rc=$1"
}

# --- fixtures ---------------------------------------------------------------

cat > "$TMP/resolv.auto" <<'EOF'
# Interface wan
nameserver 217.14.192.175
nameserver 217.14.201.11
# Interface wan_6
nameserver 2a02:6b8::feed:0ff
nameserver fd00::1
EOF

mkdir "$TMP/bin"

# dig stub: policy file maps "<server>|<rc>|<stdout>"; calls are logged
cat > "$TMP/bin/dig" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP/dig_calls"
server=""
for a in "\$@"; do
    case "\$a" in @*) server="\${a#@}" ;; esac
done
line=\$(grep -m1 "^\$server|" "$TMP/dig_policy" 2>/dev/null || true)
[ -z "\$line" ] && exit 1
rc=\$(echo "\$line" | cut -d'|' -f2)
out=\$(echo "\$line" | cut -d'|' -f3-)
[ -n "\$out" ] && echo "\$out"
exit "\$rc"
EOF
chmod +x "$TMP/bin/dig"
: > "$TMP/dig_calls"
: > "$TMP/dig_policy"

PATH="$TMP/bin:$PATH"

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
# after constants.sh: it hardcodes the router path, tests need the fixture
export RESOLV_CONF_AUTO="$TMP/resolv.auto"

dig_set() { # server rc [stdout]
    echo "$1|$2|${3-}" >> "$TMP/dig_policy"
}

dig_called_with() { # substring label
    grep -q "$1" "$TMP/dig_calls" && ok || bad "$2: dig not called with [$1], calls: $(cat "$TMP/dig_calls")"
}

# --- T1: get_dhcp_dns filters IPv4 only, keeps order ------------------------
assert_eq "$(get_dhcp_dns | tr '\n' ' ')" "217.14.192.175 217.14.201.11 " "T1 dhcp dns"

# --- T2: dns_probe alive / dead / args --------------------------------------
dig_set 8.8.4.4 0 "93.184.216.34"
dns_probe 8.8.4.4; assert_rc $? 0 "T2 probe alive"
dig_set 1.2.3.4 9
dns_probe 1.2.3.4; assert_rc $? 1 "T2 probe dead"
dns_probe ""; assert_rc $? 1 "T2 probe empty"
dig_called_with "@8.8.4.4 $DNS_PROBE_DOMAIN" "T2 probe args"
dig_called_with "+tries=1" "T2 probe timeout flag"

# --- T3: dns_probe_target_ip (IP as-is, hostname via bootstrap) -------------
dig_set 77.88.8.8 0 "8.8.8.8
8.8.4.4"
assert_eq "$(dns_probe_target_ip "dns.google" "77.88.8.8")" "8.8.8.8" "T3 hostname resolves"
dig_called_with "@77.88.8.8 dns.google" "T3 resolves via bootstrap, not system resolver"
assert_eq "$(dns_probe_target_ip "8.8.8.8" "")" "8.8.8.8" "T3 IP passthrough"
dig_set 9.9.9.9 9
dns_probe_target_ip "unresolvable.example" "9.9.9.9" >/dev/null; assert_rc $? 1 "T3 dead bootstrap"

# --- T4: fallback_chain_pick (policy reset per case) --------------------------
dig_reset() { : > "$TMP/dig_policy"; }
dig_set 217.14.201.11 0 "5.255.255.242"

dig_reset
dig_set 217.14.201.11 0 "5.255.255.242"
assert_eq "$(fallback_chain_pick "1.1.1.1,dhcp")" "217.14.201.11" "T4 chain dead-ip then dhcp"

dig_reset
assert_eq "$(fallback_chain_pick " 9.9.9.9 , 77.88.8.8 ")" "" "T4 spaces: all dead -> empty"

dig_reset
dig_set 77.88.8.7 0 "77.88.55.242"
assert_eq "$(fallback_chain_pick " 9.9.9.9 , 77.88.8.7 ")" "77.88.8.7" "T4 spaces trimmed, later entry wins"

dig_reset
dig_set 217.14.201.11 0 "5.255.255.242"
assert_eq "$(fallback_chain_pick "dhcp")" "217.14.201.11" "T4 dhcp-only chain"
assert_eq "$(fallback_chain_pick "")" "" "T4 empty chain"

# --- T5: dns_health_evaluate truth table -------------------------------------
assert_eq "$(dns_health_evaluate ok 0 1 3)" "ok 0 none" "T5 ok stays"
assert_eq "$(dns_health_evaluate ok 0 0 3)" "ok 1 none" "T5 first fail"
assert_eq "$(dns_health_evaluate ok 2 0 3)" "fail 0 reload" "T5 third fail flips"
assert_eq "$(dns_health_evaluate fail 0 0 3)" "fail 0 none" "T5 fail stays"
assert_eq "$(dns_health_evaluate fail 0 1 3)" "fail 1 none" "T5 first recovery"
assert_eq "$(dns_health_evaluate fail 2 1 3)" "ok 0 reload" "T5 third recovery flips"
assert_eq "$(dns_health_evaluate weird 7 0 3)" "ok 1 none" "T5 garbage mode reset"
assert_eq "$(dns_health_evaluate ok garbage 0 3)" "ok 1 none" "T5 garbage counter reset"
assert_eq "$(dns_health_evaluate ok 5 0 3)" "fail 0 reload" "T5 over-threshold still flips"

# --- T6: sing-box config glue (real config-manager + jq) ----------------------
. "$LIB/sing_box_config_manager.sh"

CONFIG='{}'
CONFIG=$(sing_box_cm_configure_dns "$CONFIG" "$SB_FALLBACK_DNS_SERVER_TAG" "ipv4_only" true)
CONFIG=$(sing_box_cm_add_udp_dns_server "$CONFIG" "$SB_BOOTSTRAP_SERVER_TAG" "77.88.8.8" 53)
CONFIG=$(sing_box_cm_add_udp_dns_server "$CONFIG" "$SB_FALLBACK_DNS_SERVER_TAG" "217.14.201.11" 53)
CONFIG=$(sing_box_cm_add_fakeip_dns_server "$CONFIG" "$SB_FAKEIP_DNS_SERVER_TAG" "198.18.0.0/15" "")
CONFIG=$(sing_box_cm_add_dns_route_rule "$CONFIG" "$SB_FAKEIP_DNS_SERVER_TAG" "$SB_FAKEIP_DNS_RULE_TAG")

assert_eq "$(echo "$CONFIG" | jq -r '.dns.final')" "$SB_FALLBACK_DNS_SERVER_TAG" "T6 final=fallback"
assert_eq "$(echo "$CONFIG" | jq -r '.dns.servers | length')" "3" "T6 server count"
assert_eq "$(echo "$CONFIG" | jq -r '.dns.servers[] | select(.tag=="fallback-dns-server") | .type + " " + .server + ":" + (.server_port|tostring)')" \
    "udp 217.14.201.11:53" "T6 fallback server object"
assert_eq "$(echo "$CONFIG" | jq -r '[.dns.rules[] | select(.server=="fakeip-server")] | length')" "1" "T6 fakeip rule present"

# happy path: no failover, final = main
CONFIG2='{}'
CONFIG2=$(sing_box_cm_configure_dns "$CONFIG2" "$SB_DNS_SERVER_TAG" "ipv4_only" true)
CONFIG2=$(sing_box_cm_add_udp_dns_server "$CONFIG2" "$SB_BOOTSTRAP_SERVER_TAG" "77.88.8.8" 53)
assert_eq "$(echo "$CONFIG2" | jq -r '.dns.final')" "$SB_DNS_SERVER_TAG" "T6b final=main"
assert_eq "$(echo "$CONFIG2" | jq -r '.dns.servers | length')" "1" "T6b no fallback object"

# --- summary ------------------------------------------------------------------
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
