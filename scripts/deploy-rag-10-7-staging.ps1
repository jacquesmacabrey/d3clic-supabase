param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ProjectRef,

  [switch]$Execute
)

$ErrorActionPreference = "Stop"

$ExpectedProjectRef = "lhrctmwxdgscfisrnqko"
$ExpectedProjectName = "d3clic-staging-auth"

if (-not $Execute) {
  throw "Mode préparation uniquement. Relance avec -Execute après la revue."
}

if ($ProjectRef -ne $ExpectedProjectRef) {
  throw "Projet refusé : '$ProjectRef'. RAG-10.7 doit cibler uniquement le staging '$ExpectedProjectName' ($ExpectedProjectRef)."
}

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
  Write-Host "Projet cible vérifié : $ExpectedProjectName ($ExpectedProjectRef)."

  supabase link --project-ref $ExpectedProjectRef
  if ($LASTEXITCODE -ne 0) { throw "La liaison au staging Supabase a échoué." }

  $LinkedProjectRefPath = Join-Path (Get-Location) "supabase\.temp\project-ref"
  if (-not (Test-Path $LinkedProjectRefPath)) {
    throw "Impossible de vérifier le projet Supabase lié."
  }

  $LinkedProjectRef = (Get-Content -Raw $LinkedProjectRefPath).Trim()
  if ($LinkedProjectRef -ne $ExpectedProjectRef) {
    throw "Projet Supabase lié inattendu : '$LinkedProjectRef'. Déploiement arrêté."
  }

  supabase db push --include-all
  if ($LASTEXITCODE -ne 0) { throw "La migration RAG-10.7 a échoué." }

  supabase functions deploy rag-admin-rules `
    --project-ref $ExpectedProjectRef `
    --no-verify-jwt
  if ($LASTEXITCODE -ne 0) { throw "Le déploiement de rag-admin-rules a échoué." }

  Write-Host "RAG-10.7 déployé en staging. Exécuter maintenant tests/sql/rag-10-7-admin-workflow.test.sql."
}
finally {
  Pop-Location
}
