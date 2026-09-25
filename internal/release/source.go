package release

// Repository is the release authority for this fork. Go module/import paths
// retain upstream attribution; they are not update/download destinations.
const Repository = "dima-m711/herdr-mobile-relay"
const API = "https://api.github.com/repos/" + Repository
const Web = "https://github.com/" + Repository
const Assets = Web + "/releases/download"
