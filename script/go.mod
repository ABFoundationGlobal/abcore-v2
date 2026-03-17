// This go.mod exists solely to mark script/ as a separate Go module.
// It prevents Go's ./... pattern (used by go test, golangci-lint, etc.) from
// descending into script/release/data/, which is a docker-mounted volume
// owned by a container user and not readable by the host build user.
// There is no Go code in this directory.
module github.com/ethereum/go-ethereum/script

go 1.24
