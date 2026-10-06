BEGIN;

CREATE TABLE IF NOT EXISTS files (
    id            uuid        PRIMARY KEY,
    object_key    text        NOT NULL UNIQUE,
    original_name text        NOT NULL,
    size_bytes    bigint      NOT NULL CHECK (size_bytes >= 0),
    sha256        text        NOT NULL,
    status        text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','uploaded','processing','done','failed')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS files_status_updated_idx ON files (status, updated_at);

GRANT SELECT, INSERT, UPDATE ON files TO appuser;

COMMIT;
