package lighter_signer_test

import (
	"encoding/hex"
	"hash"
	"testing"
	"time"

	"github.com/elliottech/lighter-go/types"
	"github.com/elliottech/lighter-go/types/txtypes"
	curve "github.com/elliottech/poseidon_crypto/curve/ecgfp5"
	gFp5 "github.com/elliottech/poseidon_crypto/field/goldilocks_quintic_extension"
	schnorr "github.com/elliottech/poseidon_crypto/signature/schnorr"
)

const (
	privateKeyHex     = "07000000000000000300000000000000000000000000000000000000000000000000000000000000"
	messageHashHex    = "01000000000000000200000000000000030000000000000004000000000000000500000000000000"
	nonceHex          = "09000000000000000000000000000000050000000000000000000000000000000000000000000000"
	expectedPublicKey = "48d4615592bf39d71889f5127c7710c36912b733a1f8f32cb9446a7aec4e34461348642d459cbc77"
	expectedSignature = "a90169cde0aa539d74553bcdccd969925519370da180f17c2374f9448d857d7d3dd342894fe83770e321927a894dadef5932badf109a622dbd07be130e22e522f1c58ec27e05e9458071b476bfa1e708"
	expectedAuthToken = "1800000000:1:0:b4af0d1c8b2b48f5b5115dcdd3e9a1a51dadadf52c5bed7ef4acbc56786e118897d9dab1a356c258af1cca4bd13bdf5ed2e90b2ee0187323f0b17fadf4e136bd755fe35cbcf222d96d44575d7ab91920"
)

type fixedSigner struct {
	privateKey curve.ECgFp5Scalar
	nonce      curve.ECgFp5Scalar
}

func (signer fixedSigner) Sign(message []byte, _ hash.Hash) ([]byte, error) {
	hashedMessage, err := gFp5.FromCanonicalLittleEndianBytes(message)
	if err != nil {
		return nil, err
	}
	return schnorr.SchnorrSignHashedMessage2(hashedMessage, signer.privateKey, signer.nonce).ToBytes(), nil
}

func TestTask198PrimitiveVector(t *testing.T) {
	signer := newFixedSigner(t)
	messageHash := decodeHex(t, messageHashHex)
	hashedMessage, err := gFp5.FromCanonicalLittleEndianBytes(messageHash)
	if err != nil {
		t.Fatal(err)
	}

	publicKey := schnorr.SchnorrPkFromSk(signer.privateKey).ToLittleEndianBytes()
	signature := schnorr.SchnorrSignHashedMessage2(hashedMessage, signer.privateKey, signer.nonce).ToBytes()

	assertHex(t, "public key", publicKey, expectedPublicKey)
	assertHex(t, "signature", signature, expectedSignature)
}

func TestTask198AuthTokenVector(t *testing.T) {
	signer := newFixedSigner(t)
	apiKeyIndex := uint8(0)
	accountIndex := int64(1)

	token, err := types.ConstructAuthToken(signer, time.Unix(1800000000, 0), &types.TransactOpts{
		ApiKeyIndex:      &apiKeyIndex,
		FromAccountIndex: &accountIndex,
	})
	if err != nil {
		t.Fatal(err)
	}
	if token != expectedAuthToken {
		t.Fatalf("auth token mismatch\nwant: %s\n got: %s", expectedAuthToken, token)
	}
}

func TestCreateOrderVector(t *testing.T) {
	signer := newFixedSigner(t)
	apiKeyIndex := uint8(0)
	accountIndex := int64(1)
	nonce := int64(7)

	tx, err := types.ConstructCreateOrderTx(signer, 304, &types.CreateOrderTxReq{
		MarketIndex:      1,
		ClientOrderIndex: 123,
		BaseAmount:       1000,
		Price:            200000,
		IsAsk:            0,
		Type:             txtypes.LimitOrder,
		TimeInForce:      txtypes.ImmediateOrCancel,
		ReduceOnly:       0,
		TriggerPrice:     txtypes.NilOrderTriggerPrice,
		OrderExpiry:      txtypes.NilOrderExpiry,
	}, &types.TransactOpts{
		ApiKeyIndex:      &apiKeyIndex,
		FromAccountIndex: &accountIndex,
		ExpiredAt:        1800000000,
		Nonce:            &nonce,
	})
	if err != nil {
		t.Fatal(err)
	}

	assertHex(t, "order signature", tx.Sig, "e0a05f331d066a48e1ad5a6fbbb1a14994460474f3c0fdcf2dcb40f6db19ef718df9e1115f8ca31e8ec991d573d321d00d00c616935f57f90a46aecbbea69a426fc293ae4dab259c8fc017adfa61c55c")
}

func newFixedSigner(t *testing.T) fixedSigner {
	t.Helper()
	return fixedSigner{
		privateKey: curve.ScalarElementFromLittleEndianBytes(decodeHex(t, privateKeyHex)),
		nonce:      curve.ScalarElementFromLittleEndianBytes(decodeHex(t, nonceHex)),
	}
}

func decodeHex(t *testing.T, value string) []byte {
	t.Helper()
	decoded, err := hex.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return decoded
}

func assertHex(t *testing.T, label string, actual []byte, expected string) {
	t.Helper()
	encoded := hex.EncodeToString(actual)
	if encoded != expected {
		t.Fatalf("%s mismatch\nwant: %s\n got: %s", label, expected, encoded)
	}
}
