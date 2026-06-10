package store

import (
	"context"
	"errors"

	"github.com/your-org/space-taco-delivery/internal/model"
)

var ErrOrderNotFound = errors.New("order not found")

// Store defines the order storage interface.
type Store interface {
	CreateOrder(ctx context.Context, req model.CreateOrderRequest) (*model.Order, error)
	GetOrder(ctx context.Context, id string) (*model.Order, error)
	ListOrders(ctx context.Context) ([]*model.Order, error)
	UpdateStatus(ctx context.Context, id string, status model.OrderStatus) (*model.Order, error)
}
