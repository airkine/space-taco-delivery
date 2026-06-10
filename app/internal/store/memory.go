package store

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/your-org/space-taco-delivery/internal/model"
)

// MemoryStore is an in-memory implementation (perfect for local dev).
type MemoryStore struct {
	mu     sync.RWMutex
	orders map[string]*model.Order
	seq    int
}

// NewMemoryStore creates a new in-memory store with some seed data.
func NewMemoryStore() *MemoryStore {
	ms := &MemoryStore{
		orders: make(map[string]*model.Order),
	}
	ms.seed()
	return ms
}

func (s *MemoryStore) seed() {
	eta := time.Now().Add(45 * time.Minute)
	seedOrders := []model.CreateOrderRequest{
		{
			CustomerID:       "CAPT-KIRK-001",
			Planet:           "Vulcan",
			GalacticQuadrant: "Alpha",
			Items: []model.TacoItem{
				{Filling: model.FillingNebulaBeef, Quantity: 3, ExtraHot: false},
				{Filling: model.FillingMoonMushroomVeg, Quantity: 1, ExtraHot: false},
			},
		},
		{
			CustomerID:       "DARTH-V-666",
			Planet:           "Coruscant",
			GalacticQuadrant: "Outer Rim",
			Items: []model.TacoItem{
				{Filling: model.FillingBlackHoleBBQ, Quantity: 6, ExtraHot: true},
			},
		},
	}

	for _, req := range seedOrders {
		s.mu.Lock()
		s.seq++
		id := fmt.Sprintf("TACO-%06d", s.seq)
		now := time.Now()
		order := model.NewOrder(req, id, now)
		order.EstimatedETA = &eta
		s.orders[id] = order.Clone()
		s.mu.Unlock()
	}
}

func (s *MemoryStore) CreateOrder(ctx context.Context, req model.CreateOrderRequest) (*model.Order, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := req.Validate(); err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.seq++
	id := fmt.Sprintf("TACO-%06d", s.seq)
	now := time.Now()
	order := model.NewOrder(req, id, now)
	s.orders[id] = order.Clone()
	return order.Clone(), nil
}

func (s *MemoryStore) GetOrder(ctx context.Context, id string) (*model.Order, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	o, ok := s.orders[id]
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrOrderNotFound, id)
	}
	return o.Clone(), nil
}

func (s *MemoryStore) ListOrders(ctx context.Context) ([]*model.Order, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	orders := make([]*model.Order, 0, len(s.orders))
	for _, o := range s.orders {
		orders = append(orders, o.Clone())
	}
	return orders, nil
}

func (s *MemoryStore) UpdateStatus(ctx context.Context, id string, status model.OrderStatus) (*model.Order, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	o, ok := s.orders[id]
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrOrderNotFound, id)
	}
	o.Status = status
	o.UpdatedAt = time.Now()
	return o.Clone(), nil
}
