package main

import (
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	"github.com/elliottech/lighter-go/signer"
)

// The key arrives through the environment, never argv: /proc/<pid>/cmdline is
// world-readable while /proc/<pid>/environ is owner-only, and the Port helper
// this program sits beside already keeps signing keys off the command line.
const keyVar = "LIGHTER_SIGNER_API_PRIVATE_KEY"

func main() {
	if len(os.Args) != 1 {
		fmt.Fprintf(os.Stderr, "usage: %s=<40-byte-hex> derive_pubkey\n", keyVar)
		os.Exit(1)
	}

	raw, ok := os.LookupEnv(keyVar)
	if !ok || raw == "" {
		fmt.Fprintf(os.Stderr, "set %s to the 40-byte hex API private key\n", keyVar)
		os.Exit(1)
	}

	key := strings.TrimPrefix(strings.TrimPrefix(raw, "0x"), "0X")
	bytes, err := hex.DecodeString(key)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid hex private key: %v\n", err)
		os.Exit(1)
	}

	keyManager, err := signer.NewKeyManager(bytes)
	if err != nil {
		fmt.Fprintf(os.Stderr, "derive public key: %v\n", err)
		os.Exit(1)
	}

	pub := keyManager.PubKeyBytes()
	fmt.Print(hex.EncodeToString(pub[:]))
}
