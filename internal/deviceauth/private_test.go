package deviceauth

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/0cv/herdr-mobile-relay/internal/transport"
)

func TestExplicitBootstrapNeverRefreshesOrArmsAtStartup(t *testing.T) {
	now := time.Now().UTC()
	dir := t.TempDir()
	options := []Option{WithClock(func() time.Time { return now }), WithExplicitBootstrapInvitation()}
	store, err := Open(dir, options...)
	if err != nil {
		t.Fatal(err)
	}
	key := bytes.Repeat([]byte{7}, 32)
	if err := store.EnsureBootstrapInvitation(key, "private", "en"); err != nil {
		t.Fatal(err)
	}
	if store.state.Invitation != nil {
		t.Fatal("startup armed a private invitation")
	}
	if err := store.ArmBootstrapInvitation(key, "private", "en"); err != nil {
		t.Fatal(err)
	}
	selector := transport.E2EEAuthSelector{Kind: transport.E2EEAuthInvitation, ID: "bootstrap", Version: 1}
	if _, err := store.ResolveE2EESecret(context.Background(), selector); err != nil {
		t.Fatal(err)
	}
	now = now.Add(11 * time.Minute)
	store, err = Open(dir, options...)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.EnsureBootstrapInvitation(key, "private", "en"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ResolveE2EESecret(context.Background(), selector); !errors.Is(err, ErrInvitationExpired) {
		t.Fatalf("unpaired private invitation refreshed after expiry/restart: %v", err)
	}
	if err := store.EnsureBootstrapInvitation(key, "private", "en"); err != nil {
		t.Fatal(err)
	}
	if store.state.Invitation != nil {
		t.Fatal("startup rearmed consumed/expired invitation")
	}
	if err := store.ArmBootstrapInvitation(key, "private", "en"); err != nil {
		t.Fatal(err)
	}
	first, err := store.CompleteE2EEAuth(context.Background(), selector, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteE2EEAuth(context.Background(), transport.E2EEAuthSelector{Kind: transport.E2EEAuthCredential, ID: first.Identity.CredentialID, Version: first.Identity.CredentialVersion}, true); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ResolveE2EESecret(context.Background(), selector); err == nil {
		t.Fatal("consumed invitation reused")
	}
	if len(store.ListCredentials("")) != 1 {
		t.Fatal("enrolled credential missing")
	}
}
