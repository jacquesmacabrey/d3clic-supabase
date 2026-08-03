$ErrorActionPreference = "Stop"

$manifestPath = Join-Path $PSScriptRoot `
  "../supabase/functions/_shared/rag/rule-runtime-registry.json"
$migrationPath = Join-Path $PSScriptRoot `
  "../supabase/migrations/20260730150000_rag_rule_templates_foundation.sql"
$expected = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
$migration = Get-Content -Raw -Path $migrationPath
$insert = [regex]::Match(
  $migration,
  "(?s)insert\s+into\s+internal\.rag_rule_runtime_registry\s*\(.*?\)\s*values(?<values>.*?);"
)
if (-not $insert.Success) {
  throw "Le registre SQL n'a pas été trouvé dans la migration."
}
$sqlMatches = [regex]::Matches(
  $insert.Groups["values"].Value,
  "'(?<type>intent_detector|fact_extractor|renderer|aggregation_strategy)'\s*,\s*'(?<key>[a-z][a-z0-9_]{2,99})'"
)

$expectedKeys = @(
  $expected |
    ForEach-Object { "$($_.keyType):$($_.runtimeKey)" } |
    Sort-Object
)
$actualKeys = @(
  $sqlMatches |
    ForEach-Object {
      "$($_.Groups['type'].Value):$($_.Groups['key'].Value)"
    } |
    Sort-Object
)

$difference = Compare-Object `
  -ReferenceObject $expectedKeys `
  -DifferenceObject $actualKeys

if ($null -ne $difference) {
  $summary = ($difference | Out-String).Trim()
  throw "Registre SQL/TypeScript différent. Déploiement bloqué.`n$summary"
}

Write-Host "Registre migration/TypeScript conforme ($($expectedKeys.Count) clés)."
