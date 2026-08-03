param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRef,

  [switch]$Execute
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$rollbackRoot = Join-Path $projectRoot "rollback-edge"

if (-not $Execute) {
  throw "Mode préparation uniquement. Relance avec -Execute pour restaurer l'Edge Function précédente."
}

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
  throw "Supabase CLI n'est pas disponible."
}
if (-not (Test-Path (Join-Path $rollbackRoot "supabase/config.toml"))) {
  throw "Le paquet de retour arrière est incomplet."
}

Push-Location $rollbackRoot
try {
  Write-Host "1/2 - Liaison du paquet de retour arrière"
  supabase link --project-ref $ProjectRef
  if ($LASTEXITCODE -ne 0) {
    throw "La liaison au projet Supabase a échoué."
  }

  Write-Host "2/2 - Restauration de rag-answer-question"
  supabase functions deploy rag-answer-question `
    --project-ref $ProjectRef `
    --no-verify-jwt
  if ($LASTEXITCODE -ne 0) {
    throw "La restauration de rag-answer-question a échoué."
  }
}
finally {
  Pop-Location
}

Write-Host "Edge Function précédente restaurée. La migration SQL additive reste en place."
