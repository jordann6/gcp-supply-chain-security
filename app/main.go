// A deliberately boring service.
//
// The application is not the point of this repo. What matters is that it is
// small enough to build in seconds and clean enough to pass a CRITICAL
// vulnerability gate, so that a blocked deployment is unambiguous evidence of
// the policy working rather than of the app being broken.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

type status struct {
	Service   string    `json:"service"`
	Revision  string    `json:"revision"`
	Attested  bool      `json:"attested"`
	StartedAt time.Time `json:"started_at"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	started := time.Now().UTC()

	// If this responds at all, Binary Authorization allowed the revision to
	// start. There is no way for the service to check its own attestation, and
	// a field claiming otherwise would be theatre.
	body := status{
		Service:   os.Getenv("K_SERVICE"),
		Revision:  os.Getenv("K_REVISION"),
		Attested:  true,
		StartedAt: started,
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(body); err != nil {
			log.Printf("encode: %v", err)
		}
	})

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("listening on :%s", port)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server: %v", err)
	}
}
