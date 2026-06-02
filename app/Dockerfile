# syntax=docker/dockerfile:1
# =============================================================================
# Stage 1: Build — compile the Go binary
# =============================================================================
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Cache deps before copying source
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# Build a statically linked binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.version=${VERSION:-dev} -X main.commit=${COMMIT:-unknown}" \
    -trimpath \
    -o space-taco-delivery \
    ./cmd/server

# =============================================================================
# Stage 2: Security scan layer — run govulncheck
# =============================================================================
FROM golang:1.22-alpine AS scanner
RUN go install golang.org/x/vuln/cmd/govulncheck@latest
WORKDIR /scan
COPY --from=builder /build .
RUN govulncheck ./... || true  # non-blocking in build; CI will gate separately

# =============================================================================
# Stage 3: Final — distroless nonroot image
# =============================================================================
FROM gcr.io/distroless/static-debian12:nonroot AS final

LABEL org.opencontainers.image.title="Space Taco Delivery" \
      org.opencontainers.image.description="Intergalactic taco order microservice" \
      org.opencontainers.image.vendor="your-org" \
      org.opencontainers.image.licenses="MIT"

COPY --from=builder /build/space-taco-delivery /usr/local/bin/space-taco-delivery

EXPOSE 8080

USER nonroot:nonroot

ENTRYPOINT ["/usr/local/bin/space-taco-delivery"]
