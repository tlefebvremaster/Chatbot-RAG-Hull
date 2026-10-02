# Specs | Chatbot RAG — Options, Futures and Other Derivatives (Hull)

## 1. Déclencheur & Livrable attendu

### 1.1 Déclencheur
**Mise à jour (choix final) : interface de chat.** Le projet a évolué vers une **interface de chat n8n** (fenêtre de conversation), jugée plus pertinente pour une démonstration/soutenance et cohérente avec le niveau "avancé" visé. Elle apporte aussi la **mémoire de conversation** (questions de suivi).

*Choix initial (conservé pour historique) : appel direct via webhook/API, sans interface dédiée — une version webhook a été construite puis remplacée par la version chat avancée.*

### 1.2 Portée de l'indexation
Le livre *Options, Futures and Other Derivatives* (8th edition, John Hull) est vectorisé **une seule fois**. Il n'y a pas de besoin de ré-indexation récurrente ni d'ajout d'autres documents à la base pour ce projet.

### 1.3 Format de la réponse
Pour chaque question posée :
- Une **réponse rédigée en texte libre**, en langage naturel, répondant directement à la question.
- La **citation de la source** dans le livre (chapitre et/ou page) d'où provient l'information, pour permettre une vérification.

## 2. Outils & Écosystème

### 2.1 Outils imposés
- **Automatisation** : n8n (accès via MCP déjà en place).
- **Base vectorielle** : Supabase.
- **Modèle de génération (LLM)** : Anthropic Claude.

### 2.2 État des accès
- n8n (MCP) : déjà disponible.
- Compte Supabase : déjà disponible.
- Clé API Anthropic : **à récupérer** — l'utilisateur dispose déjà d'un crédit/abonnement Claude existant, donc l'usage de cette clé pour le projet n'engendre pas de coût supplémentaire direct.

### 2.3 Limites connues à prendre en compte
- **Quota du plan gratuit Supabase** (stockage/requêtes) à respecter — le volume de contenu vectorisé et le rythme de requêtes doivent rester dans ces limites.

## 3. Contraintes opérationnelles & Gestion des échecs

### 3.1 Volume attendu
Usage **ponctuel, pour une démonstration/soutenance** du projet M2 — pas un usage quotidien soutenu ni multi-utilisateurs réguliers.

### 3.2 Budget d'exécution
**0 € de coût additionnel.** L'utilisation de Claude s'appuie sur un crédit/abonnement déjà existant, pas sur un nouveau budget dédié à ce projet.

### 3.3 Comportement attendu en cas d'échec
Pas une priorité pour cette version : si un appel à Claude, Supabase ou n8n échoue en cours de traitement, **aucune exigence spécifique de récupération** (pas de retry automatique ni d'alerte formalisée demandés à ce stade).

### 3.4 Confidentialité & sécurité
Aucune contrainte particulière identifiée : le contenu (manuel académique) et l'usage (projet étudiant) ne sont pas considérés comme sensibles.

---

## Synthèse

| Dimension | Réponse |
|---|---|
| Déclencheur | Interface de chat n8n (avec mémoire de conversation) — *version webhook initiale remplacée* |
| Indexation | Une seule fois, ce livre uniquement |
| Format de réponse | Texte libre + citation de la source (chapitre/page) |
| Automatisation | n8n (via MCP) |
| Base vectorielle | Supabase |
| LLM de génération | Anthropic Claude |
| Accès | n8n ✓, Supabase ✓, clé Anthropic à récupérer |
| Limite connue | Quota plan gratuit Supabase |
| Volume | Usage ponctuel (démo/soutenance M2) |
| Budget | 0 € additionnel (crédit Claude existant) |
| Gestion des erreurs | Non prioritaire pour cette version |
| Confidentialité | Aucune contrainte particulière |
