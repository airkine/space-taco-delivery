package handler

import (
	_ "embed"
	"net/http"
)

//go:embed ui.html
var uiHTML []byte

func (h *Handler) ServeUI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(uiHTML)
}
