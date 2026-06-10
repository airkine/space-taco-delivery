package service

import (
	"context"
	"log/slog"
	"sort"
	"strings"

	"github.com/your-org/space-taco-delivery/internal/model"
	"github.com/your-org/space-taco-delivery/internal/store"
)

type ListOptions struct {
	Limit      int
	Offset     int
	Status     model.OrderStatus
	CustomerID string
	Planet     string
}

type OrderService struct {
	repo store.Store
	log  *slog.Logger
}

func NewOrderService(repo store.Store, log *slog.Logger) *OrderService {
	return &OrderService{repo: repo, log: log}
}

func (s *OrderService) CreateOrder(ctx context.Context, req model.CreateOrderRequest) (*model.Order, error) {
	if err := req.Validate(); err != nil {
		return nil, err
	}

	order, err := s.repo.CreateOrder(ctx, req)
	if err != nil {
		return nil, err
	}

	s.log.Info("order created", "id", order.ID, "planet", order.Planet, "tacos", order.TotalTacos)
	return order, nil
}

func (s *OrderService) GetOrder(ctx context.Context, id string) (*model.Order, error) {
	return s.repo.GetOrder(ctx, id)
}

func (s *OrderService) ListOrders(ctx context.Context, opts ListOptions) ([]*model.Order, error) {
	orders, err := s.repo.ListOrders(ctx)
	if err != nil {
		return nil, err
	}

	sort.SliceStable(orders, func(i, j int) bool {
		return orders[i].CreatedAt.Before(orders[j].CreatedAt)
	})

	filtered := make([]*model.Order, 0, len(orders))
	for _, order := range orders {
		if opts.Status != "" && order.Status != opts.Status {
			continue
		}
		if opts.CustomerID != "" && !strings.EqualFold(order.CustomerID, opts.CustomerID) {
			continue
		}
		if opts.Planet != "" && !strings.Contains(strings.ToLower(order.Planet), strings.ToLower(opts.Planet)) {
			continue
		}
		filtered = append(filtered, order)
	}

	if opts.Offset >= len(filtered) {
		return []*model.Order{}, nil
	}

	end := len(filtered)
	if opts.Limit > 0 && opts.Offset+opts.Limit < end {
		end = opts.Offset + opts.Limit
	}

	return filtered[opts.Offset:end], nil
}

func (s *OrderService) UpdateOrderStatus(ctx context.Context, id string, status model.OrderStatus) (*model.Order, error) {
	req := model.UpdateStatusRequest{Status: status}
	if err := req.Validate(); err != nil {
		return nil, err
	}

	order, err := s.repo.UpdateStatus(ctx, id, status)
	if err != nil {
		return nil, err
	}

	s.log.Info("order status updated", "id", order.ID, "status", order.Status)
	return order, nil
}
