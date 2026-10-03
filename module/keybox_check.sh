#!/system/bin/sh
# AlwaysStrong — keybox structure check.
#
# Answers one question: will OhMyKeymint actually accept this file?
#
# "It contains the string Keybox" is not that question. keymint parses the
# document and refuses it when a key entry is incomplete; and when it refuses
# the file it does NOT keep the previous keybox — it rewrites its own bundled
# template (the one with DeviceID="sw"), which is not a real attestation chain.
# Every Play Integrity verdict then goes red, so a user who swapped in a
# malformed keybox ends up strictly worse off than before they touched it: the
# usual "keybox revoked" state is two green and one red (BASIC + DEVICE pass,
# only STRONG fails), while a rejected keybox is three red.
#
# The checks below mirror what keymint enforces, in the order it complains:
#   * <AndroidAttestation> root carrying a <Keybox>
#   * <NumberOfKeyboxes> >= 1
#   * at least one <Key algorithm="rsa">  — without an RSA entry keymint logs
#     "missing RSA key entry in keybox.xml" and rejects the whole file
#   * every <Key> carries a <PrivateKey> with a PEM block and a
#     <CertificateChain> holding at least one certificate
#
# Callers use this to keep a bad keybox from ever reaching OMK's runtime dir;
# see keybox_fetch.sh, omk-sync.sh, omk-early.sh, action.sh and the WebUI.
#
# Scope: this is a structural check only. It does not verify signatures, match
# each leaf certificate against its private key, or consult Google's revocation
# list — a well-formed but revoked keybox passes here and still costs STRONG
# (that is the ordinary two-green-one-red state). What it does catch is the case
# that is strictly worse: a file keymint refuses outright, which takes all three
# verdicts down.
#
# Usage:
#   sh keybox_check.sh <keybox.xml>            # problems on stdout, exit code
#   sh keybox_check.sh --quiet <keybox.xml>    # exit code only
#
# Exit: 0 valid · 1 present but unusable · 2 missing / unreadable

QUIET=0
[ "$1" = "--quiet" ] && { QUIET=1; shift; }
KB="$1"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

if [ -z "$KB" ]; then
    say "no keybox path given"
    exit 2
fi
if [ ! -f "$KB" ]; then
    say "not a file: $KB"
    exit 2
fi
if [ ! -s "$KB" ]; then
    say "file is empty: $KB"
    exit 1
fi

# One pass over the file. The PEM bodies span lines, so the chain/private-key
# checks are driven by the BEGIN markers rather than by counting elements.
PROBLEMS=$(
awk '
    BEGIN { root = 0; kb = 0; nkb = ""; keys = 0; rsa = 0; certs = 0; bad = 0
            inkey = 0; inpk = 0; incc = 0 }

    function err(m) { print m; bad++ }

    # --- document level ---------------------------------------------------
    /<AndroidAttestation/ { root = 1 }
    /<Keybox/             { kb = 1 }
    /<NumberOfKeyboxes>/  {
        n = $0
        sub(/.*<NumberOfKeyboxes>/, "", n)
        sub(/<.*/, "", n)
        gsub(/[^0-9]/, "", n)
        nkb = n
    }

    # --- per key ----------------------------------------------------------
    # <Key algorithm="..."> opens a record; <Keybox ...> and </Key> never match
    # because of the algorithm= anchor.
    /<Key[[:space:]]+algorithm=/ {
        if (inkey) err("algorithm=\"" algo "\": <Key> block was never closed")
        inkey = 1
        algo = $0
        sub(/.*algorithm="/, "", algo)
        sub(/".*/, "", algo)
        pk = 0; pkpem = 0; cc = 0; cccert = 0; inpk = 0; incc = 0
        next
    }
    inkey && /<PrivateKey/   { pk = 1; inpk = 1 }
    inkey && inpk && /-----BEGIN[A-Z ]*PRIVATE KEY-----/ { pkpem = 1 }
    inkey && /<\/PrivateKey>/ { inpk = 0 }
    inkey && /<CertificateChain/ { cc = 1; incc = 1 }
    inkey && incc && /-----BEGIN CERTIFICATE-----/ { cccert++; certs++ }
    inkey && /<\/CertificateChain>/ { incc = 0 }
    inkey && /<\/Key>/ {
        keys++
        if (algo == "rsa") rsa++
        if (!pk)             err("algorithm=\"" algo "\": no <PrivateKey>")
        else if (!pkpem)     err("algorithm=\"" algo "\": <PrivateKey> has no PEM block")
        if (!cc)             err("algorithm=\"" algo "\": no <CertificateChain>")
        else if (cccert == 0) err("algorithm=\"" algo "\": <CertificateChain> has no certificate")
        inkey = 0
    }

    END {
        if (!root) err("no <AndroidAttestation> root element")
        if (!kb)   err("no <Keybox> element")
        if (nkb == "")          err("no <NumberOfKeyboxes>")
        else if (nkb + 0 < 1)   err("<NumberOfKeyboxes> is " nkb)
        if (keys == 0) err("no <Key> entry at all")
        if (keys > 0 && rsa == 0)
            err("no <Key algorithm=\"rsa\"> entry — keymint rejects the whole file without one")
        if (certs == 0) err("no certificate anywhere in the file")
        exit (bad > 0 ? 1 : 0)
    }
' "$KB"
)
rc=$?

[ -n "$PROBLEMS" ] && say "$PROBLEMS"
exit "$rc"
