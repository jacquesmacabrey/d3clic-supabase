param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRef,

  [switch]$Execute
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

if (-not $Execute) {
  throw "Mode préparation uniquement. Relance avec -Execute après l'audit de Claude."
}

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
  throw "Supabase CLI n'est pas disponible."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw "Node.js n'est pas disponible pour les tests locaux."
}

Write-Host "1/6 - Tests TypeScript locaux"
node --test tests/rag/*.test.ts
if ($LASTEXITCODE -ne 0) {
  throw "Les tests TypeScript ont échoué."
}

Write-Host "2/6 - Vérification du lien Supabase"
supabase link --project-ref $ProjectRef
if ($LASTEXITCODE -ne 0) {
  throw "La liaison au projet Supabase a échoué."
}

Write-Host "3/6 - Migration SQL additive"
supabase db push --include-all
if ($LASTEXITCODE -ne 0) {
  throw "La migration SQL a échoué. L'Edge Function n'a pas été déployée."
}

Write-Host "4/6 - Concordance des registres"
& "$PSScriptRoot/verify-rag-runtime-registry.ps1"

Write-Host "5/6 - Déploiement de rag-answer-question"
supabase functions deploy rag-answer-question `
  --project-ref $ProjectRef `
  --no-verify-jwt
if ($LASTEXITCODE -ne 0) {
  throw "Le déploiement de rag-answer-question a échoué."
}

Write-Host "6/6 - Contrôle final du registre"
& "$PSScriptRoot/verify-rag-runtime-registry.ps1"

Write-Host "RAG-10.1 déployé en staging. Procéder à la recette fonctionnelle."
