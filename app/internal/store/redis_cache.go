package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/your-org/space-taco-delivery/internal/model"
)

const cacheTTL = 5 * time.Minute

// RedisCache wraps any Store and caches individual order lookups in Redis.
// Cache-aside pattern: read from cache first, fall through to inner store on miss,
// write through on create/update, bypass on list.
type RedisCache struct {
	inner  Store
	client *redis.Client
}

// NewRedisCache connects to Redis at redisURL and returns a caching Store.
// Returns an error if the connection cannot be established within 3 seconds.
func NewRedisCache(inner Store, redisURL string) (*RedisCache, error) {
	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, err
	}
	client := redis.NewClient(opts)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		client.Close()
		return nil, err
	}
	return &RedisCache{inner: inner, client: client}, nil
}

// Close releases the Redis connection.
func (c *RedisCache) Close() error {
	return c.client.Close()
}

func (c *RedisCache) cacheKey(id string) string {
	return "order:" + id
}

func (c *RedisCache) cacheGet(ctx context.Context, id string) (*model.Order, bool) {
	data, err := c.client.Get(ctx, c.cacheKey(id)).Bytes()
	if err != nil {
		return nil, false
	}
	var o model.Order
	if err := json.Unmarshal(data, &o); err != nil {
		return nil, false
	}
	return &o, true
}

func (c *RedisCache) cacheSet(ctx context.Context, o *model.Order) {
	data, err := json.Marshal(o)
	if err != nil {
		return
	}
	c.client.Set(ctx, c.cacheKey(o.ID), data, cacheTTL)
}

func (c *RedisCache) CreateOrder(req model.CreateOrderRequest) (*model.Order, error) {
	o, err := c.inner.CreateOrder(req)
	if err != nil {
		return nil, err
	}
	c.cacheSet(context.Background(), o)
	return o, nil
}

// GetOrder returns from cache if present; falls through to inner store on a miss
// and populates the cache for subsequent reads.
func (c *RedisCache) GetOrder(id string) (*model.Order, error) {
	ctx := context.Background()
	if o, ok := c.cacheGet(ctx, id); ok {
		return o, nil
	}
	o, err := c.inner.GetOrder(id)
	if err != nil {
		return nil, err
	}
	c.cacheSet(ctx, o)
	return o, nil
}

// ListOrders always reads from the inner store — listing is not cached.
func (c *RedisCache) ListOrders() ([]*model.Order, error) {
	return c.inner.ListOrders()
}

func (c *RedisCache) UpdateStatus(id string, status model.OrderStatus) (*model.Order, error) {
	o, err := c.inner.UpdateStatus(id, status)
	if err != nil {
		return nil, err
	}
	c.cacheSet(context.Background(), o)
	return o, nil
}
