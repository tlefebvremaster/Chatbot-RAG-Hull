# Chatbot RAG — *Options, Futures and Other Derivatives* (John Hull)

Projet M2 : un chatbot **RAG** (Retrieval-Augmented Generation) qui répond en langage naturel à des questions sur le livre de John Hull, **en citant la page source**, sans inventer.

Construit avec **n8n** (orchestration), **Supabase / Postgres + pgvector** (base vectorielle), **Google Gemini** (embeddings), **Cohere** (reranking) et **Anthropic Claude** (génération). Objectif : **0 € de coût additionnel**.

## Les deux workflows

| Fichier | Rôle | Quand |
|---|---|---|
| [`rag-indexation.json`](rag-indexation.json) | **Indexation** : upload du PDF → découpage (par page puis en chunks) → embeddings Gemini → insertion dans la table `documents` via PGVector | Une seule fois |
| [`rag-chatbot-explicite.json`](rag-chatbot-explicite.json) | **Réponse** : pipeline explicite nœud par nœud (embedding → recherche hybride → rerank → prompt augmenté → Claude → mémoire) | À chaque question |

> Le workflow de réponse est **volontairement explicite** (sans les « sous-nœuds » de l'AI Agent) : chaque étape est un nœud visible et modifiable, pour un contrôle total et la possibilité d'ajouter des étapes (augmentation, rerank, garde-fous…).

## Architecture (phase de réponse)

```
Chat (question + mémoire de session)
   │
   ▼
Reformulation de la question ..... Claude → requête de recherche autonome en ANGLAIS
   (résout les questions de suivi via l'historique ; FR→EN pour matcher le livre)
   │
   ▼
Embedding de la requête .......... HTTP → Google Gemini (gemini-embedding-001, 3072 dim)
   │
   ▼
Recherche HYBRIDE sur Postgres
   ├─ vectorielle (opérateur <=> cosinus) ...... top 20
   └─ mots-clés (to_tsvector / plainto_tsquery) . top 8
   │
   ▼
Fusion + dédoublonnage des passages
   │
   ▼
Rerank ......................... HTTP → Cohere (rerank-v3.5) → 5 meilleurs
   │
   ▼
Construction du PROMPT AUGMENTÉ (extraits + pages + historique)
   │
   ▼
Génération ..................... Anthropic Claude (claude-sonnet-5)
   │
   ▼
Réponse (+ sauvegarde de l'échange dans chat_turns)
```

## Paramètres clés

| Paramètre | Valeur | Pourquoi |
|---|---|---|
| Reformulation de requête | Claude → requête EN autonome | FR→EN pour matcher le livre anglais + résout les questions de suivi |
| Taille de chunk | 1000 caractères | ~1 paragraphe : assez de contexte, assez précis |
| Chevauchement (overlap) | 200 (20 %) | évite de couper une idée à la frontière |
| Découpage | récursif + par page | coupe aux frontières naturelles + garde le n° de page |
| Embeddings | Gemini `gemini-embedding-001` (3072 dim) | qualité, multilingue, gratuit |
| Passages récupérés | 20 (vectoriel) + 8 (mots-clés) | large filet pour ne rien rater |
| Passages gardés après rerank | 5 | précision : seuls les meilleurs vont au LLM |
| LLM de génération | Claude `claude-sonnet-5` | synthèse + gratuit (crédits n8n) |

## Installation

1. **Base de données** : exécuter [`schema.sql`](schema.sql) dans l'éditeur SQL de Supabase (crée l'extension `vector`, la table `documents` + son index full-text, et la table mémoire `chat_turns`).
2. **n8n** : importer les deux fichiers `.json`.
3. **Credentials à reconnecter dans n8n** (non inclus dans les exports, voir ci-dessous) :
   - Postgres (Session pooler Supabase)
   - Google Gemini (PaLM) API — pour les embeddings
   - Cohere API — pour le rerank
   - Anthropic — via les crédits Gateway de n8n cloud
4. **Indexer** : lancer `rag-indexation.json`, uploader le PDF du livre (une seule fois).
5. **Discuter** : ouvrir le chat de `rag-chatbot-explicite.json`.

## Sécurité

Les exports de workflows **ne contiennent aucune clé API** — seulement la liste des types de credentials à reconnecter. À l'import, il faut re-sélectionner/recréer chaque credential dans ta propre instance n8n.

## Documents du projet

- [`CAHIER-DES-CHARGES.md`](CAHIER-DES-CHARGES.md) — besoin fonctionnel
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — architecture technique
- [`FICHE-SOUTENANCE.md`](FICHE-SOUTENANCE.md) — explication simple de chaque étape + justification des paramètres (pour la soutenance)
