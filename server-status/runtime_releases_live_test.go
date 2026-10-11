package main

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestLiveRuntimeReleaseSources(t *testing.T) {
	if os.Getenv("SERA_LIVE_RELEASE_TEST") != "1" {
		t.Skip("set SERA_LIVE_RELEASE_TEST=1 to check publisher APIs")
	}
	for _, id := range []string{"python", "go", "node", "php", "openjdk", "dotnet", "ruby", "bun", "deno"} {
		t.Run(id, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			items, err := runtimeReleases(ctx, id)
			if err != nil {
				t.Fatal(err)
			}
			if len(items) == 0 {
				t.Fatal("no releases")
			}
			t.Logf("%d releases, newest %s", len(items), items[0].Version)
		})
	}
}
