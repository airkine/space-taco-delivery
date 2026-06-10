package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/your-org/space-taco-delivery/internal/model"
	"github.com/your-org/space-taco-delivery/internal/service"
	"github.com/your-org/space-taco-delivery/internal/store"
)

// Handler holds dependencies for HTTP handlers.
type Handler struct {
	service *service.OrderService
	log     *slog.Logger
}

// New creates a new Handler.
func New(svc *service.OrderService, log *slog.Logger) *Handler {
	return &Handler{service: svc, log: log}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func (h *Handler) writeNotFound(w http.ResponseWriter) {
	writeError(w, http.StatusNotFound, "resource not found")
}

// Healthz is a liveness probe endpoint.
func (h *Handler) Healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"message": "🌮 Taco engines nominal",
	})
}

// Readyz is a readiness probe endpoint.
func (h *Handler) Readyz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ready",
		"message": "🚀 Ready to accept taco orders",
	})
}

// GetMenu returns the galactic taco menu.
func (h *Handler) GetMenu(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"menu":    model.GalacticMenu,
		"message": "Welcome to Space Taco Delivery — Est. Stardate 2350",
	})
}

// ServeOrders routes requests for the orders collection.
func (h *Handler) ServeOrders(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.ListOrders(w, r)
	case http.MethodPost:
		h.CreateOrder(w, r)
	default:
		w.Header().Set("Allow", "GET,POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// ServeOrderResource routes requests for a single order resource.
func (h *Handler) ServeOrderResource(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/orders/")
	path = strings.TrimSuffix(path, "/")
	if path == "" {
		h.writeNotFound(w)
		return
	}

	if strings.HasSuffix(path, "/status") {
		if r.Method != http.MethodPatch {
			w.Header().Set("Allow", "PATCH")
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}

		id := strings.TrimSuffix(path, "/status")
		if id == "" {
			writeError(w, http.StatusBadRequest, "invalid order identifier")
			return
		}

		h.UpdateOrderStatus(w, r, id)
		return
	}

	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	h.GetOrder(w, r, path)
}

// ListOrders returns orders with optional pagination and filters.
func (h *Handler) ListOrders(w http.ResponseWriter, r *http.Request) {
	opts, err := h.parseListOptions(r.URL.Query())
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	orders, err := h.service.ListOrders(r.Context(), opts)
	if err != nil {
		h.log.Error("list orders failed", "error", err)
		writeError(w, http.StatusInternalServerError, "warp drive malfunction")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"orders": orders,
		"total":  len(orders),
	})
}

func (h *Handler) parseListOptions(values url.Values) (service.ListOptions, error) {
	var opts service.ListOptions

	if limit := strings.TrimSpace(values.Get("limit")); limit != "" {
		parsed, err := strconv.Atoi(limit)
		if err != nil || parsed < 0 {
			return opts, errors.New("invalid limit")
		}
		opts.Limit = parsed
	}

	if offset := strings.TrimSpace(values.Get("offset")); offset != "" {
		parsed, err := strconv.Atoi(offset)
		if err != nil || parsed < 0 {
			return opts, errors.New("invalid offset")
		}
		opts.Offset = parsed
	}

	opts.CustomerID = strings.TrimSpace(values.Get("customer_id"))
	opts.Planet = strings.TrimSpace(values.Get("planet"))

	if status := strings.TrimSpace(values.Get("status")); status != "" {
		opts.Status = model.OrderStatus(status)
		if !opts.Status.IsValid() {
			return opts, errors.New("invalid status filter")
		}
	}

	return opts, nil
}

// CreateOrder creates a new taco order.
func (h *Handler) CreateOrder(w http.ResponseWriter, r *http.Request) {
	var req model.CreateOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid order transmission")
		return
	}

	order, err := h.service.CreateOrder(r.Context(), req)
	if err != nil {
		if errors.Is(err, model.ErrInvalidOrderRequest) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		h.log.Error("create order failed", "error", err)
		writeError(w, http.StatusInternalServerError, "order black-holed, try again")
		return
	}

	writeJSON(w, http.StatusCreated, order)
}

// GetOrder returns a single order by ID.
func (h *Handler) GetOrder(w http.ResponseWriter, r *http.Request, id string) {
	order, err := h.service.GetOrder(r.Context(), id)
	if err != nil {
		if errors.Is(err, store.ErrOrderNotFound) {
			writeError(w, http.StatusNotFound, err.Error())
			return
		}

		h.log.Error("get order failed", "error", err)
		writeError(w, http.StatusInternalServerError, "order retrieval malfunction")
		return
	}

	writeJSON(w, http.StatusOK, order)
}

// UpdateOrderStatus updates the status of an order.
func (h *Handler) UpdateOrderStatus(w http.ResponseWriter, r *http.Request, id string) {
	var req model.UpdateStatusRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid status signal")
		return
	}

	order, err := h.service.UpdateOrderStatus(r.Context(), id, req.Status)
	if err != nil {
		if errors.Is(err, model.ErrInvalidStatusRequest) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if errors.Is(err, store.ErrOrderNotFound) {
			writeError(w, http.StatusNotFound, err.Error())
			return
		}

		h.log.Error("update order status failed", "error", err)
		writeError(w, http.StatusInternalServerError, "status update malfunction")
		return
	}

	writeJSON(w, http.StatusOK, order)
}
