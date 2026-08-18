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
	lighterChainID    = uint32(304)
	vectorExpiredAt   = int64(1800000000)
	vectorAccount     = int64(1)
	vectorAPIKeyIndex = uint8(0)
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
	apiKeyIndex := vectorAPIKeyIndex
	accountIndex := vectorAccount
	nonce := int64(7)

	tx, err := types.ConstructCreateOrderTx(signer, lighterChainID, &types.CreateOrderTxReq{
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
		ExpiredAt:        vectorExpiredAt,
		Nonce:            &nonce,
	})
	if err != nil {
		t.Fatal(err)
	}

	assertHex(t, "order signature", tx.Sig, "e0a05f331d066a48e1ad5a6fbbb1a14994460474f3c0fdcf2dcb40f6db19ef718df9e1115f8ca31e8ec991d573d321d00d00c616935f57f90a46aecbbea69a426fc293ae4dab259c8fc017adfa61c55c")
}

// The five transaction vectors below were captured by running the pinned official
// github.com/elliottech/lighter-go@v0.0.0-20260608173247-c26ac340ce5d directly with
// fixedSigner and Bourse's pre-bump dependency graph from commit f72dd288bdfee611cdfa7acca634323ccadef231
// (go-ethereum v1.15.6 and gnark-crypto v0.14.0). The assertions do not generate their goldens.
// Re-running the same vectors against the later bump (go-ethereum v1.17.0,
// gnark-crypto v0.18.1) produced identical signature and tx_info bytes — the bump
// is signature-neutral for cancel_order, cancel_all_orders, modify_order,
// update_leverage, and update_margin.

func TestCancelOrderVector(t *testing.T) {
	nonce := int64(3)
	tx, err := types.ConstructL2CancelOrderTx(
		newFixedSigner(t),
		lighterChainID,
		&types.CancelOrderTxReq{MarketIndex: 1, Index: 2},
		vectorTransactOpts(nonce, nil),
	)
	if err != nil {
		t.Fatal(err)
	}

	assertTransactionVector(
		t,
		tx,
		tx.Sig,
		"e28ec6f5f16f62e41b05f730898d9304259952a2bad9b66b673ec1428aa68583efbe59a2b15a0f677ab606e17250fa1aff29d3e31650aae9e13600fe4cfc309a9c0aeabf15a5bb41dea2aadd0662f024",
		`{"AccountIndex":1,"ApiKeyIndex":0,"MarketIndex":1,"Index":2,"ExpiredAt":1800000000,"Nonce":3,"Sig":"4o7G9fFvYuQbBfcwiY2TBCWZUqK62bZrZz7BQoqmhYPvvlmisVoPZ3q2BuFyUPoa/ynT4xZQqunhNgD+TPwwmpwK6r8VpbtB3qKq3QZi8CQ=","L2TxAttributes":null}`,
	)
}

func TestCancelAllOrdersVector(t *testing.T) {
	nonce := int64(4)
	marketIndex := int16(1)
	attributes := &types.L2TxAttributes{CancelAllMarketIndex: &marketIndex}
	tx, err := types.ConstructL2CancelAllOrdersTx(
		newFixedSigner(t),
		lighterChainID,
		&types.CancelAllOrdersTxReq{TimeInForce: 0, Time: 0},
		vectorTransactOpts(nonce, attributes),
	)
	if err != nil {
		t.Fatal(err)
	}

	assertTransactionVector(
		t,
		tx,
		tx.Sig,
		"bf2695a1e6fcbef0e128f8310fa35833d5a8285387bd787ed13873f8e0e1763ab7be9c4058c1db428ee614b1ba8ce2be394e0d4fc624d1d87636fe87334c3419746816b9ada88b0672034c3c6eade400",
		`{"AccountIndex":1,"ApiKeyIndex":0,"TimeInForce":0,"Time":0,"ExpiredAt":1800000000,"Nonce":4,"Sig":"vyaVoeb8vvDhKPgxD6NYM9WoKFOHvXh+0Thz+ODhdjq3vpxAWMHbQo7mFLG6jOK+OU4NT8Yk0dh2Nv6HM0w0GXRoFrmtqIsGcgNMPG6t5AA=","L2TxAttributes":{"5":1}}`,
	)
}

func TestModifyOrderVector(t *testing.T) {
	nonce := int64(8)
	integratorAccount := int64(5)
	takerFee := uint32(6)
	makerFee := uint32(7)
	attributes := &types.L2TxAttributes{
		IntegratorAccountIndex: &integratorAccount,
		IntegratorTakerFee:     &takerFee,
		IntegratorMakerFee:     &makerFee,
	}
	tx, err := types.ConstructL2ModifyOrderTx(
		newFixedSigner(t),
		lighterChainID,
		&types.ModifyOrderTxReq{MarketIndex: 1, Index: 2, BaseAmount: 3, Price: 4, TriggerPrice: 0},
		vectorTransactOpts(nonce, attributes),
	)
	if err != nil {
		t.Fatal(err)
	}

	assertTransactionVector(
		t,
		tx,
		tx.Sig,
		"435651223136685e56386aae83d825f2a23a50f07966d7bdadc4e94790a90ce892aff6669d4fb63f583730eb8a89453c38d505c7cdef28638f25688f2c36aad8455048722fd906e3003a68f6fd128b57",
		`{"AccountIndex":1,"ApiKeyIndex":0,"MarketIndex":1,"Index":2,"BaseAmount":3,"Price":4,"TriggerPrice":0,"ExpiredAt":1800000000,"Nonce":8,"Sig":"Q1ZRIjE2aF5WOGqug9gl8qI6UPB5Zte9rcTpR5CpDOiSr/ZmnU+2P1g3MOuKiUU8ONUFx83vKGOPJWiPLDaq2EVQSHIv2QbjADpo9v0Si1c=","L2TxAttributes":{"1":5,"2":6,"3":7}}`,
	)
}

func TestUpdateLeverageVector(t *testing.T) {
	nonce := int64(9)
	tx, err := types.ConstructUpdateLeverageTx(
		newFixedSigner(t),
		lighterChainID,
		&types.UpdateLeverageTxReq{MarketIndex: 1, InitialMarginFraction: 100, MarginMode: 0},
		vectorTransactOpts(nonce, nil),
	)
	if err != nil {
		t.Fatal(err)
	}

	assertTransactionVector(
		t,
		tx,
		tx.Sig,
		"8e59ebaf9667607617b86aaf949a10d21e22a5718c08fc42074f8d99faaea5282d6a92c9d1114b0ba7627fdbb196404b595b87b6302a38c848ac6fdcd5ecb17fc7f82df08672e28bb5fa1c167c44bd22",
		`{"AccountIndex":1,"ApiKeyIndex":0,"MarketIndex":1,"InitialMarginFraction":100,"MarginMode":0,"ExpiredAt":1800000000,"Nonce":9,"Sig":"jlnrr5ZnYHYXuGqvlJoQ0h4ipXGMCPxCB0+NmfqupSgtapLJ0RFLC6dif9uxlkBLWVuHtjAqOMhIrG/c1eyxf8f4LfCGcuKLtfocFnxEvSI=","L2TxAttributes":null}`,
	)
}

func TestUpdateMarginNegativeAmountVector(t *testing.T) {
	nonce := int64(10)
	tx, err := types.ConstructUpdateMarginTx(
		newFixedSigner(t),
		lighterChainID,
		&types.UpdateMarginTxReq{MarketIndex: 1, USDCAmount: -10, Direction: 1},
		vectorTransactOpts(nonce, nil),
	)
	if err != nil {
		t.Fatal(err)
	}

	assertTransactionVector(
		t,
		tx,
		tx.Sig,
		"323fdad0b3a2eeae15a2ffca5b89e0ff622254d1d91035cd36a9c6883f652156aa54bbbbc6c0de21e16da2a57518c5910881af9029947f4c455984a6bd3779abd51a7a6dccb700daa090c9fd69a3d86a",
		`{"AccountIndex":1,"ApiKeyIndex":0,"MarketIndex":1,"USDCAmount":-10,"Direction":1,"ExpiredAt":1800000000,"Nonce":10,"Sig":"Mj/a0LOi7q4Vov/KW4ng/2IiVNHZEDXNNqnGiD9lIVaqVLu7xsDeIeFtoqV1GMWRCIGvkCmUf0xFWYSmvTd5q9Uaem3MtwDaoJDJ/Wmj2Go=","L2TxAttributes":null}`,
	)
}

func vectorTransactOpts(nonce int64, attributes *types.L2TxAttributes) *types.TransactOpts {
	apiKeyIndex := vectorAPIKeyIndex
	accountIndex := vectorAccount
	return &types.TransactOpts{
		ApiKeyIndex:      &apiKeyIndex,
		FromAccountIndex: &accountIndex,
		ExpiredAt:        vectorExpiredAt,
		Nonce:            &nonce,
		TxAttributes:     attributes,
	}
}

func assertTransactionVector(t *testing.T, tx txtypes.TxInfo, signature []byte, expectedSignature, expectedTxInfo string) {
	t.Helper()
	assertHex(t, "transaction signature", signature, expectedSignature)
	actualTxInfo, err := tx.GetTxInfo()
	if err != nil {
		t.Fatal(err)
	}
	if actualTxInfo != expectedTxInfo {
		t.Fatalf("transaction info mismatch\nwant: %s\n got: %s", expectedTxInfo, actualTxInfo)
	}
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
