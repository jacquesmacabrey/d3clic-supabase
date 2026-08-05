# Back-office production

`index.html` est la source versionnée de l’interface de production à installer
sur Infomaniak dans `/rag-production/index.html`.

Cette variante pointe vers le projet Supabase `d3clic-chat`
(`ittlvqwgdsgzbgnjyexj`) et utilise une clé publique distincte du staging.
La page staging reste inchangée.

Après publication, ajouter l’URL suivante aux URL de redirection autorisées
dans Supabase Auth si elle n’est pas déjà présente :

`https://d3clic-suite.ch/rag-production/index.html`
