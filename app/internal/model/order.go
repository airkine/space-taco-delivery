package model

import (
	"time"
)

// TacoFilling represents a taco filling option from the galactic menu
type TacoFilling string

const (
	FillingNebulaBeef      TacoFilling = "nebula_beef"
	FillingStardustShrimp  TacoFilling = "stardust_shrimp"
	FillingMoonMushroomVeg TacoFilling = "moon_mushroom_veg"
	FillingBlackHoleBBQ    TacoFilling = "black_hole_bbq"
	FillingCometChorizo    TacoFilling = "comet_chorizo"
)

// OrderStatus tracks the intergalactic delivery pipeline
type OrderStatus string

const (
	StatusReceived  OrderStatus = "received"  // Order beamed in
	StatusPreparing OrderStatus = "preparing" // Kitchen crew assembling
	StatusLaunched  OrderStatus = "launched"  // Delivery pod launched
	StatusInOrbit   OrderStatus = "in_orbit"  // Approaching destination
	StatusDelivered OrderStatus = "delivered" // Nom nom nom
	StatusAborted   OrderStatus = "aborted"   // Asteroid interference
)

// TacoItem is a single taco in the order
type TacoItem struct {
	Filling  TacoFilling `json:"filling"`
	Quantity int         `json:"quantity"`
	ExtraHot bool        `json:"extra_hot"` // Solar-flare salsa
}

// Order represents a taco delivery order
type Order struct {
	ID               string      `json:"id"`
	CustomerID       string      `json:"customer_id"`
	Planet           string      `json:"planet"` // Delivery destination
	GalacticQuadrant string      `json:"galactic_quadrant"`
	Items            []TacoItem  `json:"items"`
	Status           OrderStatus `json:"status"`
	TotalTacos       int         `json:"total_tacos"`
	CreatedAt        time.Time   `json:"created_at"`
	UpdatedAt        time.Time   `json:"updated_at"`
	EstimatedETA     *time.Time  `json:"estimated_eta,omitempty"`
}

// MenuItem represents an item on the galactic menu
type MenuItem struct {
	Filling     TacoFilling `json:"filling"`
	Name        string      `json:"name"`
	Description string      `json:"description"`
	SpiceLevel  int         `json:"spice_level"` // 1-5 suns
	Available   bool        `json:"available"`
}

// CreateOrderRequest is the inbound order payload
type CreateOrderRequest struct {
	CustomerID       string     `json:"customer_id"`
	Planet           string     `json:"planet"`
	GalacticQuadrant string     `json:"galactic_quadrant"`
	Items            []TacoItem `json:"items"`
}

// UpdateStatusRequest updates an order's status
type UpdateStatusRequest struct {
	Status OrderStatus `json:"status"`
}

// GalacticMenu is the full menu
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
