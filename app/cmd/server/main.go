package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/your-org/space-taco-delivery/internal/handler"
	"github.com/your-org/space-taco-delivery/internal/service"
	"github.com/your-org/space-taco-delivery/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	memStore := store.NewMemoryStore()

	var st store.Store = memStore
	if redisURL := os.Getenv("REDIS_URL"); redisURL != "" {
		cache, err := store.NewRedisCache(memStore, redisURL, log)
		if err != nil {
			log.Warn("redis cache unavailable, falling back to memory store", "error", err)
		} else {
			log.Info("redis cache enabled", "url", redisURL)
			defer cache.Close()
			st = cache
		}
	}

	svc := service.NewOrderService(st, log)
	h := handler.New(svc, log)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" || r.Method != http.MethodGet {
			http.NotFound(w, r)
			return
		}
		h.ServeUI(w, r)
	})
	mux.HandleFunc("/healthz", h.Healthz)
	mux.HandleFunc("/readyz", h.Readyz)
	mux.HandleFunc("/api/v1/menu", h.GetMenu)
	mux.HandleFunc("/api/v1/orders", h.ServeOrders)
	mux.HandleFunc("/api/v1/orders/", h.ServeOrderResource)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		log.Info("🚀 Space Taco Delivery is launching", "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Info("🛸 Initiating graceful shutdown...")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Error("shutdown error", "error", err)
	}
	log.Info("🌮 All tacos delivered. Goodbye.")
}
