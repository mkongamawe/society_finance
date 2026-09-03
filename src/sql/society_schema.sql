-- ============================================================
-- Church finance & congregation database — consolidated schema
-- Standalone database, separate from circuit_finance_dev
-- Target: PostgreSQL 13+ (uses GENERATED ALWAYS AS ... STORED, PG12+)
--
-- Revision notes (this pass, per reviewer feedback):
--   - roles, currencies, genders, member_statuses, location_statuses
--     added as lookup tables; users/accounts/members/visitors/
--     society_targets now reference them by FK instead of inline text.
--   - full_name split into first_name / middle_name / surname on
--     users, members, visitors. full_name kept as a GENERATED column
--     so every existing view/join that reads full_name still works.
--   - PostGIS geography dropped in favor of a plain `location` TEXT
--     column (NocoDB compatibility) — see note on the members table.
--   - Voided transactions/transfers no longer use an is_voided flag.
--     Voiding now inserts a mirrored, negative-amount reversal row
--     (voided_tx_id points back at the original). See void_transaction()
--     and void_transfer() near the bottom of this file.
--   - report_runs drops pdf_path and its per-period UNIQUE constraint,
--     since we no longer store PDFs and want every run recorded, even
--     repeat runs of the same period.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- needed for gen_random_uuid()
-- CREATE EXTENSION IF NOT EXISTS postgis;  -- geography type + spatial indexing for member/visitor locations

-- ------------------------------------------------------------
-- roles: who's allowed to do what. A lookup table rather than a
-- CHECK list so new roles don't require a schema change.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roles (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL UNIQUE,  -- 'Admin', 'Treasurer', 'Viewer'
    description  TEXT
);

-- ------------------------------------------------------------
-- currencies: what an account's balance is denominated in.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS currencies (
    id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code    TEXT NOT NULL UNIQUE,   -- ISO 4217, e.g. 'KES', 'USD'
    name    TEXT NOT NULL,
    symbol  TEXT
);

-- ------------------------------------------------------------
-- genders: kept as a lookup rather than a CHECK list so a new
-- category can be added without a migration.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS genders (
    id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label  TEXT NOT NULL UNIQUE
);

-- ------------------------------------------------------------
-- member_statuses: a member's life stage — drives targets and
-- the Members dashboard breakdown.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS member_statuses (
    id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label  TEXT NOT NULL UNIQUE  -- 'Student', 'Working', 'Retired'
);

-- ------------------------------------------------------------
-- location_statuses: where someone lives, relative to the circuit.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS location_statuses (
    id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label  TEXT NOT NULL UNIQUE  -- 'Within circuit', 'Outside circuit', 'Diaspora'
);

-- ------------------------------------------------------------
-- member_statuses: a member's life stage — drives targets and
-- the Members dashboard breakdown.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS visitor_statuses (
    id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label  TEXT NOT NULL UNIQUE  -- 'Active', 'Converted', 'Lapsed'
);

-- ----------------------------------------
-- Create function because concat_ws and trim/brim and array_to_string are not
-- considered IMMUTABLE
-- ----------------------------------------
CREATE OR REPLACE FUNCTION build_full_name(
    first_name  TEXT,
    middle_name TEXT,
    surname     TEXT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT btrim(
        COALESCE(NULLIF(first_name,  ''), '') ||
        CASE WHEN NULLIF(middle_name, '') IS NOT NULL THEN ' ' || middle_name ELSE '' END ||
        CASE WHEN NULLIF(surname,     '') IS NOT NULL THEN ' ' || surname     ELSE '' END
    );
$$;

-- ------------------------------------------------------------
-- users: treasurers and other people who can log in
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name   TEXT NOT NULL,
    middle_name  TEXT,
    surname      TEXT NOT NULL,
    full_name   TEXT GENERATED ALWAYS AS (
        build_full_name(first_name, middle_name, surname)
    ) STORED,
    email        TEXT NOT NULL UNIQUE,
    role_id      UUID NOT NULL REFERENCES roles(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- accounts: the physical places money sits
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS accounts (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name             TEXT NOT NULL UNIQUE,
    account_type     TEXT NOT NULL CHECK (account_type IN ('bank', 'mobile_money_cash')),
    currency_id      UUID NOT NULL REFERENCES currencies(id),
    opening_balance  NUMERIC(14, 2) NOT NULL DEFAULT 0,
    is_active        BOOLEAN NOT NULL DEFAULT true
);

-- ------------------------------------------------------------
-- funds: what pool of money a transaction belongs to
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS funds (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name           TEXT NOT NULL UNIQUE,
    description    TEXT,
    is_restricted  BOOLEAN NOT NULL DEFAULT false,
    is_active      BOOLEAN NOT NULL DEFAULT true
);

-- ------------------------------------------------------------
-- categories: the nature of a transaction (self-referencing for subcategories)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS categories (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                 TEXT NOT NULL,
    category_type        TEXT NOT NULL CHECK (category_type IN ('income', 'expense')),
    parent_category_id   UUID REFERENCES categories(id) ON DELETE SET NULL,
    UNIQUE (name, category_type)
);

-- ------------------------------------------------------------
-- fellowship_groups: which fellowship a member belongs to
-- (Men's, Women's, Youth, Children's, etc.)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fellowship_groups (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT true
);

-- ------------------------------------------------------------
-- members: the fellowship's own membership roll
--
-- Location note: this used to carry a PostGIS `geography(Point,4326)`
-- column, but that didn't play well with NocoDB's editing UI, so it's
-- back to a plain TEXT column here — NocoDB does the lat/long ->
-- geodata conversion on its side. This trades away in-database
-- proximity queries (ST_DWithin, ST_Distance, the GiST index) for
-- compatibility with the tool the data actually gets edited in.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS members (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name            TEXT NOT NULL,
    middle_name           TEXT,
    surname               TEXT NOT NULL,
    full_name   TEXT GENERATED ALWAYS AS (
        build_full_name(first_name, middle_name, surname)
    ) STORED,
    gender_id             UUID NOT NULL REFERENCES genders(id),
    phone_number          TEXT,
    member_status_id      UUID NOT NULL REFERENCES member_statuses(id),
    is_active             BOOLEAN NOT NULL DEFAULT true,

    -- sacramental record
    baptism_status        BOOLEAN NOT NULL DEFAULT false,
    baptism_date          DATE,
    confirmation_status   BOOLEAN NOT NULL DEFAULT false,
    confirmation_date     DATE,

    -- which fellowship group this member belongs to
    fellowship_group_id   UUID REFERENCES fellowship_groups(id),

    -- for a child/youth member, who their parent/guardian member is
    parent_member_id      UUID REFERENCES members(id) ON DELETE SET NULL,

    -- location: a general area for everyday reference, a status
    -- relative to the circuit, and a free-text point (see note above)
    general_area          TEXT,
    location_status_id    UUID REFERENCES location_statuses(id),
    location_text         TEXT,   -- e.g. "-1.286389, 36.817223" — geocoded downstream in NocoDB
    location_geo          GEOGRAPHY(Point, 4326), -- to be used/implemented later in the UI

    entered_by             UUID NOT NULL REFERENCES users(id),
    updated_by              UUID REFERENCES users(id),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_baptism_date_logical
        CHECK (baptism_date IS NULL OR baptism_status = true),
    CONSTRAINT chk_confirmation_date_logical
        CHECK (confirmation_date IS NULL OR confirmation_status = true)
);

CREATE INDEX idx_members_fellowship_group  ON members(fellowship_group_id);
CREATE INDEX idx_members_status            ON members(member_status_id);
CREATE INDEX idx_members_location_status   ON members(location_status_id);
CREATE INDEX idx_members_parent            ON members(parent_member_id);
CREATE INDEX idx_members_location_geo      ON members USING GIST(location_geo);

-- ------------------------------------------------------------
-- visitors: people attending who are not (yet) members.
-- Kept as its own table rather than a status flag on members,
-- so first-timers never touch member-scoped logic (targets,
-- fund contributions, etc.) until they actually convert.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS visitors (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name            TEXT NOT NULL,
    middle_name           TEXT,
    surname               TEXT NOT NULL,
    full_name   TEXT GENERATED ALWAYS AS (
        build_full_name(first_name, middle_name, surname)
    ) STORED,
    gender_id             UUID NOT NULL REFERENCES genders(id),
    phone_number          TEXT,

    general_area          TEXT,
    location_status_id    UUID REFERENCES location_statuses(id),
    location_text         TEXT,
    location_geo          GEOGRAPHY(Point, 4326),

    invited_by_member_id  UUID REFERENCES members(id),   -- who brought them, if known
    how_heard             TEXT,                          -- 'member_invite', 'walk_in', 'crusade', 'social_media', ...
    first_visit_date      DATE NOT NULL,

    visitor_status         TEXT NOT NULL DEFAULT 'Active' CHECK (visitor_status IN ('Active', 'Converted', 'Lapsed')),
    converted_member_id   UUID REFERENCES members(id),   -- set once transitioned to full membership
    converted_at           TIMESTAMPTZ,

    notes                  TEXT,
    entered_by              UUID NOT NULL REFERENCES users(id),
    updated_by                UUID REFERENCES users(id),
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_conversion_consistency CHECK (
        (visitor_status = 'Converted' AND converted_member_id IS NOT NULL)
        OR (visitor_status <> 'Converted' AND converted_member_id IS NULL)
    )
);

CREATE INDEX idx_visitors_status           ON visitors(visitor_status);
CREATE INDEX idx_visitors_invited_by       ON visitors(invited_by_member_id);
CREATE INDEX idx_visitors_location_status  ON visitors(location_status_id);

-- ------------------------------------------------------------
-- visitor_visits: one row per time a visitor actually showed up.
-- This is what lets a scheduled job decide "has this person
-- attended enough / long enough to be transitioned to membership".
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS visitor_visits (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visitor_id           UUID NOT NULL REFERENCES visitors(id) ON DELETE CASCADE,
    visit_date           DATE NOT NULL,
    fellowship_group_id  UUID REFERENCES fellowship_groups(id),  -- which service/fellowship they attended, if relevant
    recorded_by          UUID REFERENCES users(id),

    UNIQUE (visitor_id, visit_date)
);

CREATE INDEX idx_visitor_visits_visitor ON visitor_visits(visitor_id);
CREATE INDEX idx_visitor_visits_date ON visitor_visits(visit_date);

-- ------------------------------------------------------------
-- transactions: every income/expense entry.
--
-- Voiding note: there is no is_voided flag. To void a transaction,
-- a second row is inserted with the same account/category/fund/member,
-- the amount negated, and voided_tx_id pointing back at the original
-- (see void_transaction() near the bottom of this file). Direction
-- still comes from the linked category's category_type — negating
-- the amount on the reversal row makes it cancel the original exactly
-- when summed, no matter which category_type it belongs to. This
-- means every balance/ledger view can do a plain SUM(), with no
-- per-row flag to check.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id               UUID NOT NULL REFERENCES accounts(id),
    category_id              UUID NOT NULL REFERENCES categories(id),
    fund_id                  UUID REFERENCES funds(id),
    member_id                UUID REFERENCES members(id),       -- set when tied to a member (registration, contribution)
    related_transaction_id   UUID REFERENCES transactions(id),  -- set for a charge tied to another transaction (e.g. a fee)
    voided_tx_id              UUID REFERENCES transactions(id),  -- set on a reversal row; points at the transaction it cancels
    amount                    NUMERIC(14, 2) NOT NULL,
    transaction_date          DATE NOT NULL,
    description                TEXT,
    voided_reason               TEXT,   -- populated on the reversal row, explaining why
    entered_by                   UUID NOT NULL REFERENCES users(id),
    updated_by                    UUID REFERENCES users(id),
    created_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_amount_sign CHECK (
        (voided_tx_id IS NULL AND amount > 0)      -- ordinary entries are always positive
        OR (voided_tx_id IS NOT NULL AND amount < 0) -- reversal entries are always negative
    )
);

CREATE INDEX idx_transactions_account   ON transactions(account_id);
CREATE INDEX idx_transactions_category  ON transactions(category_id);
CREATE INDEX idx_transactions_fund      ON transactions(fund_id);
CREATE INDEX idx_transactions_member    ON transactions(member_id);
CREATE INDEX idx_transactions_related   ON transactions(related_transaction_id);
CREATE INDEX idx_transactions_voided    ON transactions(voided_tx_id);
CREATE INDEX idx_transactions_date      ON transactions(transaction_date);

-- a transaction can only be voided once
CREATE UNIQUE INDEX idx_transactions_voided_once
    ON transactions(voided_tx_id)
    WHERE voided_tx_id IS NOT NULL;

-- ------------------------------------------------------------
-- transfers: money moving between accounts.
-- Same voiding pattern as transactions — see void_transfer().
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transfers (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_account_id   UUID NOT NULL REFERENCES accounts(id),
    to_account_id     UUID NOT NULL REFERENCES accounts(id),
    voided_tx_id       UUID REFERENCES transfers(id),
    amount              NUMERIC(14, 2) NOT NULL,
    transfer_date        DATE NOT NULL,
    description            TEXT,
    voided_reason           TEXT,
    entered_by               UUID NOT NULL REFERENCES users(id),
    updated_by                 UUID REFERENCES users(id),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (from_account_id <> to_account_id),
    CONSTRAINT chk_transfer_amount_sign CHECK (
        (voided_tx_id IS NULL AND amount > 0)
        OR (voided_tx_id IS NOT NULL AND amount < 0)
    )
);

CREATE INDEX idx_transfers_from   ON transfers(from_account_id);
CREATE INDEX idx_transfers_to     ON transfers(to_account_id);
CREATE INDEX idx_transfers_voided ON transfers(voided_tx_id);

CREATE UNIQUE INDEX idx_transfers_voided_once
    ON transfers(voided_tx_id)
    WHERE voided_tx_id IS NOT NULL;

-- ------------------------------------------------------------
-- Void Request Table. This is to help NocoDB's data Entry.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS void_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id  UUID REFERENCES transactions(id),
    transfer_id     UUID REFERENCES transfers(id),
    reason          TEXT,
    requested_by    UUID NOT NULL REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at    TIMESTAMPTZ,
    reversal_tx_id  UUID REFERENCES transactions(id),
    reversal_tr_id  UUID REFERENCES transfers(id),

    CONSTRAINT chk_void_target CHECK (
        (transaction_id IS NOT NULL AND transfer_id IS NULL) OR
        (transaction_id IS NULL AND transfer_id IS NOT NULL)
    )
);

-- ------------------------------------------------------------
-- audit_log: generic change history for any table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name   TEXT NOT NULL,
    record_id    UUID NOT NULL,
    action       TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    changed_by   UUID REFERENCES users(id),
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    diff         JSONB
);

CREATE INDEX idx_audit_log_record ON audit_log(table_name, record_id);

-- ------------------------------------------------------------
-- report_runs: a record of every generated report.
-- PDFs are no longer stored — just what period was reported on and
-- when. No uniqueness constraint on the period: re-running a report
-- for the same period is expected and every run gets its own row.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS report_runs (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_start   DATE NOT NULL,
    period_end     DATE NOT NULL,
    generated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    generated_by   UUID REFERENCES users(id)
);

CREATE INDEX idx_report_runs_period ON report_runs(period_start, period_end);

-- ------------------------------------------------------------
-- society_targets: flexible giving targets by category, per year.
-- Three levels of specificity, most specific wins:
--   1. member_id set          -> an override for one named individual
--   2. member_status_id set   -> applies to every member in that status group
--   3. neither set            -> applies uniformly to everyone
-- 'period' says whether target_amount is a per-year or per-month figure.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS society_targets (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_category_id   UUID NOT NULL REFERENCES categories(id),
    member_id              UUID REFERENCES members(id),
    member_status_id        UUID REFERENCES member_statuses(id),
    year                     INTEGER NOT NULL,
    period                    TEXT NOT NULL CHECK (period IN ('Annual', 'Monthly')),
    target_amount              NUMERIC(14, 2) NOT NULL CHECK (target_amount > 0),

    -- a target should target at most one of: a specific member, or a status group
    CONSTRAINT chk_target_specificity
        CHECK (NOT (member_id IS NOT NULL AND member_status_id IS NOT NULL))
);

-- one uniform target per category per year, when it applies to everyone
CREATE UNIQUE INDEX idx_society_targets_uniform
    ON society_targets(target_category_id, year)
    WHERE member_id IS NULL AND member_status_id IS NULL;
-- one target per category per status group per year
CREATE UNIQUE INDEX idx_society_targets_status
    ON society_targets(target_category_id, member_status_id, year)
    WHERE member_status_id IS NOT NULL;
-- one override target per category per member per year, if ever needed
CREATE UNIQUE INDEX idx_society_targets_member
    ON society_targets(target_category_id, member_id, year)
    WHERE member_id IS NOT NULL;


-- ------------------------------------------------------------
-- Process void requests.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_void_request()
RETURNS TRIGGER AS $$
DECLARE
    v_reversal_id UUID;
BEGIN
    IF NEW.transaction_id IS NOT NULL THEN
        SELECT void_transaction(NEW.transaction_id, NEW.requested_by, NEW.reason)
        INTO v_reversal_id;
        NEW.reversal_tx_id := v_reversal_id;

    ELSIF NEW.transfer_id IS NOT NULL THEN
        SELECT void_transfer(NEW.transfer_id, NEW.requested_by, NEW.reason)
        INTO v_reversal_id;
        NEW.reversal_tr_id := v_reversal_id;
    END IF;

    NEW.processed_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_process_void_request
    BEFORE INSERT ON void_requests
    FOR EACH ROW
    EXECUTE FUNCTION process_void_request();
    
-- ------------------------------------------------------------
-- keep updated_at current on edits
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_transactions_updated_at
    BEFORE UPDATE ON transactions
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_members_updated_at
    BEFORE UPDATE ON members
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_visitors_updated_at
    BEFORE UPDATE ON visitors
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- ------------------------------------------------------------
-- generic audit trigger: fires no matter which tool issues the SQL.
-- Works on any table carrying entered_by/updated_by columns —
-- currently transactions, transfers, members, and visitors.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION log_audit_event()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (table_name, record_id, action, diff)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD));
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (table_name, record_id, action, changed_by, diff)
        VALUES (
            TG_TABLE_NAME, NEW.id, 'UPDATE', NEW.updated_by,
            jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW))
        );
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, record_id, action, changed_by, diff)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', NEW.entered_by, to_jsonb(NEW));
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_transactions_audit
    AFTER INSERT OR UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION log_audit_event();

CREATE TRIGGER trg_transfers_audit
    AFTER INSERT OR UPDATE OR DELETE ON transfers
    FOR EACH ROW EXECUTE FUNCTION log_audit_event();

CREATE TRIGGER trg_members_audit
    AFTER INSERT OR UPDATE OR DELETE ON members
    FOR EACH ROW EXECUTE FUNCTION log_audit_event();

CREATE TRIGGER trg_visitors_audit
    AFTER INSERT OR UPDATE OR DELETE ON visitors
    FOR EACH ROW EXECUTE FUNCTION log_audit_event();

-- ------------------------------------------------------------
-- account_balances: current balance per account.
-- No is_voided filter needed anymore — a voided transaction's
-- negative-amount reversal row cancels it out under a plain SUM().
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW account_balances AS
SELECT
    a.id                    AS account_id,
    a.name                  AS account_name,
    a.opening_balance
        + COALESCE(SUM(
            CASE
                WHEN c.category_type = 'income'  THEN t.amount
                WHEN c.category_type = 'expense' THEN -t.amount
                ELSE 0
            END
          ), 0)
        + COALESCE((SELECT SUM(tr_in.amount)  FROM transfers tr_in  WHERE tr_in.to_account_id = a.id), 0)
        - COALESCE((SELECT SUM(tr_out.amount) FROM transfers tr_out WHERE tr_out.from_account_id = a.id), 0)
        AS current_balance
FROM accounts a
LEFT JOIN transactions t ON t.account_id = a.id
LEFT JOIN categories c   ON c.id = t.category_id
GROUP BY a.id, a.name, a.opening_balance;

-- ------------------------------------------------------------
-- general_ledger: one chronological, read-only view of everything.
-- is_voided/voided_reason booleans are gone; is_reversal + which
-- entry a row reverses (voids_entry_date) replace them.
-- category_type preserves the original income/expense direction on
-- reversal rows so reporting can net them correctly.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS general_ledger;
CREATE VIEW general_ledger AS
SELECT * FROM (
    SELECT
        t.id,
        t.transaction_date            AS entry_date,
        a.name                        AS account_name,
        c.name                        AS category_name,
        c.category_type               AS category_type,
        f.name                        AS fund_name,
        mem.full_name                 AS member_name,
        CASE WHEN c.category_type = 'income' THEN t.amount ELSE -t.amount END AS signed_amount,
        t.description,
        u.full_name                   AS entered_by_name,
        (t.voided_tx_id IS NOT NULL)  AS is_reversal,
        vt.transaction_date           AS voids_entry_date,
        t.voided_reason,
        'transaction'                  AS entry_type
    FROM transactions t
    JOIN accounts a       ON a.id = t.account_id
    JOIN categories c     ON c.id = t.category_id
    LEFT JOIN funds f     ON f.id = t.fund_id
    LEFT JOIN members mem ON mem.id = t.member_id
    JOIN users u          ON u.id = t.entered_by
    LEFT JOIN transactions vt ON vt.id = t.voided_tx_id

    UNION ALL

    SELECT
        tr.id,
        tr.transfer_date              AS entry_date,
        af.name || ' -> ' || ato.name AS account_name,
        'Transfer'                     AS category_name,
        'transfer'                     AS category_type,
        NULL                            AS fund_name,
        NULL                            AS member_name,
        tr.amount                      AS signed_amount,
        tr.description,
        u.full_name                    AS entered_by_name,
        (tr.voided_tx_id IS NOT NULL)  AS is_reversal,
        vtr.transfer_date              AS voids_entry_date,
        tr.voided_reason,
        'transfer'                      AS entry_type
    FROM transfers tr
    JOIN accounts af  ON af.id = tr.from_account_id
    JOIN accounts ato ON ato.id = tr.to_account_id
    JOIN users u      ON u.id = tr.entered_by
    LEFT JOIN transfers vtr ON vtr.id = tr.voided_tx_id
) combined
ORDER BY entry_date DESC;

-- ------------------------------------------------------------
-- visitor_conversion_candidates: view a scheduled job can poll
-- to decide who's ready to be transitioned. Threshold below
-- (4+ visits) is a starting point — tune to what your church
-- actually wants ("visited every week for a month", etc.)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW visitor_conversion_candidates AS
SELECT
    v.id                AS visitor_id,
    v.full_name,
    v.first_visit_date,
    COUNT(vv.id)         AS visit_count,
    MIN(vv.visit_date)   AS earliest_visit,
    MAX(vv.visit_date)   AS latest_visit
FROM visitors v
JOIN visitor_visits vv ON vv.visitor_id = v.id
WHERE v.visitor_status = 'Active'
GROUP BY v.id, v.full_name, v.first_visit_date
HAVING COUNT(vv.id) >= 4;

-- ------------------------------------------------------------
-- convert_visitor_to_member: the actual transition step.
-- A scheduled job (cron, pg_cron, app-level worker — whatever
-- runs the "daemon") would loop over
-- visitor_conversion_candidates and call this per visitor_id.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION convert_visitor_to_member(
    p_visitor_id        UUID,
    p_entered_by         UUID,   -- who/what triggered the conversion (a user, or a service account for the daemon)
    p_member_status_id   UUID DEFAULT NULL  -- defaults to 'Working' below if not supplied
)
RETURNS UUID AS $$
DECLARE
    v_member_id  UUID;
    v            RECORD;
    v_status_id  UUID;
BEGIN
    SELECT * INTO v FROM visitors WHERE id = p_visitor_id AND visitor_status = 'Active';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Visitor % not found or not active', p_visitor_id;
    END IF;

    v_status_id := COALESCE(
        p_member_status_id,
        (SELECT id FROM member_statuses WHERE label = 'Working')
    );

    INSERT INTO members (
        first_name, middle_name, surname, gender_id, phone_number,
        general_area, location_status_id, location, member_status_id, entered_by
    )
    VALUES (
        v.first_name, v.middle_name, v.surname, v.gender_id, v.phone_number,
        v.general_area, v.location_status_id, v.location, v_status_id, p_entered_by
    )
    RETURNING id INTO v_member_id;

    UPDATE visitors
    SET visitor_status      = 'Converted',
        converted_member_id = v_member_id,
        converted_at         = now(),
        updated_by            = p_entered_by,
        updated_at             = now()
    WHERE id = p_visitor_id;

    RETURN v_member_id;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- void_transaction / void_transfer: the voiding mechanism itself.
-- Rather than trusting every caller to build the mirrored reversal
-- row correctly by hand, these functions do it: fetch the original,
-- copy its dimensions (account/category/fund/member, or from/to
-- account), negate the amount, and stamp voided_tx_id. Guards
-- against voiding a reversal row itself, or voiding the same
-- transaction twice (the partial unique indexes above enforce
-- the latter at the DB level too).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION void_transaction(
    p_transaction_id  UUID,
    p_entered_by       UUID,
    p_reason            TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_reversal_id  UUID;
    orig           RECORD;
BEGIN
    SELECT * INTO orig FROM transactions WHERE id = p_transaction_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % not found', p_transaction_id;
    END IF;

    IF orig.voided_tx_id IS NOT NULL THEN
        RAISE EXCEPTION 'Transaction % is itself a reversal entry and cannot be voided', p_transaction_id;
    END IF;

    IF EXISTS (SELECT 1 FROM transactions WHERE voided_tx_id = p_transaction_id) THEN
        RAISE EXCEPTION 'Transaction % has already been voided', p_transaction_id;
    END IF;

    INSERT INTO transactions (
        account_id, category_id, fund_id, member_id, voided_tx_id,
        amount, transaction_date, description, voided_reason, entered_by
    )
    VALUES (
        orig.account_id, orig.category_id, orig.fund_id, orig.member_id, orig.id,
        -orig.amount, CURRENT_DATE, orig.description, p_reason, p_entered_by
    )
    RETURNING id INTO v_reversal_id;

    RETURN v_reversal_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION void_transfer(
    p_transfer_id  UUID,
    p_entered_by    UUID,
    p_reason         TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_reversal_id  UUID;
    orig           RECORD;
BEGIN
    SELECT * INTO orig FROM transfers WHERE id = p_transfer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transfer % not found', p_transfer_id;
    END IF;

    IF orig.voided_tx_id IS NOT NULL THEN
        RAISE EXCEPTION 'Transfer % is itself a reversal entry and cannot be voided', p_transfer_id;
    END IF;

    IF EXISTS (SELECT 1 FROM transfers WHERE voided_tx_id = p_transfer_id) THEN
        RAISE EXCEPTION 'Transfer % has already been voided', p_transfer_id;
    END IF;

    -- same from/to accounts, negated amount: contribution to each
    -- account's balance flips sign and exactly cancels the original.
    INSERT INTO transfers (
        from_account_id, to_account_id, voided_tx_id,
        amount, transfer_date, description, voided_reason, entered_by
    )
    VALUES (
        orig.from_account_id, orig.to_account_id, orig.id,
        -orig.amount, CURRENT_DATE, orig.description, p_reason, p_entered_by
    )
    RETURNING id INTO v_reversal_id;

    RETURN v_reversal_id;
END;
$$ LANGUAGE plpgsql;


-- ================================
-- New column
-- ===============================
-- location_text whereas is text here is converted to GeoData in NocoDB