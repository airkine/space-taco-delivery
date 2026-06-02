package handler

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/your-org/space-taco-delivery/internal/model"
	"github.com/your-org/space-taco-delivery/internal/store"
)

// Handler holds dependencies for HTTP handlers
type Handler struct {
	store store.Store
	log   *slog.Logger
}

// New creates a new Handler
func New(s store.Store, log *slog.Logger) *Handler {
	return &Handler{store: s, log: log}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// Healthz is a liveness probe endpoint
func (h *Handler) Healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"message": "🌮 Taco engines nominal",
	})
}

// Readyz is a readiness probe endpoint
func (h *Handler) Readyz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ready",
		"message": "🚀 Ready to accept taco orders",
	})
}

// GetMenu returns the galactic taco menu
func (h *Handler) GetMenu(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"menu":    model.GalacticMenu,
		"message": "Welcome to Space Taco Delivery — Est. Stardate 2350",
	})
}

// ListOrders returns all orders
func (h *Handler) ListOrders(w http.ResponseWriter, r *http.Request) {
	orders, err := h.store.ListOrders()
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

// CreateOrder creates a new taco order
func (h *Handler) CreateOrder(w http.ResponseWriter, r *http.Request) {
	var req model.CreateOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid order transmission")
		return
	}

	if req.CustomerID == "" || req.Planet == "" || len(req.Items) == 0 {
		writeError(w, http.StatusBadRequest, "missing required fields: customer_id, planet, items")
		return
	}

	order, err := h.store.CreateOrder(req)
	if err != nil {
		h.log.Error("create order failed", "error", err)
		writeError(w, http.StatusInternalServerError, "order black-holed, try again")
		return
	}

	h.log.Info("order created", "id", order.ID, "planet", order.Planet, "tacos", order.TotalTacos)
	writeJSON(w, http.StatusCreated, order)
}

// GetOrder returns a single order by ID
func (h *Handler) GetOrder(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	order, err := h.store.GetOrder(id)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, order)
}

// UpdateOrderStatus updates the status of an order
func (h *Handler) UpdateOrderStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	var req model.UpdateStatusRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid status signal")
		return
	}

	order, err := h.store.UpdateStatus(id, req.Status)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	h.log.Info("order status updated", "id", order.ID, "status", order.Status)
	writeJSON(w, http.StatusOK, order)
}
