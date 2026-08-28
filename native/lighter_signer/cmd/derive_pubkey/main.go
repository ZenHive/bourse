package main

import (
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	"github.com/elliottech/lighter-go/signer"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: derive_pubkey <40-byte-hex-api-private-key>")
		os.Exit(1)
	}

	key := strings.TrimPrefix(strings.TrimPrefix(os.Args[1], "0x"), "0X")
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
