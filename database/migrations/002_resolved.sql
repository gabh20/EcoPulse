-- Aplicar uma vez em bancos existentes. Não apaga ocorrências.
BEGIN;
ALTER TABLE reports DROP CONSTRAINT IF EXISTS reports_status_check;
ALTER TABLE reports ADD CONSTRAINT reports_status_check
    CHECK (status IN ('ACTIVE', 'EXPIRED', 'RESOLVED'));
COMMIT;
