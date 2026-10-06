-- appdb принадлежит postgres, а не приложению.
-- Причина: владелец базы через роль pg_database_owner владеет и схемой public,
-- а владелец схемы может удалять любые таблицы в ней, в обход GRANT/REVOKE.
ALTER DATABASE appdb OWNER TO postgres;
