$ErrorActionPreference = "Stop"

$ExpectedEngineHash = "eca639155e99bff7bdf8acdc28e6cecb52f13089fae5bb00f6d25e8b4bad3bcf"
$EnginePath = Join-Path $PSScriptRoot "..\supabase\functions\_shared\rag\rule-engine.ts"
$ActualEngineHash = (Get-FileHash -Algorithm SHA256 $EnginePath).Hash.ToLowerInvariant()
if ($ActualEngineHash -ne $ExpectedEngineHash) {
  throw "rule-engine.ts a changé. Déploiement RAG-10.7 arrêté."
}

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
  throw "Supabase CLI est introuvable."
}

Push-Location (Join-Path $PSScriptRoot "..")
try {
  supabase db push
  if ($LASTEXITCODE -ne 0) { throw "La migration RAG-10.7 a échoué." }

  supabase functions deploy rag-admin-rules --no-verify-jwt
  if ($LASTEXITCODE -ne 0) { throw "Le déploiement de rag-admin-rules a échoué." }

  Write-Host "RAG-10.7 déployé en staging. Exécuter maintenant tests/sql/rag-10-7-admin-workflow.test.sql."
}
finally {
  Pop-Location
}
