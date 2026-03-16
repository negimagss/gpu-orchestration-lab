package sse

import (
	"fmt"
	"log"
	"net/http"
	"sync"
)

// Client represents a connected SSE client
type Client struct {
	ID     string
	Events chan string
	Done   chan struct{}
}

// Hub manages all SSE client connections
type Hub struct {
	clients    map[string]*Client
	register   chan *Client
	unregister chan *Client
	mu         sync.RWMutex
}

// NewHub creates a new SSE hub
func NewHub() *Hub {
	return &Hub{
		clients:    make(map[string]*Client),
		register:   make(chan *Client),
		unregister: make(chan *Client),
	}
}

// Run starts the hub event loop
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client.ID] = client
			h.mu.Unlock()
			log.Printf("SSE client connected: %s (total: %d)", client.ID, len(h.clients))

		case client := <-h.unregister:
			h.mu.Lock()
			// Only remove if this is still the active client for this ID
			// (a new connection with the same ID may have already replaced it)
			if existing, ok := h.clients[client.ID]; ok && existing == client {
				close(client.Events)
				delete(h.clients, client.ID)
			}
			h.mu.Unlock()
			log.Printf("SSE client disconnected: %s (total: %d)", client.ID, len(h.clients))
		}
	}
}

// Register adds a new client
func (h *Hub) Register(client *Client) {
	h.register <- client
}

// Unregister removes a client
func (h *Hub) Unregister(client *Client) {
	h.unregister <- client
}

// SendToClient sends an SSE event to a specific client
func (h *Hub) SendToClient(clientID string, event string, data string) {
	h.mu.RLock()
	client, ok := h.clients[clientID]
	h.mu.RUnlock()

	if !ok {
		return
	}

	msg := fmt.Sprintf("event: %s\ndata: %s\n\n", event, data)
	select {
	case client.Events <- msg:
	default:
		log.Printf("Client %s buffer full, dropping message", clientID)
	}
}

// ServeSSE handles the SSE HTTP connection for a client
func (h *Hub) ServeSSE(w http.ResponseWriter, r *http.Request, clientID string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no") // Disable nginx buffering

	client := &Client{
		ID:     clientID,
		Events: make(chan string, 64),
		Done:   make(chan struct{}),
	}

	h.Register(client)
	defer h.Unregister(client)

	// Send initial connection event
	fmt.Fprintf(w, "event: connected\ndata: {\"clientId\":\"%s\"}\n\n", clientID)
	flusher.Flush()

	for {
		select {
		case msg, ok := <-client.Events:
			if !ok {
				return
			}
			fmt.Fprint(w, msg)
			flusher.Flush()

		case <-r.Context().Done():
			return
		}
	}
}
