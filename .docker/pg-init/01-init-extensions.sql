-- Enable the pgvector extension for use in Drupal's AI Vector database
CREATE EXTENSION IF NOT EXISTS vector;
-- Enable pg_trgm extension required by Drupal 11
CREATE EXTENSION IF NOT EXISTS pg_trgm;