-- Human metadata. Bibliographic edits survive the next scrape; decisions are automated.
CREATE TABLE IF NOT EXISTS documents (
    title TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '',
    doc_date TEXT NOT NULL DEFAULT '',
    doc_type TEXT NOT NULL DEFAULT '',
    country TEXT NOT NULL DEFAULT '',
    project_id TEXT NOT NULL DEFAULT '',
    project_title TEXT NOT NULL DEFAULT '',
    report_no TEXT NOT NULL DEFAULT '',
    language TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL DEFAULT '',
    filename TEXT NOT NULL DEFAULT '',
    download_status TEXT NOT NULL DEFAULT '',
    screen_status TEXT NOT NULL DEFAULT '',
    filter_reason TEXT NOT NULL DEFAULT '',
    id TEXT PRIMARY KEY
);

-- Source evidence and download checks remain separate from human corrections.
CREATE TABLE IF NOT EXISTS retrieval_state (
    id TEXT PRIMARY KEY,
    record_json TEXT NOT NULL,
    download_json TEXT NOT NULL DEFAULT '{}',
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL
);

-- Receipts are written only after a successful parse or extraction.
CREATE TABLE IF NOT EXISTS processing (
    id TEXT NOT NULL REFERENCES documents(id),
    stage TEXT NOT NULL CHECK (stage IN ('parse', 'extract')),
    input_sha256 TEXT NOT NULL,
    recipe TEXT NOT NULL,
    output_sha256 TEXT NOT NULL,
    completed_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id, stage)
);

-- Content changes invalidate parsing; changed parsed content invalidates extraction.
CREATE VIEW IF NOT EXISTS processing_status AS
SELECT d.source, d.id, d.filename,
    COALESCE(json_extract(s.download_json, '$.sha256'), '') AS sha256,
    COALESCE(json_extract(s.download_json, '$.status'), '')
        IN ('downloaded', 'skipped_valid', 'adopted_local') AS available,
    COALESCE(p.input_sha256, '') AS parsed_input,
    COALESCE(p.recipe, '') AS parse_recipe,
    COALESCE(p.output_sha256, '') AS parsed_sha256,
    COALESCE(e.input_sha256, '') AS extracted_input,
    COALESCE(e.recipe, '') AS extract_recipe,
    COALESCE(e.output_sha256, '') AS extracted_sha256,
    json_array(d.title, d.doc_date, d.doc_type, d.country, d.project_id,
        d.project_title, d.report_no) AS metadata_json,
    COALESCE(p.input_sha256, '') != COALESCE(json_extract(s.download_json, '$.sha256'), '')
        OR p.id IS NULL AS needs_parse,
    COALESCE(p.input_sha256, '') != COALESCE(json_extract(s.download_json, '$.sha256'), '')
        OR e.id IS NULL OR COALESCE(e.input_sha256, '') != COALESCE(p.output_sha256, '')
        OR COALESCE(e.metadata_json, '') != json_array(d.title, d.doc_date, d.doc_type,
            d.country, d.project_id, d.project_title, d.report_no)
        AS needs_extract
FROM documents d JOIN retrieval_state s USING (id)
LEFT JOIN processing p ON p.id = d.id AND p.stage = 'parse'
LEFT JOIN processing e ON e.id = d.id AND e.stage = 'extract'
WHERE d.screen_status != 'drop';
