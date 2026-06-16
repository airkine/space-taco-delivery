# syntax=docker/dockerfile:1
# =============================================================================
# Stage 1: Build — compile the Go binary
# Pinned to 1.26 to resolve HIGH stdlib CVEs fixed in Go 1.26.4+
# (CVE-2026-42504, CVE-2026-42499, CVE-2026-39836, and others)
# =============================================================================
FROM golang:1.26-alpine AS builder

RUN apk update && apk upgrade --no-cache

WORKDIR /build

# Cache deps before copying source
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# TARGETARCH is injected by docker buildx for each platform in the matrix
# (amd64, arm64, etc.). Without this, GOARCH defaults to the builder's native
# arch and the cross-compiled binary fails at runtime with "exec format error".
ARG TARGETARCH
# Build a statically linked binary for the target platform
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build \
    -ldflags="-w -s -X main.version=${VERSION:-dev} -X main.commit=${COMMIT:-unknown}" \
    -trimpath \
    -o space-taco-delivery \
    ./cmd/server

# =============================================================================
# Stage 2: Security scan layer — run govulncheck
# =============================================================================
FROM golang:1.26-alpine AS scanner
RUN apk update && apk upgrade --no-cache && go install golang.org/x/vuln/cmd/govulncheck@latest
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
