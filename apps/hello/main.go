package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

// version is stamped with the git SHA at build time (see Dockerfile) so a
// running container can prove exactly which image it came from.
var version = "dev"

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	hostname, _ := os.Hostname()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello from networking-fun version=%s host=%s\n", version, hostname)
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	log.Printf("hello listening on :%s (version=%s)", port, version)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
