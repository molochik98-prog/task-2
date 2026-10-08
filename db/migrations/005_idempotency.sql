BEGIN;

ALTER TABLE files ADD COLUMN IF NOT EXISTS idempotency_key text;

-- Частичный unique: строки без ключа (старые, загрузки без заголовка) не конфликтуют.
CREATE UNIQUE INDEX IF NOT EXISTS files_idempotency_key_uidx
    ON files (idempotency_key) WHERE idempotency_key IS NOT NULL;

COMMIT;
