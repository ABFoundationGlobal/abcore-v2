// bls_proof: decrypt a keystorev4 BLS keystore and emit the pubkey +
// proof-of-possession for StakeHub.createValidator().
//
// Usage:
//
//	go run script/upgrade-drill/bls_proof/main.go \
//	    -keystore <path-to-keystore-json> \
//	    -password <wallet-password> \
//	    -operator <0xAddr> \
//	    -chainid <decimal>
//
// Output (two lines):
//
//	PUBKEY=<96-hex-char BLS public key>
//	PROOF=0x<192-hex-char proof-of-possession>
package main

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/big"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	bls "github.com/prysmaticlabs/prysm/v5/crypto/bls"
	keystorev4 "github.com/wealdtech/go-eth2-wallet-encryptor-keystorev4"
)

func main() {
	keystorePath := flag.String("keystore", "", "path to keystorev4 JSON file")
	password := flag.String("password", "", "keystore password")
	operatorHex := flag.String("operator", "", "operator address (0x...)")
	chainID := flag.Int64("chainid", 0, "chain ID")
	flag.Parse()

	if *keystorePath == "" || *password == "" || *operatorHex == "" || *chainID == 0 {
		flag.Usage()
		os.Exit(1)
	}

	// Read keystore.
	raw, err := os.ReadFile(*keystorePath)
	if err != nil {
		log.Fatalf("read keystore: %v", err)
	}
	var ks map[string]interface{}
	if err := json.Unmarshal(raw, &ks); err != nil {
		log.Fatalf("parse keystore: %v", err)
	}

	// Decrypt private key bytes using keystorev4.
	enc := keystorev4.New()
	cryptoFields, ok := ks["crypto"].(map[string]interface{})
	if !ok {
		log.Fatal("keystore missing 'crypto' field")
	}
	privKeyBytes, err := enc.Decrypt(cryptoFields, *password)
	if err != nil {
		log.Fatalf("decrypt keystore: %v", err)
	}

	// Reconstruct BLS secret key.
	secretKey, err := bls.SecretKeyFromBytes(privKeyBytes)
	if err != nil {
		log.Fatalf("bls.SecretKeyFromBytes: %v", err)
	}
	pubKey := secretKey.PublicKey()

	// Compute proof-of-possession:
	// msgHash = keccak256(operatorAddr(20) || pubKey(48) || paddedChainId(32))
	// This matches both blsAccountGenerateProof in geth and _checkVoteAddress in StakeHub.sol.
	operatorAddr := common.HexToAddress(*operatorHex)
	pubKeyBytes := pubKey.Marshal()
	chainIDBig := new(big.Int).SetInt64(*chainID)
	paddedChainID := make([]byte, 32)
	chainIDBig.FillBytes(paddedChainID)

	msgInput := append(operatorAddr.Bytes(), append(pubKeyBytes, paddedChainID...)...)
	msgHash := crypto.Keccak256(msgInput)

	sig := secretKey.Sign(msgHash)

	operatorHexLower := strings.ToLower(strings.TrimPrefix(*operatorHex, "0x"))
	_ = operatorHexLower

	fmt.Printf("PUBKEY=%s\n", hex.EncodeToString(pubKeyBytes))
	fmt.Printf("PROOF=0x%s\n", hex.EncodeToString(sig.Marshal()))
}
