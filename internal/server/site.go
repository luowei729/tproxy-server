package server

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type staticEntry struct {
	body        []byte
	contentType string
	modTime     time.Time
	etag        string
}

type staticSite struct {
	entries  map[string]*staticEntry
	index    *staticEntry
	notFound *staticEntry
}

func loadStaticSite(root string) (*staticSite, error) {
	site := &staticSite{entries: make(map[string]*staticEntry)}
	err := filepath.WalkDir(root, func(full string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !entry.Type().IsRegular() {
			return nil
		}
		relative, err := filepath.Rel(root, full)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if relative == "." || strings.HasPrefix(relative, "../") {
			return nil
		}
		data, err := os.ReadFile(full)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		site.entries["/"+relative] = &staticEntry{
			body:        data,
			contentType: contentTypeFor(relative),
			modTime:     info.ModTime(),
			etag:        fmt.Sprintf(`"%x"`, sha256.Sum256(data)),
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	site.index = site.entries["/index.html"]
	if site.index == nil {
		return nil, os.ErrNotExist
	}
	site.notFound = site.entries["/404.html"]
	if site.notFound == nil {
		site.notFound = site.index
	}
	return site, nil
}

func (s *staticSite) resolve(requestPath string, legacyRoutes bool) *staticEntry {
	if requestPath == "" || requestPath[0] != '/' {
		return nil
	}
	if path.Clean(requestPath) != requestPath || strings.Contains(requestPath, "\\") {
		return nil
	}
	if entry := s.entries[requestPath]; entry != nil {
		return entry
	}
	if !legacyRoutes {
		return nil
	}
	if requestPath == "/favicon.ico" {
		return s.entries["/favicon.svg"]
	}
	if filepath.Ext(requestPath) == "" {
		if entry := s.entries[requestPath+".html"]; entry != nil {
			return entry
		}
	}
	return nil
}

// builtinContentTypes covers the handful of web file types that Go's mime
// package does not know without a system /etc/mime.types. A slim container
// image has no such file, and serving robots.txt as octet-stream is a small but
// visible difference from any ordinary static server.
var builtinContentTypes = map[string]string{
	".txt":   "text/plain; charset=utf-8",
	".text":  "text/plain; charset=utf-8",
	".map":   "application/json",
	".webm":  "video/webm",
	".woff2": "font/woff2",
	".woff":  "font/woff",
}

func contentTypeFor(relative string) string {
	extension := strings.ToLower(filepath.Ext(relative))
	if value := mime.TypeByExtension(extension); value != "" {
		return value
	}
	if value := builtinContentTypes[extension]; value != "" {
		return value
	}
	return "application/octet-stream"
}

func (s *Server) serveEntry(
	w http.ResponseWriter,
	r *http.Request,
	entry *staticEntry,
	status int) {
	w.Header().Set("Content-Type", entry.contentType)
	if status == http.StatusOK {
		w.Header().Set("ETag", entry.etag)
		http.ServeContent(w, r, "", entry.modTime, bytes.NewReader(entry.body))
		return
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(entry.body)))
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		_, _ = w.Write(entry.body)
	}
}
