package model

import (
	"errors"
	"fmt"
	"time"
)

var (
	ErrInvalidOrderRequest  = errors.New("invalid order request")
	ErrInvalidStatusRequest = errors.New("invalid status request")
)

// TacoFilling represents a taco filling option from the galactic menu.
type TacoFilling string

const (
	FillingNebulaBeef      TacoFilling = "nebula_beef"
	FillingStardustShrimp  TacoFilling = "stardust_shrimp"
	FillingMoonMushroomVeg TacoFilling = "moon_mushroom_veg"
	FillingBlackHoleBBQ    TacoFilling = "black_hole_bbq"
	FillingCometChorizo    TacoFilling = "comet_chorizo"
)

// OrderStatus tracks the intergalactic delivery pipeline.
type OrderStatus string

const (
	StatusReceived  OrderStatus = "received"  // Order beamed in
	StatusPreparing OrderStatus = "preparing" // Kitchen crew assembling
	StatusLaunched  OrderStatus = "launched"  // Delivery pod launched
	StatusInOrbit   OrderStatus = "in_orbit"  // Approaching destination
	StatusDelivered OrderStatus = "delivered" // Nom nom nom
	StatusAborted   OrderStatus = "aborted"   // Asteroid interference
)

// TacoItem is a single taco in the order.
type TacoItem struct {
	Filling  TacoFilling `json:"filling"`
	Quantity int         `json:"quantity"`
	ExtraHot bool        `json:"extra_hot"`
}

// Order represents a taco delivery order.
type Order struct {
	ID               string      `json:"id"`
	CustomerID       string      `json:"customer_id"`
	Planet           string      `json:"planet"`
	GalacticQuadrant string      `json:"galactic_quadrant"`
	Items            []TacoItem  `json:"items"`
	Status           OrderStatus `json:"status"`
	TotalTacos       int         `json:"total_tacos"`
	CreatedAt        time.Time   `json:"created_at"`
	UpdatedAt        time.Time   `json:"updated_at"`
	EstimatedETA     *time.Time  `json:"estimated_eta,omitempty"`
}

// MenuItem represents an item on the galactic menu.
type MenuItem struct {
	Filling     TacoFilling `json:"filling"`
	Name        string      `json:"name"`
	Description string      `json:"description"`
	SpiceLevel  int         `json:"spice_level"`
	Available   bool        `json:"available"`
}

// CreateOrderRequest is the inbound order payload.
type CreateOrderRequest struct {
	CustomerID       string     `json:"customer_id"`
	Planet           string     `json:"planet"`
	GalacticQuadrant string     `json:"galactic_quadrant"`
	Items            []TacoItem `json:"items"`
}

// UpdateStatusRequest updates an order's status.
type UpdateStatusRequest struct {
	Status OrderStatus `json:"status"`
}

func (req CreateOrderRequest) Validate() error {
	if req.CustomerID == "" {
		return fmt.Errorf("%w: customer_id is required", ErrInvalidOrderRequest)
	}
	if req.Planet == "" {
		return fmt.Errorf("%w: planet is required", ErrInvalidOrderRequest)
	}
	if len(req.Items) == 0 {
		return fmt.Errorf("%w: at least one item is required", ErrInvalidOrderRequest)
	}
	for _, item := range req.Items {
		if item.Filling == "" {
			return fmt.Errorf("%w: item filling is required", ErrInvalidOrderRequest)
		}
		if item.Quantity <= 0 {
			return fmt.Errorf("%w: item quantity must be greater than zero", ErrInvalidOrderRequest)
		}
	}
	return nil
}

func (req UpdateStatusRequest) Validate() error {
	if !req.Status.IsValid() {
		return fmt.Errorf("%w: status is invalid", ErrInvalidStatusRequest)
	}
	return nil
}

func (s OrderStatus) IsValid() bool {
	switch s {
	case StatusReceived, StatusPreparing, StatusLaunched, StatusInOrbit, StatusDelivered, StatusAborted:
		return true
	default:
		return false
	}
}

func NewOrder(req CreateOrderRequest, id string, now time.Time) *Order {
	total := 0
	for _, item := range req.Items {
		total += item.Quantity
	}

	eta := now.Add(30 * time.Minute)
	items := make([]TacoItem, len(req.Items))
	copy(items, req.Items)

	return &Order{
		ID:               id,
		CustomerID:       req.CustomerID,
		Planet:           req.Planet,
		GalacticQuadrant: req.GalacticQuadrant,
		Items:            items,
		Status:           StatusReceived,
		TotalTacos:       total,
		CreatedAt:        now,
		UpdatedAt:        now,
		EstimatedETA:     &eta,
	}
}

func (o *Order) Clone() *Order {
	if o == nil {
		return nil
	}

	items := make([]TacoItem, len(o.Items))
	copy(items, o.Items)

	clone := *o
	clone.Items = items
	if o.EstimatedETA != nil {
		eta := *o.EstimatedETA
		clone.EstimatedETA = &eta
	}

	return &clone
}

// GalacticMenu is the full menu.
var GalacticMenu = []MenuItem{
	{
		Filling:     FillingNebulaBeef,
		Name:        "Nebula Beef Supreme",
		Description: "Slow-cooked beef marinated in cosmic dust reduction",
		SpiceLevel:  3,
		Available:   true,
	},
	{
		Filling:     FillingStardustShrimp,
		Name:        "Stardust Shrimp Fiesta",
		Description: "Flash-fried shrimp with meteorite salt and zero-g guac",
		SpiceLevel:  2,
		Available:   true,
	},
	{
		Filling:     FillingMoonMushroomVeg,
		Name:        "Moon Mushroom Vegan",
		Description: "Selenite mushrooms sautéed in lunar butter (vegan friendly)",
		SpiceLevel:  1,
		Available:   true,
	},
	{
		Filling:     FillingBlackHoleBBQ,
		Name:        "Black Hole BBQ Brisket",
		Description: "So smoky it bends light — mesquite-smoked brisket",
		SpiceLevel:  4,
		Available:   true,
	},
	{
		Filling:     FillingCometChorizo,
		Name:        "Comet Chorizo Blaze",
		Description: "Spicy chorizo with trailing jalapeño comet tail",
		SpiceLevel:  5,
		Available:   true,
	},
}
