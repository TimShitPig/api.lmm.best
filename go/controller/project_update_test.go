package controller

import (
	"strings"
	"testing"
)

func TestNormalizeProjectCommit(t *testing.T) {
	var commit githubProjectCommit
	commit.SHA = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
	commit.Commit.Message = "Concise title\n\nDetailed commit message."
	commit.Commit.Author.Date = "2026-07-31T08:30:00Z"

	release, err := normalizeProjectCommit(commit)
	if err != nil {
		t.Fatalf("normalizeProjectCommit() error = %v", err)
	}
	if release.TagName != "abcdef0" {
		t.Fatalf("tag_name = %q, want %q", release.TagName, "abcdef0")
	}
	if release.Name != "Concise title" {
		t.Fatalf("name = %q, want %q", release.Name, "Concise title")
	}
	if release.Body != commit.Commit.Message {
		t.Fatalf("body = %q, want full commit message", release.Body)
	}
	expectedURL := projectCommitURLBase + strings.ToLower(commit.SHA)
	if release.HTMLURL != expectedURL {
		t.Fatalf("html_url = %q, want %q", release.HTMLURL, expectedURL)
	}
	if release.PublishedAt != commit.Commit.Author.Date {
		t.Fatalf("published_at = %q, want %q", release.PublishedAt, commit.Commit.Author.Date)
	}
}

func TestNormalizeProjectCommitUsesCommitterDate(t *testing.T) {
	var commit githubProjectCommit
	commit.SHA = "0123456789abcdef0123456789abcdef01234567"
	commit.Commit.Message = "Committer date fallback"
	commit.Commit.Committer.Date = "2026-07-31T09:00:00Z"

	release, err := normalizeProjectCommit(commit)
	if err != nil {
		t.Fatalf("normalizeProjectCommit() error = %v", err)
	}
	if release.PublishedAt != commit.Commit.Committer.Date {
		t.Fatalf("published_at = %q, want committer date", release.PublishedAt)
	}
}

func TestNormalizeProjectCommitRejectsMalformedPayload(t *testing.T) {
	tests := []struct {
		name    string
		sha     string
		message string
		date    string
	}{
		{name: "short sha", sha: "abc123", message: "message", date: "2026-07-31T09:00:00Z"},
		{name: "non-hex sha", sha: "zzzzzzz", message: "message", date: "2026-07-31T09:00:00Z"},
		{name: "missing message", sha: "abcdef0", date: "2026-07-31T09:00:00Z"},
		{name: "invalid date", sha: "abcdef0", message: "message", date: "not-a-date"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var commit githubProjectCommit
			commit.SHA = test.sha
			commit.Commit.Message = test.message
			commit.Commit.Author.Date = test.date

			if _, err := normalizeProjectCommit(commit); err == nil {
				t.Fatal("normalizeProjectCommit() error = nil, want malformed payload error")
			}
		})
	}
}
