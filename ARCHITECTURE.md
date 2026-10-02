# Architecture | Chatbot RAG — Options, Futures and Other Derivatives (Hull)

Traduction technique du [cahier des charges](CAHIER-DES-CHARGES.md). Chaque nœud cité ci-dessous existe réellement dans les workflows n8n livrés ([`rag-indexation.json`](rag-indexation.json) et [`rag-chatbot-explicite.json`](rag-chatbot-explicite.json)).

> **Version finale : pipeline explicite.** À la demande du jury, la phase de réponse n'utilise **aucun « sous-nœud »** (pas de nœud AI Agent « boîte noire »). Chaque étape — embedding, recherche, rerank, augmentation, génération, mémoire — est un **nœud visible et modifiable**, pour un contrôle total et la possibilité d'ajouter des étapes.

## 1. Vue d'ensemble

Deux workflows séparés, qui ne se partagent que la base Postgres (Supabase).

```
WORKFLOW 1 — Indexation (une seule fois, manuel)
┌──────────────────┐     ┌────────────────────────────────────────────┐
│ Formulaire n8n     │────▶│ Postgres PGVector (mode: insert)            │
│ (upload du PDF)    │     │  ├─ embedding : Google Gemini                │
└──────────────────┘     │  ├─ documentLoader : Chargeur PDF (par page)│
                           │  └─ textSplitter : Recursive (1000 / 200)   │
                           └────────────────────┬───────────────────────┘
                                                 ▼
                                       Table Postgres "documents"
                                       (text + embedding 3072 + metadata.loc.pageNumber)

WORKFLOW 2 — Question / Réponse (chaîne explicite, à chaque message)
┌───────────────┐   ┌──────────────────┐   ┌─────────────────────────┐
│ Chat Trigger   │──▶│ Préparer entrée    │──▶│ Historique (reformulation)│ (Postgres: agrège l'historique)
│ (public, mémo) │   │ (Set: question,    │   └───────────┬─────────────┘
└───────────────┘   │  session_id)       │               ▼
                     └──────────────────┘   ┌─────────────────────────┐
                                             │ Reformuler la question   │ Claude → requête EN autonome
                                             └───────────┬─────────────┘  (résout les questions de suivi)
                                                         ▼
                                             ┌─────────────────────────┐
                                             │ Requete de recherche     │ (Set: search_query + question d'origine)
                                             └───────────┬─────────────┘
                                                         ▼
                                             ┌──────────────────────────┐
                                             │ Embedding question (Gemini)│  HTTP → vecteur 3072
                                             └───────────┬──────────────┘
                                                         ▼
                                              ┌──────────────────┐
                                              │ Vecteur vers SQL  │ (Code)
                                              └────────┬──────────┘
                                   ┌───────────────────┴───────────────────┐
                                   ▼                                       ▼
                        ┌────────────────────┐              ┌────────────────────────┐
                        │ Recherche vectorielle│  (Postgres)  │ Recherche mots-cles     │ (Postgres)
                        │ embedding <=> vec, 20 │              │ to_tsvector/ts_query, 8 │
                        └──────────┬───────────┘              └───────────┬────────────┘
                                   └───────────────┬──────────────────────┘
                                                   ▼
                                        ┌────────────────────┐
                                        │ Fusionner resultats │ (Merge)
                                        └──────────┬──────────┘
                                                   ▼
                                        ┌────────────────────┐
                                        │ Agreger passages    │ (Code: dédoublonnage)
                                        └──────────┬──────────┘
                                                   ▼
                                        ┌────────────────────┐
                                        │ Rerank (Cohere)     │  HTTP → rerank-v3.5, top 5
                                        └──────────┬──────────┘
                                                   ▼
                                        ┌────────────────────┐
                                        │ Top passages        │ (Code: contexte + [page X])
                                        └──────────┬──────────┘
                                                   ▼
                                        ┌────────────────────┐
                                        │ Lire historique     │ (Postgres: chat_turns, 5 derniers)
                                        └──────────┬──────────┘
                                                   ▼
                                        ┌──────────────────────────┐
                                        │ Construire prompt augmente│ (Code: système + extraits + historique)
                                        └──────────┬───────────────┘
                                                   ▼
                                        ┌────────────────────┐
                                        │ Generer reponse     │  Anthropic Claude (claude-sonnet-5)
                                        └──────────┬──────────┘
                                                   ▼
                                        ┌────────────────────┐   ┌────────────────────┐
                                        │ Sauver historique   │──▶│ Reponse (sortie chat)│
                                        │ (Postgres INSERT)   │   │ (Set: output)        │
                                        └────────────────────┘   └────────────────────┘
```

## 2. Traçabilité exigence → choix technique

| Exigence (cahier des charges) | Choix technique | Pourquoi |
|---|---|---|
| Interface de chat avec mémoire | Nœud **Chat Trigger** (`public`, `responseMode: lastNode`) + table mémoire `chat_turns` lue/écrite en SQL | Permet les questions de suivi ("et pour l'option américaine ?") sans dépendre d'un sous-nœud de mémoire |
| Qualité du retrieval (livre EN, questions FR) | Étape de **reformulation de requête** (nœud Claude) : réécrit la question en une requête de recherche autonome en **anglais**, en s'appuyant sur l'historique | FR→EN améliore la recherche vectorielle ET mots-clés sur un livre anglais ; résout les questions de suivi ("et pour l'américaine ?") avant la recherche |
| Suppression des « sous-nœuds » (demande du jury) | Chaîne **explicite** : HTTP (embedding, rerank), Postgres (recherche, mémoire), Code (fusion, augmentation), nœud Anthropic | Chaque étape est visible et modifiable ; on peut insérer une étape (garde-fou, traduction…) n'importe où |
| Indexation une seule fois, ce livre uniquement | Workflow 1 séparé, déclenché par un **formulaire n8n** (champ fichier) | Le formulaire est le moyen simple d'envoyer le PDF à n8n cloud (pas d'accès au disque local) |
| Réponse = texte libre + citation chapitre/page | Prompt système explicite (nœud Code *Construire prompt augmente*) + découpage **par page** (`splitPages: true`) à l'indexation | Chaque passage retrouvé porte son `metadata.loc.pageNumber`, injecté dans le contexte sous la forme `[page X]` et cité par Claude |
| Base vectorielle = Supabase | **Postgres + pgvector** via une connexion Postgres (Session pooler Supabase) | Le cours impose une connexion Postgres ; pgvector ajoute la recherche de proximité (`<=>`) |
| Qualité de recherche | **Recherche hybride** : vectorielle (sens) + full-text (`to_tsvector`/`plainto_tsquery`, termes exacts), puis **rerank Cohere** | La vectorielle rate parfois un terme technique précis ; les mots-clés le rattrapent ; le rerank ne garde que les 5 plus pertinents |
| LLM = Anthropic Claude | Nœud **Anthropic** (`claude-sonnet-5`), `simplify: false`, `maxTokens: 1500`, système injecté en expression | Choix du cahier des charges ; branché en fin de chaîne explicite |
| Budget 0€ | **Crédits Gateway** n8n cloud (Anthropic) + clé **Gemini** gratuite (embeddings) + **Cohere** gratuit (rerank) + Supabase gratuit | Aucun coût additionnel pour un usage ponctuel de démo |
| Quota gratuit Supabase à respecter | Un seul livre, indexé une fois → volume de vecteurs borné (5020 chunks) | Pas de ré-indexation récurrente qui ferait grossir la base |

## 3. Logique détaillée

### Workflow 1 — Indexation (`rag-indexation.json`)
1. Le **formulaire n8n** (champ type `file`, PDF) reçoit le livre.
2. Le nœud **Postgres PGVector** (`mode: insert`, table `documents`) orchestre l'insertion.
3. Son sous-nœud **Chargeur PDF (par page)** (`dataType: binary`, `loader: pdfLoader`, `splitPages: true`) crée **un document par page**, avec le numéro de page en métadonnée.
4. Son sous-nœud **Decoupage en chunks** (Recursive Character Text Splitter, `chunkSize` ~1000, `chunkOverlap` 200) re-découpe chaque page.
5. Son sous-nœud **Embeddings Google Gemini** (`gemini-embedding-001`) vectorise chaque chunk (3072 dim).
6. Résultat inséré dans la table `documents`.

> **Pourquoi l'indexation garde ses sous-nœuds ?** Le Chargeur PDF intégré tamponne automatiquement et de façon fiable le `pageNumber` de chaque chunk. Le refaire en explicite (via *Extract from File*) aplatirait le PDF et ferait perdre les frontières de pages — donc les citations. L'esprit de la demande (contrôle, ajout d'étapes) concerne la phase de réponse, pas ce découpage linéaire.

### Workflow 2 — Question / Réponse (`rag-chatbot-explicite.json`)
1. **Chat RAG Hull** (Chat Trigger) reçoit le message et l'identifiant de session.
2. **Préparer entrée** (Set) extrait `question` et `session_id`.
3. **Historique (reformulation)** (Postgres) agrège les 5 derniers échanges de la session en une seule ligne `history` (toujours une ligne, même vide → la chaîne ne s'interrompt jamais).
4. **Reformuler la question** (Claude) réécrit la question en **une requête de recherche autonome en anglais**, en résolvant les références à l'historique (ex. "et pour l'américaine ?" → "American option early exercise"). *C'est l'étape de query rewriting.*
5. **Requete de recherche** (Set) expose `search_query` (la requête reformulée) tout en conservant la `question` d'origine (en français, pour la réponse finale).
6. **Embedding question (Gemini)** (HTTP POST) transforme la `search_query` en vecteur 3072 — *même modèle que l'indexation*, condition pour que les vecteurs soient comparables.
7. **Vecteur vers SQL** (Code) formate le vecteur (`[v1,v2,…]`) et nettoie les mots-clés (à partir de la `search_query`).
8. **Recherche vectorielle** (Postgres) : `ORDER BY embedding <=> vec` → 20 passages par le sens. **Recherche mots-cles** (Postgres) : `to_tsvector @@ plainto_tsquery` → 8 passages par termes exacts.
9. **Fusionner resultats** (Merge) + **Agreger passages** (Code, dédoublonnage par texte).
10. **Rerank (Cohere)** (HTTP POST, `rerank-v3.5`, `top_n: 5`) reclasse les candidats par pertinence réelle (query = `search_query`).
11. **Top passages** (Code) reconstruit les 5 meilleurs passages avec leur page → bloc de contexte `[page X] …`.
12. **Lire historique** (Postgres) récupère les 5 derniers échanges de la session (`alwaysOutputData: true`), pour le prompt final.
13. **Construire prompt augmente** (Code) assemble le message système (réponds en français, uniquement d'après les extraits, cite la page, n'invente pas) + historique + extraits + question d'origine. **C'est l'étape d'augmentation.**
14. **Generer reponse** (Anthropic, `claude-sonnet-5`) rédige la réponse sourcée.
15. **Sauver historique** (Postgres INSERT, dollar-quoting `$q$…$q$` / `$a$…$a$` pour gérer les virgules/apostrophes) + **Reponse (sortie chat)** (Set) renvoie la réponse.

> **Note :** l'historique est lu à deux endroits — tôt (étape 3) pour la reformulation, et plus tard (étape 12) pour le prompt final. Deux petites lectures SQL indépendantes, qui gardent chaque étape simple et isolée.

## 4. Modèle de données

Voir [`schema.sql`](schema.sql).

- **`documents`** : `id`, `text`, `metadata` (jsonb, contient `loc.pageNumber`), `embedding` (vector **3072**). Créée automatiquement par le nœud PGVector au premier insert (dimension déduite du modèle).
- **Index full-text** : `documents_text_fts` (GIN sur `to_tsvector('english', text)`) — alimente la recherche par mots-clés.
- **Pas d'index ANN** sur `embedding` : pgvector n'indexe pas au-delà de 2000 dimensions (ici 3072) → balayage exact, suffisant à l'échelle d'un livre.
- **`chat_turns`** : `id`, `session_id`, `question`, `answer`, `created_at` — la mémoire de conversation.

## 5. Risques & limites

| Risque | Impact | À vérifier / faire |
|---|---|---|
| Taille du PDF (~36 Mo) via le formulaire | Dépassement possible de la limite d'upload n8n cloud | Tester l'upload réel avant la démo ; sinon scinder le PDF |
| Crédits Gateway (Anthropic) + quotas Gemini/Cohere gratuits | Épuisement possible si testé en boucle | Vérifier les soldes avant la soutenance ; garder une clé de secours |
| Citation de page dépend du PDF Loader sur un PDF académique (formules, 2 colonnes) | Numéros de page ou découpage imprécis sur certaines sections | Vérifié après la 1ère indexation sur des questions tests |
| Pas d'index vectoriel (3072 dim) | Recherche plus lente si la base grossit beaucoup (plusieurs livres) | OK pour un livre ; réduire la dimension si passage à l'échelle |
| Qualité sur contenu très technique (formules, notations) | Chunks de texte brut capturant mal certaines formules | Évalué sur des questions types d'examen |
