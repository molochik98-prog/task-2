-- Хеш, размер и тип считает worker, поэтому при вставке они ещё неизвестны.
BEGIN;
ALTER TABLE files ADD COLUMN IF NOT EXISTS content_type text;
ALTER TABLE files ALTER COLUMN size_bytes DROP NOT NULL;
ALTER TABLE files ALTER COLUMN sha256 DROP NOT NULL;
COMMIT;
