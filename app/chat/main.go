package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/inferops/chat/handlers"
	"github.com/inferops/chat/sse"
)

func main() {
	// Configuration from environment
	port := getEnv("PORT", "8080")
	ragServiceURL := getEnv("RAG_SERVICE_URL", "http://localhost:8000")
	otelEndpoint := getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")

	// Initialize OpenTelemetry
	shutdown, err := initTracer(otelEndpoint)
	if err != nil {
		log.Printf("WARNING: Failed to initialize tracer: %v", err)
	} else {
		defer shutdown(context.Background())
	}

	// Initialize SSE hub for managing client connections
	hub := sse.NewHub()
	go hub.Run()

	// Initialize handlers
	h := handlers.New(ragServiceURL, hub)

	// Routes
	mux := http.NewServeMux()

	// Health check
	mux.HandleFunc("GET /health", h.HealthCheck)

	// Chat API
	mux.HandleFunc("POST /api/chat", h.Chat)

	// SSE stream endpoint
	mux.HandleFunc("GET /api/stream", h.Stream)

	// Static files and templates
	mux.HandleFunc("GET /", h.Index)
	mux.Handle("GET /static/", http.StripPrefix("/static/",
		http.FileServer(http.Dir("templates/static"))))

	// Server
	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 120 * time.Second, // Long timeout for SSE
		IdleTimeout:  120 * time.Second,
	}

	// Graceful shutdown
	go func() {
		log.Printf("InferOps Chat App listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}
	log.Println("Server stopped")
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}
