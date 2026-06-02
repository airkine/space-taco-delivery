package store

import (
	"fmt"
	"sync"
	"time"

	"github.com/your-org/space-taco-delivery/internal/model"
)

// Store defines the order storage interface
type Store interface {
	CreateOrder(req model.CreateOrderRequest) (*model.Order, error)
	GetOrder(id string) (*model.Order, error)
	ListOrders() ([]*model.Order, error)
	UpdateStatus(id string, status model.OrderStatus) (*model.Order, error)
}

// MemoryStore is an in-memory implementation (perfect for local dev)
type MemoryStore struct {
	mu     sync.RWMutex
	orders map[string]*model.Order
	seq    int
}

// NewMemoryStore creates a new in-memory store with some seed data
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
		o, _ := s.CreateOrder(req)
		o.EstimatedETA = &eta
		_ = o
	}
}

func (s *MemoryStore) CreateOrder(req model.CreateOrderRequest) (*model.Order, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.seq++
	id := fmt.Sprintf("TACO-%06d", s.seq)

	total := 0
	for _, item := range req.Items {
		total += item.Quantity
	}

	now := time.Now()
	eta := now.Add(30 * time.Minute)
	order := &model.Order{
		ID:               id,
		CustomerID:       req.CustomerID,
		Planet:           req.Planet,
		GalacticQuadrant: req.GalacticQuadrant,
		Items:            req.Items,
		Status:           model.StatusReceived,
		TotalTacos:       total,
		CreatedAt:        now,
		UpdatedAt:        now,
		EstimatedETA:     &eta,
	}

	s.orders[id] = order
	return order, nil
}

func (s *MemoryStore) GetOrder(id string) (*model.Order, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	o, ok := s.orders[id]
	if !ok {
		return nil, fmt.Errorf("order %q not found in the galaxy", id)
	}
	return o, nil
}

func (s *MemoryStore) ListOrders() ([]*model.Order, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	orders := make([]*model.Order, 0, len(s.orders))
	for _, o := range s.orders {
		orders = append(orders, o)
	}
	return orders, nil
}

func (s *MemoryStore) UpdateStatus(id string, status model.OrderStatus) (*model.Order, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	o, ok := s.orders[id]
	if !ok {
		return nil, fmt.Errorf("order %q not found in the galaxy", id)
	}
	o.Status = status
	o.UpdatedAt = time.Now()
	return o, nil
}
