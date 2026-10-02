# Architecture | Chatbot RAG — Options, Futures and Other Derivatives (Hull)

Traduction technique du [cahier des charges](CAHIER-DES-CHARGES.md). Chaque nœud cité ci-dessous a été vérifié en interrogeant directement le registre de nœuds de l'instance n8n cloud (via le MCP) — pas de supposition sur leur existence ou leurs paramètres.

## 1. Vue d'ensemble

Deux workflows séparés, qui ne se chevauchent qu'au niveau de la base Supabase partagée :

```
WORKFLOW 1 — Indexation (une seule fois, manuel)
┌──────────────────┐     ┌──────────────────────────────────────┐
│ Formulaire n8n     │────▶│ Supabase Vector Store (mode: insert)  │
│ (upload du PDF)    │     │  ├─ embedding: Google Gemini           │
└──────────────────┘     │  └─ documentLoader: Default Data Loader│
                           │       (lit le PDF binaire, découpe     │
                           │        par page, puis par chunks)      │
                           └──────────────────┬─────────────────────┘
                                               ▼
                                     Table Supabase "documents"
                                     (contenu + embedding + page)

WORKFLOW 2 — Question / Réponse (à chaque appel)
┌──────────┐     ┌────────────────────────────────────────────┐     ┌──────────────┐
│ Webhook   │────▶│ AI Agent                                    │────▶│ Réponse webhook│
│ (POST)    │     │  ├─ model: Anthropic Chat Model (Claude)     │     │ (JSON direct)  │
└──────────┘     │  └─ tools: Supabase Vector Store              │     └──────────────┘
                   │        (mode: retrieve-as-tool, top 4)        │
                   │        └─ embedding: Google Gemini            │
                   └────────────────────────────────────────────┘
```

## 2. Traçabilité exigence → choix technique

| Exigence (cahier des charges) | Choix technique | Pourquoi |
|---|---|---|
| Déclenché via webhook/API, pas d'interface dédiée | Nœud **Webhook** (POST) en entrée du workflow 2, `responseMode: lastNode` | Renvoie directement la sortie de l'AI Agent comme réponse HTTP — aucun nœud de réponse supplémentaire nécessaire |
| Indexation une seule fois, ce livre uniquement | Workflow 1 séparé, déclenché par un **formulaire n8n** avec un champ fichier, pas de planification | Le Manual Trigger ne peut pas recevoir de fichier ; le formulaire est le seul moyen simple de faire parvenir le PDF à n8n cloud (qui n'a pas accès à ton disque local) |
| Réponse = texte libre + citation chapitre/page | Consigne système explicite sur l'AI Agent + découpage du PDF **par page** (`splitPages: true`) dans le Data Loader | Chaque passage retrouvé porte son numéro de page en métadonnée, que l'agent peut citer |
| Base vectorielle = Supabase | Nœud natif **Supabase Vector Store** (`@n8n/n8n-nodes-langchain.vectorStoreSupabase`), confirmé disponible, modes insert + retrieve-as-tool | Choix déjà fait dans le cahier des charges, confirmé supporté nativement |
| LLM = Anthropic Claude | **Anthropic Chat Model** (`lmChatAnthropic`), modèle `claude-sonnet-5` | Choix déjà fait ; branché comme "cerveau" de l'AI Agent |
| Budget 0€, clé Anthropic "à récupérer" | **Crédits Gateway** de l'instance n8n cloud, qui couvrent `anthropicApi` ET `googlePalmApi` (Gemini, pour les embeddings) | Découverte en vérifiant le MCP n8n : l'instance propose des identifiants managés gratuits pour ces deux fournisseurs — pas besoin de créer ta propre clé Anthropic pour ce volume ponctuel |
| Quota gratuit Supabase à respecter | Un seul livre, indexé une fois → volume de vecteurs borné et prévisible | Pas de mécanisme de ré-indexation qui ferait grossir la base indéfiniment |
| Usage ponctuel démo/soutenance | Architecture simple, sans file d'attente ni limitation de débit | Le volume ne justifie pas de complexité supplémentaire |
| Gestion d'erreur non prioritaire | Comportement par défaut de n8n conservé, aucun retry/alerting ajouté | Conforme à la décision explicite du cahier des charges |

## 3. Logique détaillée

### Workflow 1 — Indexation
1. Le formulaire n8n (champ type "file", PDF uniquement) reçoit le livre.
2. Le nœud Supabase Vector Store en mode `insert` reçoit ce fichier.
3. Son sous-nœud **Default Data Loader** est configuré en `dataType: binary`, `loader: pdfLoader`, `options.splitPages: true` — il extrait le texte du PDF et crée un document par page, avec le numéro de page en métadonnée.
4. Chaque page est ensuite re-découpée en chunks plus petits via un sous-nœud **Recursive Character Text Splitter** (`chunkSize` ~1000, `chunkOverlap` ~200) — nécessaire car une page de manuel académique est souvent trop longue pour un seul chunk d'embedding efficace.
5. Son sous-nœud **embedding** (Google Gemini, modèle `models/gemini-embedding-001`) vectorise chaque chunk.
6. Le résultat est inséré dans la table Supabase configurée (voir §4, prérequis).

### Workflow 2 — Question/Réponse
1. Le Webhook reçoit un POST avec la question (ex. `{"question": "..."}`) — à adapter au nom de champ exact une fois branché.
2. L'**AI Agent** reçoit cette question (`promptType: define`, texte = expression pointant vers le corps de la requête).
3. Son `systemMessage` lui donne deux consignes fermes : répondre en langage naturel ET toujours citer la page/le chapitre d'origine du passage utilisé.
4. L'agent dispose d'un seul outil : le **Supabase Vector Store en mode `retrieve-as-tool`**, avec une description claire ("recherche des passages du livre Hull sur les produits dérivés") et `topK: 4` (les 4 passages les plus pertinents).
5. L'agent décide d'appeler cet outil, reçoit les passages + leurs métadonnées (page), compose la réponse.
6. Le Webhook renvoie directement `{{ $json.output }}` au client appelant (`responseMode: lastNode`).

## 4. Modèle de données

### Table Supabase (prérequis à créer avant le premier import)
Le nœud Supabase Vector Store ne crée pas la table tout seul — il faut exécuter au préalable, dans l'éditeur SQL Supabase, le script standard d'intégration pgvector (extension `vector`, table avec colonnes `id`, `content`, `metadata` (jsonb), `embedding` (vector), et la fonction `match_documents`). C'est la procédure officielle documentée par Supabase pour l'intégration LangChain — à exécuter une fois, avant d'activer le Workflow 1.

### Métadonnées par chunk
`pageNumber` (numéro de page dans le PDF source, ajouté automatiquement par le Data Loader avec `splitPages: true`) — c'est ce champ que l'agent doit citer dans ses réponses.

## 5. Risques & limites

| Risque | Impact | À vérifier/faire |
|---|---|---|
| Taille du PDF (36,3 Mo) envoyée via un formulaire web | Risque de dépassement d'une limite de taille de payload sur n8n cloud | Tester l'upload réel avant de compter dessus pour la soutenance ; si ça bloque, scinder le PDF en plusieurs parties ou l'héberger ailleurs et le récupérer par URL |
| Crédits Gateway (Anthropic + Gemini) à quota limité, montant exact inconnu | Pourrait s'épuiser avant/pendant la soutenance si testé en boucle | Vérifier le solde réel dans l'interface n8n cloud avant la démo ; avoir en secours ta propre clé Anthropic si besoin |
| Citation de page dépend du bon comportement du PDF Loader sur un PDF académique complexe (notes de bas de page, formules, mise en page 2 colonnes) | Les numéros de page ou le découpage pourraient être imprécis sur certaines sections | À vérifier concrètement après la première indexation, sur quelques questions tests |
| Table/fonction Supabase non créées | Le Workflow 1 échoue dès la première insertion | Exécuter le script SQL pgvector de Supabase avant d'activer le workflow |
| Qualité des réponses non testée sur du contenu technique (formules financières, notations mathématiques) | Les chunks de texte brut peuvent mal capturer des formules/tableaux | À évaluer après un premier test réel avec des questions types d'examen |
