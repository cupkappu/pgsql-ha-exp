path "tde/data/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "tde/metadata" {
  capabilities = ["read", "list"]
}

path "tde/metadata/*" {
  capabilities = ["read", "list", "delete"]
}
