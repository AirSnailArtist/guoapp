package core

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNativeStreamDoesNotTreatSignedMP4AsPlaylist(t *testing.T) {
	body := bytes.Repeat([]byte{0, 0, 0, 24, 'f', 't', 'y', 'p'}, (5<<20)/8)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.Write(body)
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer engine.downloads.close()
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	for _, suffix := range []string{"/hls-cache/video.mp4?token=hls", "/video.mp4?signature=m3u8"} {
		address, token := stream.nativeOpen(providerMedia{URL: upstream.URL + suffix})
		if !strings.HasSuffix(address, ".mp4") {
			t.Fatalf("MP4 marked as playlist: %s", address)
		}
		response, err := http.Get(address)
		if err != nil {
			t.Fatal(err)
		}
		actual, err := io.ReadAll(response.Body)
		response.Body.Close()
		stream.nativeRelease(token)
		if err != nil || response.StatusCode != 200 || !bytes.Equal(actual, body) {
			t.Fatalf("MP4 truncated or rejected: status=%d size=%d err=%v", response.StatusCode, len(actual), err)
		}
	}
}

func TestNativeEncryptedHLSSegmentIsNotAPlaylist(t *testing.T) {
	body := bytes.Repeat([]byte{0x47, 0, 0, 0}, (5<<20)/4)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp2t")
		w.Write(body)
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer engine.downloads.close()
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	address, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/index.m3u8", HLSKey: []byte("0123456789abcdef"), Playlist: "#EXTM3U\n#EXTINF:3,\nsegment.ts\n#EXT-X-ENDLIST\n"})
	defer stream.nativeRelease(token)
	response, err := http.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	playlist, _ := io.ReadAll(response.Body)
	response.Body.Close()
	for _, line := range strings.Split(string(playlist), "\n") {
		if !strings.HasPrefix(line, "http:") {
			continue
		}
		response, err = http.Get(line)
		if err != nil {
			t.Fatal(err)
		}
		actual, readErr := io.ReadAll(response.Body)
		response.Body.Close()
		if readErr != nil || response.StatusCode != 200 || !bytes.Equal(actual, body) {
			t.Fatalf("encrypted segment rejected: status=%d size=%d err=%v", response.StatusCode, len(actual), readErr)
		}
		return
	}
	t.Fatal("rewritten segment missing")
}
