# Fiche de soutenance — Chatbot RAG sur le livre de Hull

Explication simple de chaque étape + justification des paramètres.

---

## Vue d'ensemble en une phrase

On a transformé un livre de 869 pages en une base consultable "par le sens", pour qu'un assistant (Claude) puisse répondre à des questions **en s'appuyant uniquement sur le livre** et en **citant la page** — sans inventer.

Le projet a **deux temps** :
1. **L'indexation** (une fois) : préparer le livre → chunking + embedding + stockage.
2. **La réponse** (à chaque question) : retrouver les bons passages + générer la réponse.

---

## ÉTAPE 1 — Le CHUNKING (découpage)

### C'est quoi, simplement
On ne peut pas donner un livre entier à l'ordinateur d'un coup. On le coupe en petits morceaux ("chunks") de taille gérable. C'est comme transformer un livre en un paquet de fiches de révision.

### Comment on l'a fait (2 niveaux)
1. **D'abord par page** : chaque page est traitée séparément → ça permet de **garder le numéro de page** de chaque morceau (indispensable pour citer la source).
2. **Puis en chunks** avec un "Recursive Character Text Splitter" :
   - taille d'un chunk = **1000 caractères**
   - chevauchement entre chunks = **200 caractères**
   - Résultat : **5020 chunks** à partir des 869 pages.

### Justification des paramètres (ce que le jury demandera)

**Pourquoi 1000 caractères par chunk ?**
C'est un compromis :
- Trop petit (ex. 200) → chaque morceau perd son contexte, l'idée est coupée, la recherche devient imprécise.
- Trop grand (ex. 4000) → un morceau contient plusieurs idées mélangées, l'embedding devient "flou" et moins précis, et on gaspille du contexte quand on le donne au LLM.
- **1000 caractères (~150-200 mots) = environ un paragraphe** : une unité de sens cohérente. C'est la valeur recommandée par défaut pour du RAG sur du texte dense.

**Pourquoi 200 de chevauchement (20%) ?**
Si on coupe net tous les 1000 caractères, une idée importante peut tomber pile à la frontière entre deux chunks et être "coupée en deux", donc mal retrouvée. Le chevauchement répète la fin d'un chunk au début du suivant → aucune idée n'est perdue à la jonction. **20% est le standard** (assez pour préserver le contexte, pas trop pour éviter la redondance inutile).

**Pourquoi "Recursive" ?**
Ce découpeur essaie de couper aux **frontières naturelles** dans l'ordre : d'abord entre paragraphes, sinon entre phrases, sinon entre mots. Il évite donc de couper au milieu d'un mot ou d'une phrase. C'est plus intelligent qu'un découpage brutal tous les X caractères.

**Pourquoi découper par page d'abord ?**
Pour conserver le **numéro de page** dans chaque chunk → c'est ce qui permet au chatbot de dire "(source : page 63)". Sans ça, pas de citation vérifiable.

---

## ÉTAPE 2 — L'EMBEDDING (vectorisation)

### C'est quoi, simplement
L'ordinateur ne comprend pas les mots, seulement les nombres. L'embedding transforme chaque chunk de texte en une longue liste de nombres (un **vecteur**) qui représente son **sens**. Deux textes au sens proche → vecteurs proches.

### Comment on l'a fait
- Modèle : **Google Gemini** (`gemini-embedding-001`)
- Chaque chunk → un vecteur de **3072 dimensions**
- Stockés dans **Postgres (Supabase)** avec l'extension **pgvector**, qui sait ranger des vecteurs et retrouver les plus proches.

### Justification des choix

**Pourquoi transformer en vecteurs ?**
Pour permettre la recherche **par le sens** et pas seulement par mots exacts. Si je demande "option qui s'exerce à l'échéance", le système doit trouver le passage sur les "options européennes" même si mes mots ne sont pas identiques. Seul l'embedding permet ça.

**Pourquoi Gemini ?**
- Qualité d'embedding élevée et multilingue (utile : livre en anglais, questions en français).
- **Gratuit** (clé Google AI Studio) → respecte la contrainte de budget 0€.

**Pourquoi 3072 dimensions ?**
C'est la taille produite par défaut par ce modèle. Plus de dimensions = représentation du sens plus riche et plus fine. (On n'a pas eu à la choisir : on l'a vérifiée réellement en base = 3072.)

**Pourquoi Postgres/pgvector (Supabase) ?**
Une base de données classique ne sait pas chercher "le vecteur le plus proche". pgvector ajoute cette capacité à Postgres. Supabase fournit ce Postgres gratuitement, prêt à l'emploi.

**Point clé à savoir dire :** le **même modèle d'embedding sert deux fois** — pour indexer les chunks ET pour transformer la question au moment de la recherche. Ils DOIVENT être identiques, sinon les vecteurs ne seraient pas comparables.

---

## ÉTAPE 3 — L'ANSWERING (recherche + réponse)

### C'est quoi, simplement
Quand tu poses une question : on la transforme en vecteur, on retrouve les passages du livre les plus pertinents, on les donne à Claude qui rédige la réponse avec les sources.

### Comment on l'a fait (pipeline explicite, nœud par nœud)
Chaque étape est un **nœud visible** (pas de « sous-nœud » boîte noire), dans cet ordre :
1. **Interface chat** avec **mémoire** (table `chat_turns` en SQL) → questions de suivi ("et pour l'option américaine ?").
2. **Embedding de la question** (HTTP → Gemini) : la question devient un vecteur, avec **le même modèle** qu'à l'indexation.
3. **Recherche hybride** — deux requêtes SQL combinées :
   - **Sémantique** (vecteurs, opérateur `<=>`) : trouve par le sens → 20 passages.
   - **Mots-clés** (full-text Postgres) : trouve les termes exacts (noms propres, sigles, formules nommées) → 8 passages.
4. **Fusion + dédoublonnage** des passages (nœud Code).
5. **Reranking (HTTP → Cohere)** : un modèle spécialisé **reclasse** ces candidats par pertinence et ne garde que les **5 meilleurs**.
6. **Augmentation** (nœud Code) : on **construit à la main le prompt** = consigne système + historique + les 5 extraits (avec leur page) + la question.
7. **Génération (nœud Claude)** : lit ce prompt et rédige la réponse **en citant la page**, sans inventer.
8. **Sauvegarde** de l'échange dans `chat_turns` (SQL) pour la mémoire.

**Pourquoi un pipeline explicite ?** À la demande du jury, on a supprimé le nœud « AI Agent » (qui faisait recherche + génération en boîte noire). Avantage : on **voit et contrôle chaque étape**, et on peut en **ajouter** (ex. un garde-fou "absent du livre", une traduction FR→EN de la question) à l'endroit voulu. L'indexation, elle, garde ses sous-nœuds car ils garantissent automatiquement le numéro de page (voir plus bas).

### Justification des choix

**Pourquoi une recherche hybride (et pas juste sémantique) ?**
La recherche par le sens peut rater un **terme technique précis** (ex. un nom de modèle, un sigle comme "CVA", une formule). La recherche par mots-clés rattrape exactement ces cas. Les deux ensemble = meilleure couverture.

**Pourquoi récupérer 20 passages puis n'en garder que 5 (reranking) ?**
La recherche vectorielle est rapide mais "approximative" : parmi ses 20 meilleurs résultats, les vraiment pertinents ne sont pas toujours dans le bon ordre. Le **reranker** est un modèle plus précis (mais plus lent) qui re-note ces 20 candidats et remonte les 5 meilleurs. On combine ainsi **rapidité** (vecteurs) et **précision** (rerank). Donner seulement les 5 meilleurs à Claude = réponse plus juste et moins de bruit.

**Pourquoi Claude pour la génération ?**
Bon niveau de rédaction et de synthèse, et **gratuit** via les crédits de la plateforme n8n (budget 0€).

**Pourquoi la mémoire de conversation ?**
Pour gérer les questions de suivi : sans mémoire, "et pour l'américaine ?" n'aurait aucun sens pour le système. La mémoire garde les derniers échanges en contexte.

**Pourquoi l'obliger à citer la page et interdire d'inventer ?**
C'est le cœur du RAG : une réponse **vérifiable** et **fiable**. On l'a testé — face à une erreur technique, il a refusé de répondre plutôt que d'inventer. C'est le comportement attendu d'un assistant documentaire sérieux.

---

## Récapitulatif des paramètres (tableau pour la soutenance)

| Paramètre | Valeur | Justification courte |
|---|---|---|
| Taille de chunk | 1000 caractères | ~1 paragraphe : assez de contexte, assez précis |
| Chevauchement | 200 (20%) | évite de couper une idée à la frontière |
| Découpage | récursif + par page | coupe aux frontières naturelles + garde la page |
| Modèle d'embedding | Gemini `gemini-embedding-001` | qualité + multilingue + gratuit |
| Dimensions | 3072 | défaut du modèle, sens riche |
| Base vectorielle | Postgres + pgvector (Supabase) | recherche de proximité + gratuit |
| Passages récupérés | 20 | large filet pour ne rien rater |
| Passages gardés après rerank | 5 | précision : seuls les meilleurs vont au LLM |
| Recherche | hybride (sémantique + mots-clés) | couvre sens ET termes exacts |
| LLM de réponse | Claude `claude-sonnet-5` | synthèse + gratuit (crédits n8n) |
| Mémoire | Table SQL `chat_turns` | questions de suivi |
| Architecture de réponse | explicite (sans sous-nœuds) | contrôle total + ajout d'étapes possible |

---

## Les 3 phrases à retenir pour le jury

1. **RAG = ne pas faire apprendre le livre au LLM, mais lui donner les bons extraits au bon moment** → réponses fiables et sourcées.
2. **Le chunking et l'embedding préparent le livre ; l'answering s'en sert** → d'où les deux temps (indexation une fois, réponse à chaque question).
3. **Chaque paramètre est un compromis** (taille de chunk, nombre de passages…) : ni trop, ni trop peu, pour équilibrer contexte, précision et coût.
