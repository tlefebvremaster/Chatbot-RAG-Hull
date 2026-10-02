-- Schéma Postgres / Supabase pour le chatbot RAG (livre de John Hull)
-- À exécuter dans l'éditeur SQL de Supabase avant la première indexation.

-- 1. Extension vecteurs (pgvector)
create extension if not exists vector;

-- 2. Table des passages du livre.
--    Note : en pratique, le nœud n8n "PGVector" crée cette table automatiquement
--    au premier insert (avec la bonne dimension = 3072, sortie de Gemini).
--    Ce script sert de documentation / reproductibilité.
create table if not exists documents (
  id        bigserial primary key,
  text      text,
  metadata  jsonb,
  embedding vector(3072)
);

-- 3. Index full-text (recherche par mots-clés = moitié "hybride" de la recherche)
create index if not exists documents_text_fts
  on documents using gin (to_tsvector('english', text));

-- Remarque : pas d'index ANN sur la colonne embedding.
-- pgvector n'indexe pas les vecteurs de plus de 2000 dimensions (ici 3072),
-- donc la recherche vectorielle fait un balayage exact — suffisant à l'échelle d'un livre.

-- 4. Table mémoire de conversation (questions de suivi)
create table if not exists chat_turns (
  id         bigserial primary key,
  session_id text,
  question   text,
  answer     text,
  created_at timestamptz default now()
);

create index if not exists chat_turns_session_idx
  on chat_turns (session_id, created_at desc);
