package server

import (
	"strings"
	"testing"
)

// Go's mime package has no built-in entry for several ordinary web file types
// and falls back to the system /etc/mime.types, which a slim container image
// does not have. A static site must still answer with the usual media type.
func TestContentTypeForWebFiles(t *testing.T) {
	for _, test := range []struct {
		name string
		want string
	}{
		{"robots.txt", "text/plain; charset=utf-8"},
		{"sitemap.TXT", "text/plain; charset=utf-8"},
		{"app.js.map", "application/json"},
		{"font.woff2", "font/woff2"},
		{"clip.webm", "video/webm"},
	} {
		if got := contentTypeFor(test.name); got != test.want {
			t.Fatalf("content type for %q was %q, want %q", test.name, got, test.want)
		}
	}
	if got := contentTypeFor("index.html"); !strings.HasPrefix(got, "text/html") {
		t.Fatalf("content type for index.html was %q", got)
	}
	if got := contentTypeFor("blob.bin"); got != "application/octet-stream" {
		t.Fatalf("unknown extension got %q", got)
	}
}
