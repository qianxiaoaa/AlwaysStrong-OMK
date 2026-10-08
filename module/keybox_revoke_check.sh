#!/system/bin/sh
# AlwaysStrong — keybox revocation check.
#
# keybox_check.sh answers "will keymint accept this document?". This answers the
# other half: "will Google accept it?". They are different questions with the
# same symptom. A structurally perfect keybox whose leaf certificate has been
# revoked passes every local check, is loaded by keymint without complaint, and
# still fails every Play Integrity verdict — because the verdict is decided on
# Google's servers, against attestation/status, where the serial is listed. No
# local file can look wrong in that case, so the only way to catch it is to read
# the same list Google reads.
#
# Public keybox mirrors are the usual source of a revoked keybox: the key is
# shared by everyone who uses the mirror, so the moment it leaks it is revoked,
# and the mirror keeps serving it until someone notices.
#
# Usage: sh keybox_revoke_check.sh <keybox.xml> <status.json>
#
# Exit:
#   0  none of the keybox's certificates is on the list
#   1  REVOKED — at least one is; each hit is printed as "REVOKED serial=... reason=..."
#   2  cannot tell (missing arguments, no certificate found, no usable tools)
#
# Every certificate is checked, not just the leaf: a revoked intermediate is
# just as fatal, and the chain in a keybox is short enough that the extra work
# is not worth the special case.

KB="$1"
LIST="$2"

[ -s "$KB" ]   || { echo "keybox not readable: $KB"; exit 2; }
[ -s "$LIST" ] || { echo "status list not readable: $LIST"; exit 2; }

# ---- Resolve tools -------------------------------------------------------
# Same fallback shape keybox_fetch.sh uses: the shell builtins/toybox tools are
# usually present, busybox covers the ROMs where they are not.
B64DEC=""
if echo dGVzdA== | base64 -d >/dev/null 2>&1; then
    B64DEC="base64 -d"
else
    for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$bb" ] && echo dGVzdA== | "$bb" base64 -d >/dev/null 2>&1; then
            B64DEC="$bb base64 -d"; break
        fi
    done
fi
[ -z "$B64DEC" ] && { echo "no base64 decoder available"; exit 2; }

OD=""
if od -An -tx1 </dev/null >/dev/null 2>&1; then
    OD="od"
else
    for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$bb" ] && "$bb" od -An -tx1 </dev/null >/dev/null 2>&1; then
            OD="$bb od"; break
        fi
    done
fi
[ -z "$OD" ] && { echo "no od available"; exit 2; }

command -v awk >/dev/null 2>&1 || { echo "no awk available"; exit 2; }

# ---- DER serial extractor ------------------------------------------------
# tbsCertificate.serialNumber, emitted two ways: lowercase hex with no leading
# zeros, and its decimal value. Google's attestation/status list (and the
# mirrors of it) key each entry by the serial's *decimal* value, while older or
# synthetic lists used hex. Printing both lets the loop below match either.
# Walk Certificate SEQUENCE -> tbsCertificate SEQUENCE -> optional [0] version
# -> INTEGER serialNumber, on the hex dump of the DER so no binary handling is
# needed. The decimal value is built with string arithmetic (muladd/hex2dec):
# serials are ~128-bit, far past awk's 2^53 integer range, so converting via
# floating point would silently produce the wrong digits and miss every match.
DER_AWK='
function hexval(x,   i, c, v, d, m) {
    v = 0
    m = "0123456789abcdef"
    for (i = 1; i <= length(x); i++) {
        c = tolower(substr(x, i, 1))
        d = index(m, c) - 1
        if (d < 0) return -1
        v = v * 16 + d
    }
    return v
}
function tlv(p,   l0, k) {
    t_tag = substr(h, p * 2 + 1, 2)
    l0 = hexval(substr(h, p * 2 + 3, 2))
    if (l0 < 128) {
        t_len = l0
        t_content = p + 2
    } else {
        k = l0 - 128
        t_len = hexval(substr(h, p * 2 + 4, k * 2))
        t_content = p + 2 + k
    }
}
function muladd(s, m, a,   i, carry, d, res) {
    carry = a; res = ""
    for (i = length(s); i >= 1; i--) {
        d = (substr(s, i, 1) + 0) * m + carry
        res = (d % 10) res
        carry = int(d / 10)
    }
    while (carry > 0) { res = (carry % 10) res; carry = int(carry / 10) }
    sub(/^0+/, "", res)
    if (res == "") res = "0"
    return res
}
function hex2dec(h,   i, d, out) {
    out = "0"
    for (i = 1; i <= length(h); i++) {
        d = index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
        out = muladd(out, 16, d)
    }
    return out
}
{
    h = $0
    gsub(/[^0-9a-fA-F]/, "", h)
    if (length(h) < 32) { print "ERR"; exit }
    tlv(0)
    if (t_tag != "30") { print "ERR"; exit }
    p = t_content
    tlv(p)
    if (t_tag != "30") { print "ERR"; exit }
    p = t_content
    tlv(p)
    if (t_tag == "a0") { p = t_content + t_len; tlv(p) }
    if (t_tag != "02") { print "ERR"; exit }
    s = substr(h, t_content * 2 + 1, t_len * 2)
    sub(/^0+/, "", s)
    if (s == "") s = "0"
    s = tolower(s)
    print s " " hex2dec(s)
    exit
}'

# One base64 blob per <Certificate>, in document order.
CERTS=$(awk '
    /-----BEGIN CERTIFICATE-----/ { inb = 1; buf = ""; next }
    /-----END CERTIFICATE-----/   { if (inb) { print buf; inb = 0 } next }
    inb { gsub(/[^A-Za-z0-9+\/=]/, "", $0); buf = buf $0 }
' "$KB" 2>/dev/null)

[ -n "$CERTS" ] || { echo "no certificate found in $KB"; exit 2; }

# The list is pretty-printed with the serial on one line and its status/reason on
# the next, so flattening it once is what makes the per-certificate match (and
# the field extraction below) a single-line job.
FLAT=$(tr -d '\n\r\t' < "$LIST" 2>/dev/null)
[ -n "$FLAT" ] || { echo "status list has no usable content: $LIST"; exit 2; }

HITS=""
SEEN=0
while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _pair=$(printf '%s' "$_line" | $B64DEC 2>/dev/null | $OD -An -tx1 | tr -d ' \n' | awk "$DER_AWK" 2>/dev/null)
    case "$_pair" in ''|ERR) continue ;; esac
    _serial=${_pair% *}
    _serial_dec=${_pair#* }
    SEEN=$((SEEN + 1))
    # An entry object is flat JSON: {"status":"...","reason":"..."} with no nested
    # braces, so [^}]* reaches its end. Prefer the hex key (synthetic/legacy
    # lists), then fall back to the decimal key that Google and its mirrors use.
    _obj=$(printf '%s' "$FLAT" | grep -o -E "\"$_serial\"[ ]*:[ ]*\{[^}]*\}" | head -n 1)
    if [ -z "$_obj" ] && [ -n "$_serial_dec" ] && [ "$_serial_dec" != "$_serial" ]; then
        _obj=$(printf '%s' "$FLAT" | grep -o -E "\"$_serial_dec\"[ ]*:[ ]*\{[^}]*\}" | head -n 1)
    fi
    [ -n "$_obj" ] || continue
    _status=$(printf '%s' "$_obj" | sed -n 's/.*"status"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    _reason=$(printf '%s' "$_obj" | sed -n 's/.*"reason"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    # Only REVOKED is fatal. A listed entry with another status (EXPIRED, SOON on
    # the ?includeExpired= endpoint) must not fail the caller's gate, or a key that
    # still works gets refused. A listing with no status field is read as revoked.
    case "${_status:-REVOKED}" in REVOKED) ;; *) continue ;; esac
    _reason=${_reason:-${_status:-REVOKED}}
    HITS="${HITS}REVOKED serial=${_serial} reason=${_reason}
"
done <<EOF
$CERTS
EOF

[ "$SEEN" -gt 0 ] || { echo "no certificate could be parsed in $KB"; exit 2; }

if [ -n "$HITS" ]; then
    printf '%s' "$HITS"
    exit 1
fi

exit 0