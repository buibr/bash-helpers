#!/bin/bash
# bi-arg: @none
#
# bi-web-dns.sh - full DNS / mail / TLS report for a domain
#
# Usage: bi-web-dns.sh <domain> [resolver]
#   bi-web-dns.sh example.com
#   bi-web-dns.sh example.com 1.1.1.1
#   bi-web-dns.sh https://www.example.com/path   (URL is stripped to host)

set -u

if [ $# -lt 1 ]; then
    echo "Usage: $0 <domain> [resolver]"
    exit 1
fi

if ! command -v dig >/dev/null; then
    echo "dig is required (apt install dnsutils / bind-utils)"
    exit 1
fi

# Normalize input: strip scheme, path, port, trailing dot, lowercase
DOMAIN=$(echo "$1" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:[0-9]+$##; s#\.$##' | tr 'A-Z' 'a-z')
RESOLVER="${2:-}"
AT=""
[ -n "$RESOLVER" ] && AT="@$RESOLVER"

# Colors (disabled when not a terminal)
if [ -t 1 ]; then
    B=$'\e[1m'; C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
else
    B=""; C=""; G=""; Y=""; R=""; D=""; N=""
fi

section() { printf '\n%s%s== %s ==%s\n' "$B" "$C" "$1" "$N"; }
label()   { printf '  %s%-12s%s ' "$B" "$1" "$N"; }
none()    { printf '%s(none)%s\n' "$D" "$N"; }
ok()      { printf '  %s✔ %s%s\n' "$G" "$1" "$N"; }
warn()    { printf '  %s⚠ %s%s\n' "$Y" "$1" "$N"; }
bad()     { printf '  %s✘ %s%s\n' "$R" "$1" "$N"; }

# q <name> <type> [@server] - print rdata of matching answers only (drops CNAME chain)
q() {
    local name="$1" type="$2" srv="${3:-$AT}"
    dig $srv +noall +answer +time=3 +tries=2 "$name" "$type" 2>/dev/null \
        | awk -v t="$type" '$4 == t { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print }'
}

# Print records indented under a label
show() {
    local name="$1" type="$2" out
    out=$(q "$name" "$type")
    # +short includes the CNAME chain; keep only real addresses for A/AAAA
    [ "$type" = "A" ] && out=$(echo "$out" | grep -E '^[0-9.]+$')
    [ "$type" = "AAAA" ] && out=$(echo "$out" | grep -E '^[0-9a-fA-F:]+$')
    label "$type"
    if [ -z "$out" ]; then
        none
    else
        echo "$out" | head -1
        echo "$out" | tail -n +2 | sed 's/^/               /'
    fi
}

printf '%sDNS report for %s%s%s' "$B" "$Y" "$DOMAIN" "$N"
[ -n "$RESOLVER" ] && printf ' (resolver %s)' "$RESOLVER"
printf '  %s%s%s\n' "$D" "$(date '+%Y-%m-%d %H:%M:%S')" "$N"

# ---------------------------------------------------------------------------
section "Basic records"
for t in A AAAA CNAME NS SOA MX TXT CAA HTTPS SVCB NAPTR LOC HINFO RP SSHFP; do
    show "$DOMAIN" "$t"
done

if [[ "$DOMAIN" != www.* ]]; then
    section "www.$DOMAIN"
    for t in A AAAA CNAME; do show "www.$DOMAIN" "$t"; done
fi

# ---------------------------------------------------------------------------
section "SOA details"
SOA=$(q "$DOMAIN" SOA | head -1)
if [ -n "$SOA" ]; then
    read -r MNAME RNAME SERIAL REFRESH RETRY EXPIRE MINTTL <<< "$SOA"
    label "Primary NS"; echo "$MNAME"
    label "Admin";      echo "$(echo "${RNAME%.}" | sed 's/\./@/')"
    label "Serial";     echo "$SERIAL"
    label "Refresh";    echo "${REFRESH}s"
    label "Retry";      echo "${RETRY}s"
    label "Expire";     echo "${EXPIRE}s"
    label "Min TTL";    echo "${MINTTL}s"
else
    warn "No SOA record (not a zone apex?)"
fi

# ---------------------------------------------------------------------------
section "IP addresses, reverse DNS (PTR) & ownership"
IPS=$( (q "$DOMAIN" A; q "$DOMAIN" AAAA) | grep -E '^[0-9a-fA-F:.]+$' | sort -u)
if [ -z "$IPS" ]; then
    none
else
    for ip in $IPS; do
        ptr=$(dig $AT +short -x "$ip" 2>/dev/null | head -3 | tr '\n' ' ')
        printf '  %s%-40s%s PTR: %s\n' "$B" "$ip" "$N" "${ptr:-${D}(none)${N}}"
        # Forward-confirmed reverse DNS
        if [ -n "$ptr" ]; then
            first=$(echo "$ptr" | awk '{print $1}')
            fwd=$( (q "$first" A; q "$first" AAAA) )
            if echo "$fwd" | grep -qx "$ip"; then
                printf '  %-40s %sFCrDNS: match%s\n' "" "$G" "$N"
            else
                printf '  %-40s %sFCrDNS: mismatch%s\n' "" "$Y" "$N"
            fi
        fi
        # ASN / owner via Team Cymru DNS (no API key needed)
        if [[ "$ip" == *.* ]]; then
            rev=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
            asn=$(dig +short +time=3 "$rev.origin.asn.cymru.com" TXT 2>/dev/null | tr -d '"' | head -1)
            if [ -n "$asn" ]; then
                asnum=$(echo "$asn" | awk -F' \\| ' '{print $1}' | awk '{print $1}')
                owner=$(dig +short +time=3 "AS$asnum.asn.cymru.com" TXT 2>/dev/null | tr -d '"' | awk -F' \\| ' '{print $NF}')
                printf '  %-40s ASN: AS%s  %s\n' "" "$asn" "${owner:+($owner)}" | sed 's/AS\([0-9]*\) | /AS\1  prefix /; s/ | / cc=/; s/ | / rir=/; s/ | / since=/'
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
section "Name servers"
NSS=$(q "$DOMAIN" NS | sed 's/\.$//')
if [ -z "$NSS" ]; then
    none
else
    declare -A SERIALS
    for ns in $NSS; do
        nsip=$(q "$ns" A | head -1)
        nsip6=$(q "$ns" AAAA | head -1)
        serial=$(dig +short +time=3 +tries=1 @"$ns" "$DOMAIN" SOA 2>/dev/null | awk '{print $3}')
        SERIALS["$ns"]="$serial"
        printf '  %s%-32s%s %-16s %-26s serial=%s\n' "$B" "$ns" "$N" "${nsip:--}" "${nsip6:--}" "${serial:-${R}no answer${N}}"
    done
    uniq_serials=$(printf '%s\n' "${SERIALS[@]}" | grep -v '^$' | sort -u | wc -l)
    [ "$uniq_serials" -le 1 ] && ok "All name servers report the same SOA serial" || warn "SOA serial mismatch between name servers"
    nscount=$(echo "$NSS" | wc -l)
    [ "$nscount" -ge 2 ] && ok "$nscount name servers (≥2 recommended)" || warn "Only $nscount name server"

    # Zone transfer test (should be refused)
    for ns in $NSS; do
        axfr=$(dig +time=3 +tries=1 @"$ns" "$DOMAIN" AXFR 2>/dev/null | grep -vE '^;|^$' | wc -l)
        if [ "$axfr" -gt 1 ]; then
            bad "AXFR allowed on $ns ($axfr records leaked)"
        else
            ok "AXFR refused on $ns"
        fi
    done
fi

# ---------------------------------------------------------------------------
section "Mail (MX, SPF, DMARC, DKIM, MTA-STS, TLS-RPT, BIMI)"
MX=$(q "$DOMAIN" MX | sort -n)
if [ -z "$MX" ]; then
    label "MX"; none
else
    while read -r prio host; do
        host=${host%.}
        mxip=$(q "$host" A | head -1)
        mxptr=""
        [ -n "$mxip" ] && mxptr=$(dig $AT +short -x "$mxip" 2>/dev/null | head -1)
        printf '  %s%-4s%s %-36s %-16s PTR: %s\n' "$B" "$prio" "$N" "$host" "${mxip:--}" "${mxptr:-${D}(none)${N}}"
    done <<< "$MX"
fi

SPF=$(q "$DOMAIN" TXT | sed 's/" "//g' | tr -d '"' | grep -i '^v=spf1')
label "SPF"; echo "${SPF:-${R}(missing)${N}}"
if [ -n "$SPF" ]; then
    [ "$(echo "$SPF" | wc -l)" -gt 1 ] && bad "Multiple SPF records (invalid)"
    lookups=$(echo "$SPF" | grep -oE '(include:|a[:/ ]|mx[:/ ]|ptr|exists:|redirect=)' | wc -l)
    [ "$lookups" -le 10 ] && ok "SPF top-level DNS lookups: $lookups (limit 10, includes not expanded)" || bad "SPF lookups: $lookups (>10)"
    case "$SPF" in
        *"-all"*) ok "SPF policy: hard fail (-all)";;
        *"~all"*) warn "SPF policy: soft fail (~all)";;
        *"+all"*) bad "SPF policy: +all (anyone can send!)";;
        *"?all"*) warn "SPF policy: neutral (?all)";;
    esac
fi

DMARC=$(q "_dmarc.$DOMAIN" TXT | sed 's/" "//g' | tr -d '"')
label "DMARC"; echo "${DMARC:-${R}(missing)${N}}"
if [ -n "$DMARC" ]; then
    p=$(echo "$DMARC" | grep -oE 'p=[a-z]+' | head -1 | cut -d= -f2)
    case "$p" in
        reject)     ok "DMARC policy: reject";;
        quarantine) ok "DMARC policy: quarantine";;
        none)       warn "DMARC policy: none (monitoring only)";;
    esac
fi

label "DKIM"
found=""
for sel in default google selector1 selector2 k1 k2 k3 s1 s2 dkim mail smtp mx \
           mandrill mailjet sendgrid smtpapi pm postmark mxvault zoho everlytickey1 \
           everlytickey2 amazonses ses cm fm1 fm2 fm3 protonmail protonmail2 protonmail3 \
           mailo hs1 hs2 krs sig1 key1 key2 litesrv 20161025 20210112 20230601 ; do
    cn=$(q "$sel._domainkey.$DOMAIN" CNAME | head -1)
    r=$(q "$sel._domainkey.$DOMAIN" TXT | sed 's/" "//g' | tr -d '"\n')
    if [ -n "$r$cn" ]; then
        [ -z "$found" ] && echo ""
        [ -n "$cn" ] && r="→ $cn  $r"
        printf '               %s%s%s: %s\n' "$G" "$sel" "$N" "$(echo "$r" | cut -c1-110)$( [ ${#r} -gt 110 ] && echo '…')"
        found=1
    fi
done
[ -z "$found" ] && printf '%s(no common selector found)%s\n' "$D" "$N"

for rec in "_mta-sts" "_smtp._tls" "default._bimi"; do
    r=$(q "$rec.$DOMAIN" TXT | tr -d '"')
    label "${rec#_}" ; echo "${r:-${D}(none)${N}}"
done
if [ -n "$(q "_mta-sts.$DOMAIN" TXT)" ] && command -v curl >/dev/null; then
    pol=$(curl -s --max-time 5 "https://mta-sts.$DOMAIN/.well-known/mta-sts.txt")
    [ -n "$pol" ] && echo "$pol" | sed 's/^/               /'
fi

# ---------------------------------------------------------------------------
section "Common SRV / service records"
for srv in _sip._tcp _sip._udp _sips._tcp _xmpp-client._tcp _xmpp-server._tcp \
           _autodiscover._tcp _imap._tcp _imaps._tcp _pop3._tcp _pop3s._tcp \
           _submission._tcp _submissions._tcp _caldav._tcp _caldavs._tcp \
           _carddav._tcp _carddavs._tcp _ldap._tcp _kerberos._tcp _kerberos._udp \
           _matrix._tcp _minecraft._tcp _ts3._udp _h323cs._tcp _jabber._tcp; do
    r=$(q "$srv.$DOMAIN" SRV)
    [ -n "$r" ] && printf '  %s%-20s%s %s\n' "$B" "$srv" "$N" "$(echo "$r" | tr '\n' ' ')"
done
printf '  %s(only existing SRV records shown)%s\n' "$D" "$N"

section "Common subdomains"
for sub in mail webmail smtp imap pop ftp autodiscover autoconfig cpanel webdisk \
           api app dev staging test admin portal vpn remote blog shop cdn static m ns1 ns2; do
    r=$(q "$sub.$DOMAIN" A | tail -1)
    c=$(q "$sub.$DOMAIN" CNAME | head -1)
    [ -n "$r$c" ] && printf '  %s%-14s%s %-16s %s\n' "$B" "$sub" "$N" "${r:--}" "${c:+→ $c}"
done
printf '  %s(only resolving subdomains shown)%s\n' "$D" "$N"

# ---------------------------------------------------------------------------
section "DNSSEC"
show "$DOMAIN" DS
DNSKEY=$(q "$DOMAIN" DNSKEY)
label "DNSKEY"
if [ -n "$DNSKEY" ]; then
    echo "$(echo "$DNSKEY" | wc -l) key(s): $(echo "$DNSKEY" | awk '{print ($1==257?"KSK":"ZSK")" alg="$3}' | tr '\n' ' ')"
else
    none
fi
adflag=$(dig $AT +dnssec +time=3 "$DOMAIN" A 2>/dev/null | grep -E '^;; flags:' | grep -o ' ad')
if [ -n "$adflag" ]; then
    ok "Resolver validated DNSSEC (AD flag set)"
elif [ -n "$DNSKEY" ]; then
    warn "DNSKEY present but response not validated (resolver may not validate)"
else
    warn "DNSSEC not enabled"
fi

# ---------------------------------------------------------------------------
section "Propagation across public resolvers (A / MX / NS)"
printf '  %s%-26s %-34s %-42s %s%s\n' "$B" "Resolver" "A" "MX" "NS" "$N"
for r in "Google:8.8.8.8" "Cloudflare:1.1.1.1" "Quad9:9.9.9.9" "OpenDNS:208.67.222.222" \
         "AdGuard:94.140.14.14" "Level3:4.2.2.2" "Yandex:77.88.8.8"; do
    name=${r%%:*}; ip=${r#*:}
    a=$(q "$DOMAIN" A "@$ip" | sort | tr '\n' ' ')
    mx=$(q "$DOMAIN" MX "@$ip" | sort -n | head -2 | awk '{print $2}' | tr '\n' ' ')
    ns=$(q "$DOMAIN" NS "@$ip" | sort | head -2 | tr '\n' ' ')
    printf '  %-26s %-34s %-42s %s\n' "$name ($ip)" "${a:--}" "${mx:--}" "${ns:--}"
done

# ---------------------------------------------------------------------------
section "Delegation trace (root → TLD → authoritative)"
dig +trace +nodnssec +time=3 "$DOMAIN" A 2>/dev/null \
    | grep -E 'IN\s+(NS|A)\s|^;; Received' \
    | awk '/^;; Received/ {printf "  %s\n", $0; next} {printf "    %-30s %-6s %s\n", $1, $4, $5}' \
    | head -40

# ---------------------------------------------------------------------------
if command -v openssl >/dev/null && [ -n "$IPS" ]; then
    section "TLS certificate (port 443)"
    cert=$(echo | timeout 6 openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null \
           | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null)
    if [ -n "$cert" ]; then
        echo "$cert" | sed 's/^/  /'
        end=$(echo "$cert" | grep notAfter | cut -d= -f2)
        days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
        if [ "$days" -lt 0 ]; then bad "Certificate EXPIRED $((-days)) days ago"
        elif [ "$days" -lt 14 ]; then warn "Certificate expires in $days days"
        else ok "Certificate valid for $days more days"; fi
    else
        warn "No TLS on port 443 or connection failed"
    fi
fi

# ---------------------------------------------------------------------------
section "WHOIS / registration"
if command -v whois >/dev/null; then
    whois "$DOMAIN" 2>/dev/null \
        | grep -iE '^\s*(registrar:|registrar url|creation date|created|updated date|registry expiry|expir|registrant (organization|country)|domain status|name server|dnssec)' \
        | sed 's/^\s*/  /' | sort -u | head -25
elif command -v curl >/dev/null; then
    # RDAP fallback (no whois binary needed)
    curl -s --max-time 8 -L "https://rdap.org/domain/$DOMAIN" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (RDAP lookup failed)"); sys.exit()
for e in d.get("events", []):
    print("  %-22s %s" % (e.get("eventAction", "") + ":", e.get("eventDate", "")))
for ent in d.get("entities", []):
    if "registrar" in ent.get("roles", []):
        name = next((v[3] for v in ent.get("vcardArray", [None, []])[1] if v[0] == "fn"), "?")
        print("  %-22s %s" % ("registrar:", name))
print("  %-22s %s" % ("status:", ", ".join(d.get("status", []))))
print("  %-22s %s" % ("nameservers:", " ".join(n.get("ldhName", "") for n in d.get("nameservers", []))))
' 2>/dev/null || echo "  (install whois or python3 for registration data)"
else
    echo "  (install whois for registration data)"
fi

echo
