module github.com/your-org/space-taco-delivery

// Kept at 1.24 so golangci-lint (currently built with Go 1.24) can analyze this module.
// The Docker build uses golang:1.26-alpine for CVE fixes — that is a runtime/stdlib concern
// and is independent of the minimum language version declared here.
go 1.24

require (
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/redis/go-redis/v9 v9.20.0 // indirect
	go.uber.org/atomic v1.11.0 // indirect
)
