package handlers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/inferops/chat/sse"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
)

var tracer = otel.Tracer("inferops-chat")

// Handler holds dependencies for HTTP handlers
type Handler struct {
	ragServiceURL string
	hub           *sse.Hub
	templates     *template.Template
	httpClient    *http.Client
}

// ChatRequest is the incoming user message
type ChatRequest struct {
	Message  string `json:"message"`
	ClientID string `json:"client_id"`
}

// ChatResponse is sent back to the client
type ChatResponse struct {
	Status    string `json:"status"`
	MessageID string `json:"message_id,omitempty"`
	Error     string `json:"error,omitempty"`
}

// RAGRequest is sent to the Python RAG service
type RAGRequest struct {
	Query    string `json:"query"`
	ClientID string `json:"client_id"`
}

// RAGStreamChunk is a chunk from the RAG service SSE stream
type RAGStreamChunk struct {
	Type    string `json:"type"`    // "token", "source", "done", "error"
	Content string `json:"content"` // token text or source info
}

// New creates a new Handler
func New(ragServiceURL string, hub *sse.Hub) *Handler {
	tmpl := template.Must(template.ParseGlob("templates/*.html"))
	return &Handler{
		ragServiceURL: ragServiceURL,
		hub:           hub,
		templates:     tmpl,
		httpClient: &http.Client{
			Timeout: 120 * time.Second, // Long timeout for LLM generation
		},
	}
}

// HealthCheck returns service health
func (h *Handler) HealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "healthy",
		"service": "inferops-chat",
	})
}

// Index serves the chat UI
func (h *Handler) Index(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	h.templates.ExecuteTemplate(w, "index.html", nil)
}

// Stream handles SSE connections from the browser
func (h *Handler) Stream(w http.ResponseWriter, r *http.Request) {
	clientID := r.URL.Query().Get("client_id")
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}
	h.hub.ServeSSE(w, r, clientID)
}

// Chat handles incoming chat messages
func (h *Handler) Chat(w http.ResponseWriter, r *http.Request) {
	_, span := tracer.Start(r.Context(), "chat.handle_message")
	defer span.End()

	var req ChatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Message == "" || req.ClientID == "" {
		http.Error(w, "message and client_id required", http.StatusBadRequest)
		return
	}

	span.SetAttributes(
		attribute.String("chat.client_id", req.ClientID),
		attribute.Int("chat.message_length", len(req.Message)),
	)

	log.Printf("Chat request from %s: %s", req.ClientID, req.Message)

	// Forward to RAG service and stream response back via SSE
	// Use background context since this outlives the HTTP request
	go h.forwardToRAG(context.Background(), req)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(ChatResponse{
		Status: "processing",
	})
}

// forwardToRAG sends the query to Python RAG service and streams response via SSE
func (h *Handler) forwardToRAG(ctx context.Context, req ChatRequest) {
	_, span := tracer.Start(ctx, "chat.forward_to_rag")
	defer span.End()

	ragReq := RAGRequest{
		Query:    req.Message,
		ClientID: req.ClientID,
	}

	body, _ := json.Marshal(ragReq)
	httpReq, err := http.NewRequestWithContext(ctx, "POST",
		h.ragServiceURL+"/api/query", bytes.NewReader(body))
	if err != nil {
		h.hub.SendToClient(req.ClientID, "error",
			fmt.Sprintf(`{"content":"Failed to create request: %s"}`, err))
		return
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")

	resp, err := h.httpClient.Do(httpReq)
	if err != nil {
		h.hub.SendToClient(req.ClientID, "error",
			fmt.Sprintf(`{"content":"RAG service unavailable: %s"}`, err))
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		h.hub.SendToClient(req.ClientID, "error",
			fmt.Sprintf(`{"content":"RAG service error: %s"}`, string(bodyBytes)))
		return
	}

	// Stream SSE from RAG service to the browser client
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if len(line) > 6 && line[:6] == "data: " {
			data := line[6:]
			var chunk RAGStreamChunk
			if err := json.Unmarshal([]byte(data), &chunk); err != nil {
				continue
			}

			switch chunk.Type {
			case "token":
				h.hub.SendToClient(req.ClientID, "token", data)
			case "source":
				h.hub.SendToClient(req.ClientID, "source", data)
			case "done":
				h.hub.SendToClient(req.ClientID, "done", data)
				span.SetAttributes(attribute.String("chat.status", "completed"))
				return
			case "error":
				h.hub.SendToClient(req.ClientID, "error", data)
				span.SetAttributes(attribute.String("chat.status", "error"))
				return
			}
		}
	}
}
