$ErrorActionPreference = "Stop"

Write-Host "Le rollback destructif de RAG-10.7 est volontairement interdit après la première décision métier."
Write-Host "Désactive l'interface, puis révoque temporairement les wrappers rag_rule_* si nécessaire."
Write-Host "Le journal d'audit, les révisions et les décisions ne doivent jamais être supprimés automatiquement."
exit 2
