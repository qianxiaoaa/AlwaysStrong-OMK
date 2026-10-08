// verify_tool — minimal Ed25519 detached-signature verifier for AlwaysStrong.
//
// The module trusts a signing key, not a server: the public key is bundled at
// module/pubkey.b64, and every downloaded payload (module update zip, keybox)
// carries a base64 detached signature that must verify against it. That is what
// makes it safe to fetch a zip from any mirror or CDN — a tampered file cannot
// produce a valid signature.
//
// Implemented in Go so the binary is a single static file with no runtime and
// can be cross-compiled for every Android ABI from any host (see
// scripts/build-verifier.sh). The signing side lives in the release workflow and
// uses the ALWAYSSTRONG_SIGNING_KEY secret.
//
// usage: verify_tool <pubkey.b64> <signature.b64> <data_file>
// exit:  0 verified · 1 bad signature · 2 usage/IO/parse error
//
// Design modelled on yypm's verify_tool.go (which inspired this port); this is
// an independent implementation.
package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
)

func readTrimmed(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "verify_tool:", err)
	os.Exit(2)
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: verify_tool <pubkey.b64> <signature.b64> <data_file>")
		os.Exit(2)
	}

	pubB64, err := readTrimmed(os.Args[1])
	if err != nil {
		fatal(err)
	}
	sigB64, err := readTrimmed(os.Args[2])
	if err != nil {
		fatal(err)
	}
	data, err := os.ReadFile(os.Args[3])
	if err != nil {
		fatal(err)
	}

	pub, err := base64.StdEncoding.DecodeString(pubB64)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		os.Exit(2)
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		os.Exit(2)
	}

	if ed25519.Verify(ed25519.PublicKey(pub), data, sig) {
		fmt.Println("OK")
		return
	}
	os.Exit(1)
}
