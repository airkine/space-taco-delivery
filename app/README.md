# Space Taco Delivery — App

A minimal Go HTTP microservice for managing intergalactic taco orders. Built with the standard library only (`net/http`, `log/slog`) — no external frameworks.

## How it works

### Project layout

```text
app/
├── cmd/server/main.go          # Entry point — wires up server, routes, graceful shutdown
├── internal/
│   ├── handler/handler.go      # HTTP handlers
│   ├── handler/ui.go           # Embeds and serves the browser UI
│   ├── handler/ui.html         # Single-page UI (space theme, vanilla JS)
│   ├── model/order.go          # Domain types: Order, TacoItem, MenuItem, request/response structs
│   └── store/memory.go         # In-memory store (thread-safe, seeded with sample orders)
├── Dockerfile                  # Multi-stage build → distroless final image
└── go.mod
```

### UI — "Launch Your Order" form

The order form fields use pre-populated dropdowns instead of free-text inputs so users pick from a curated list of space-themed options:

| Field | Options |
| ------- | --------- |
| **Commander ID** | 10 funny space aliases (e.g. `DARTH-TACO-LORD`, `ADMIRAL-NACHO`, `SPACE-COWBOY-007`) |
| **Destination Planet** | 10 planets with humorous subtitles (e.g. `Vulcan (Logically Delicious)`, `Uranus (We All Giggled)`) |
| **Galactic Quadrant** | 8 quadrant labels (e.g. `Nacho Nebula (Dense & Cheesy)`, `Burrito Belt (High Traffic Zone)`) |

Commander ID and Destination Planet are required; Galactic Quadrant is optional. All dropdowns default to an empty placeholder — if the user doesn't pick, the existing validation toast fires.

---

### API routes

| Method | Path | Description |
| -------- | ------ | ------------- |
| `GET` | `/` | Browser UI (menu, order form, order tracker) |
| `GET` | `/healthz` | Liveness probe |
| `GET` | `/readyz` | Readiness probe |
| `GET` | `/api/v1/menu` | List available taco fillings |
| `GET` | `/api/v1/orders` | List all orders |
| `POST` | `/api/v1/orders` | Create a new order |
| `GET` | `/api/v1/orders/{id}` | Get a single order by ID |
| `PATCH` | `/api/v1/orders/{id}/status` | Update order status |

### Order lifecycle

Orders move through these statuses: `received` → `preparing` → `launched` → `in_orbit` → `delivered`. Orders can be set to `aborted` at any point. Status transitions are manual via the `PATCH` endpoint — there's no background worker.

### Data store

`MemoryStore` is an in-memory, mutex-protected map. It seeds two orders on startup so the API returns data immediately. Data does not persist across restarts — this is intentional for local dev and testing.

---

## Docker Compose

The fastest way to build and run the app locally is from the **repo root**:

```bash
docker compose up --build
```

This builds the image and starts two services:

| Service       | Port   | Notes                                   |
| ------------- | ------ | --------------------------------------- |
| `space-taco`  | `8080` | Go app, built from `app/Dockerfile`     |
| `redis`       | `6379` | Redis 7; app connects via `REDIS_URL`   |

The app waits for Redis to pass its healthcheck before starting. To run without Redis (MemoryStore only), omit the `REDIS_URL` environment variable or set it to empty.

```bash
docker compose down   # stop and remove containers
```

---

## Building the Docker image locally

The Dockerfile is a three-stage build:

1. **builder** — compiles a statically linked binary with `CGO_ENABLED=0`
2. **scanner** — runs `govulncheck` (non-blocking; informational only)
3. **final** — copies the binary into `gcr.io/distroless/static-debian12:nonroot`

Build from the **repo root**:

```bash
docker build \
  --target final \
  -t space-taco-delivery:local \
  -f app/Dockerfile \
  app/
```

Run it:

```bash
docker run --rm -p 8080:8080 space-taco-delivery:local
```

Verify:

```bash
curl http://localhost:8080/healthz
curl http://localhost:8080/api/v1/menu | jq .
```

### Optional build args

Pass `VERSION` and `COMMIT` to embed them in the binary:

```bash
docker build \
  --target final \
  --build-arg VERSION=0.1.0 \
  --build-arg COMMIT=$(git rev-parse --short HEAD) \
  -t space-taco-delivery:local \
  -f app/Dockerfile \
  app/
```

---

## Running locally without Docker

Requires Go 1.22+.

```bash
cd app
go run ./cmd/server
```

The server listens on `:8080` by default. Override with the `PORT` env var:

```bash
PORT=9090 go run ./cmd/server
```

### Sample requests

```bash
# Place an order
curl -X POST http://localhost:8080/api/v1/orders \
  -H 'Content-Type: application/json' \
  -d '{
    "customer_id": "EARTHLING-001",
    "planet": "Earth",
    "galactic_quadrant": "Milky Way",
    "items": [
      {"filling": "black_hole_bbq", "quantity": 2, "extra_hot": true}
    ]
  }'

# Update status
curl -X PATCH http://localhost:8080/api/v1/orders/TACO-000001/status \
  -H 'Content-Type: application/json' \
  -d '{"status": "preparing"}'
```

### Available fillings

| Key | Name |
| ----- | ------ |
| `nebula_beef` | Nebula Beef Supreme |
| `stardust_shrimp` | Stardust Shrimp Fiesta |
| `moon_mushroom_veg` | Moon Mushroom Vegan |
| `black_hole_bbq` | Black Hole BBQ Brisket |
| `comet_chorizo` | Comet Chorizo Blaze |

---

## Full local cluster

To deploy into a local kind cluster with Flux and Kyverno, use the bootstrap script from the repo root:

```bash
./deploy/kind/bootstrap-local.sh
```

See [`deploy/kind/`](../deploy/kind/) for cluster config details.
