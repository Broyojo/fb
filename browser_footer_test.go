//go:build !fbmac

package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPagesLinkHealthzAndVersion(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "code.go"), []byte("package x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "data.csv"), []byte("a,b\n1,2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "notes.md"), []byte("# hi\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	server := fileServer{fsys: os.DirFS(root), pandoc: fakePandoc(t), dir: root}

	for _, url := range []string{"/", "/code.go", "/data.csv"} {
		req := httptest.NewRequest(http.MethodGet, url, nil)
		req.Header.Set("Sec-Fetch-Dest", "document")
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("%s: status = %d, want %d", url, rec.Code, http.StatusOK)
			continue
		}
		body := rec.Body.String()
		if !strings.Contains(body, "/_fb/healthz") || !strings.Contains(body, "/_fb/version") {
			t.Errorf("%s lacks the healthz/version footer", url)
		}
	}

	// Markdown pages render without the footer.
	req := httptest.NewRequest(http.MethodGet, "/notes.md", nil)
	req.Header.Set("Sec-Fetch-Dest", "document")
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/notes.md: status = %d, want %d", rec.Code, http.StatusOK)
	}
	if body := rec.Body.String(); strings.Contains(body, "/_fb/healthz") || strings.Contains(body, "/_fb/version") {
		t.Error("/notes.md unexpectedly has the healthz/version footer")
	}
}
