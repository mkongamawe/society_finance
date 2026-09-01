-- ============================================================
-- Fellowship finance database — consolidated schema
-- Standalone database, separate from circuit_finance_dev
-- Target: PostgreSQL 13+
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- needed for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS postgis;  -- geography type + spatial indexing for member/visitor locations

-- ------------------------------------------------------------
-- users: treasurers and other people who can log in
-- ------------------------------------------------------------
CREATE TABLE users (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name   TEXT NOT NULL,
    email       TEXT NOT NULL UNIQUE,
    role        TEXT NOT NULL CHECK (role IN ('admin', 'treasurer', 'viewer')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- accounts: the physical places money sits
-- ------------------------------------------------------------
CREATE TABLE accounts (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name             TEXT NOT NULL UNIQUE,
    account_type     TEXT NOT NULL CHECK (account_type IN ('bank', 'mobile_money_cash')),
    currency         TEXT NOT NULL DEFAULT 'KES',
    opening_balance  NUMERIC(14, 2) NOT NULL DEFAULT 0,
    is_active        BOOLEAN NOT NULL DEFAULT true
);

-- ------------------------------------------------------------
-- funds: what pool of money a transaction belongs to
-- ------------------------------------------------------------
CREATE TABLE funds (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name           TEXT NOT NULL UNIQUE,
    description    TEXT,
    is_restricted  BOOLEAN NOT NULL DEFAULT false,
    is_active      BOOLEAN NOT NULL DEFAULT true
);

-- ------------------------------------------------------------
-- categories: the nature of a transaction (self-referencing for subcategories)
-- ------------------------------------------------------------
CREATE TABLE categories (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                 TEXT NOT NULL,
    category_type        TEXT NOT NULL CHECK (category_type IN ('income', 'expense')),
    parent_category_id   UUID REFERENCES categories(id) ON DELETE SET NULL,
    UNIQUE (name, category_type)
);

-- ------------------------------------------------------------
-- fellowship_groups: which fellowship a member belongs to
-- (Men's, Women's, Youth, Children's, etc.) Kept as a lookup
-- table rather than a fixed CHECK list so the church can
-- add/rename groups without a schema change.
-- ------------------------------------------------------------
CREATE TABLE fellowship_groups (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL UNIQUE,   -- e.g. 'Men''s Fellowship', 'Women''s Fellowship', 'Youth Fellowship'
    description TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT true
);

-- ------------------------------------------------------------
-- members: the fellowship's own membership roll
-- ------------------------------------------------------------
CREATE TABLE members (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name            TEXT NOT NULL,
    gender               TEXT NOT NULL CHECK (gender IN ('Male', 'Female')),
    phone_number         TEXT,
    member_status        TEXT NOT NULL DEFAULT 'Working' CHECK (member_status IN ('Student', 'Working', 'Retired')),
    is_active            BOOLEAN NOT NULL DEFAULT true,

    -- sacramental record
    baptism_status       BOOLEAN NOT NULL DEFAULT false,
    baptism_date         DATE,
    confirmation_status  BOOLEAN NOT NULL DEFAULT false,
    confirmation_date    DATE,

    -- which fellowship group this member belongs to
    fellowship_group_id  UUID REFERENCES fellowship_groups(id),

    -- location: a general area for everyday reference, a status
    -- describing that area relative to the circuit, and a precise
    -- point for mapping and proximity queries (SRID 4326 = WGS84,
    -- the lat/lng system GPS and every mapping API uses)
    general_area         TEXT,
    location_status      TEXT CHECK (location_status IN ('Within circuit', 'Outside circuit', 'Diaspora')),
    location              GEOGRAPHY(Point, 4326),   -- ST_MakePoint(longitude, latitude)::geography — note the order

    entered_by           UUID NOT NULL REFERENCES users(id),
    updated_by           UUID REFERENCES users(id),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_baptism_date_logical
        CHECK (baptism_date IS NULL OR baptism_status = true),
    CONSTRAINT chk_confirmation_date_logical
        CHECK (confirmation_date IS NULL OR confirmation_status = true)
);

CREATE INDEX idx_members_fellowship_group ON members(fellowship_group_id);
CREATE INDEX idx_members_location ON members USING GIST(location);

-- ------------------------------------------------------------
-- visitors: people attending who are not (yet) members.
-- Kept as its own table rather than a status flag on members,
-- so first-timers never touch member-scoped logic (targets,
-- fund contributions, etc.) until they actually convert.
-- ------------------------------------------------------------
CREATE TABLE visitors (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name             TEXT NOT NULL,
    phone_number          TEXT,
    gender                TEXT NOT NULL CHECK (gender IN ('Male', 'Female')),

    general_area          TEXT,
    location_status       TEXT CHECK (location_status IN ('Within circuit', 'Outside circuit', 'Diaspora')),
    location               GEOGRAPHY(Point, 4326),

    invited_by_member_id  UUID REFERENCES members(id),   -- who brought them, if known
    how_heard             TEXT,                          -- 'member_invite', 'walk_in', 'crusade', 'social_media', ...
    first_visit_date      DATE NOT NULL,

    visitor_status        TEXT NOT NULL DEFAULT 'Active' CHECK (visitor_status IN ('Active', 'Converted', 'LAapsed')),
    converted_member_id   UUID REFERENCES members(id),   -- set once transitioned to full membership
    converted_at          TIMESTAMPTZ,

    notes                 TEXT,
    entered_by            UUID NOT NULL REFERENCES users(id),
    updated_by            UUID REFERENCES users(id),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_conversion_consistency CHECK (
        (visitor_status = 'converted' AND converted_member_id IS NOT NULL)
        OR (visitor_status <> 'converted' AND converted_member_id IS NULL)
    )
);

CREATE INDEX idx_visitors_status ON visitors(visitor_status);
CREATE INDEX idx_visitors_invited_by ON visitors(invited_by_member_id);
CREATE INDEX idx_visitors_location ON visitors USING GIST(location);

-- ------------------------------------------------------------
-- visitor_visits: one row per time a visitor actually showed up.
-- This is what lets a scheduled job decide "has this person
-- attended enough / long enough to be transitioned to membership".
-- ------------------------------------------------------------
CREATE TABLE visitor_visits (
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
-- transactions: every income/expense entry
-- amount is always positive; direction comes from categories.category_type
-- ------------------------------------------------------------
CREATE TABLE transactions (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id               UUID NOT NULL REFERENCES accounts(id),
    category_id              UUID NOT NULL REFERENCES categories(id),
    fund_id                  UUID REFERENCES funds(id),
    member_id                UUID REFERENCES members(id),       -- set when tied to a member (registration, contribution)
    related_transaction_id   UUID REFERENCES transactions(id),  -- set for a charge tied to another transaction
    amount                   NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
    transaction_date         DATE NOT NULL,
    description              TEXT,
    entered_by               UUID NOT NULL REFERENCES users(id),
    updated_by               UUID REFERENCES users(id),
    is_voided                BOOLEAN NOT NULL DEFAULT false,
    voided_reason            TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_transactions_account   ON transactions(account_id);
CREATE INDEX idx_transactions_category  ON transactions(category_id);
CREATE INDEX idx_transactions_fund      ON transactions(fund_id);
CREATE INDEX idx_transactions_member    ON transactions(member_id);
CREATE INDEX idx_transactions_related   ON transactions(related_transaction_id);
CREATE INDEX idx_transactions_date      ON transactions(transaction_date);

-- ------------------------------------------------------------
-- transfers: money moving between accounts
-- ------------------------------------------------------------
CREATE TABLE transfers (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_account_id  UUID NOT NULL REFERENCES accounts(id),
    to_account_id    UUID NOT NULL REFERENCES accounts(id),
    amount           NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
    transfer_date    DATE NOT NULL,
    description      TEXT,
    entered_by       UUID NOT NULL REFERENCES users(id),
    updated_by       UUID REFERENCES users(id),
    is_voided        BOOLEAN NOT NULL DEFAULT false,
    voided_reason    TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (from_account_id <> to_account_id)
);

CREATE INDEX idx_transfers_from ON transfers(from_account_id);
CREATE INDEX idx_transfers_to   ON transfers(to_account_id);

-- ------------------------------------------------------------
-- audit_log: generic change history for any table
-- ------------------------------------------------------------
CREATE TABLE audit_log (
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
-- report_runs: a record of every generated report
-- ------------------------------------------------------------
CREATE TABLE report_runs (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_start   DATE NOT NULL,
    period_end     DATE NOT NULL,
    generated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    generated_by   UUID REFERENCES users(id),
    pdf_path       TEXT,
    UNIQUE (period_start, period_end)
);

-- ------------------------------------------------------------
-- fellowship_targets: flexible targets by category, per year.
-- Three levels of specificity, most specific wins:
--   1. member_id set        -> an override for one named individual
--   2. member_status set    -> applies to every student, or every working member
--   3. neither set          -> applies uniformly to everyone / the fellowship as a whole
-- 'period' says whether target_amount is a per-year or per-month figure.
-- ------------------------------------------------------------
CREATE TABLE society_targets (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_category_id  UUID NOT NULL REFERENCES categories(id),
    member_id            UUID REFERENCES members(id),
    member_status        TEXT CHECK (member_status IN ('Student', 'Working', 'Retired')),
    year                 INTEGER NOT NULL,
    period               TEXT NOT NULL CHECK (period IN ('Annual', 'Monthly')),
    target_amount        NUMERIC(14, 2) NOT NULL CHECK (target_amount > 0),

    -- a target should target at most one of: a specific member, or a status group
    CONSTRAINT chk_target_specificity
        CHECK (NOT (member_id IS NOT NULL AND member_status IS NOT NULL))
);

-- one uniform target per category per year, when it applies to everyone
CREATE UNIQUE INDEX idx_society_targets_uniform
    ON society_targets(target_category_id, year)
    WHERE member_id IS NULL AND member_status IS NULL;
-- one target per category per status group per year (student / working)
CREATE UNIQUE INDEX idx_society_targets_status
    ON society_targets(target_category_id, member_status, year)
    WHERE member_status IS NOT NULL;
-- one override target per category per member per year, if ever needed
CREATE UNIQUE INDEX idx_fellowship_targets_member
    ON society_targets(target_category_id, member_id, year)
    WHERE member_id IS NOT NULL;

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
-- account_balances: current balance per account, excluding voided rows
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW account_balances AS
SELECT
    a.id                    AS account_id,
    a.name                  AS account_name,
    a.opening_balance
        + COALESCE(SUM(
            CASE
                WHEN t.is_voided THEN 0
                WHEN c.category_type = 'income'  THEN t.amount
                WHEN c.category_type = 'expense' THEN -t.amount
                ELSE 0
            END
          ), 0)
        + COALESCE((SELECT SUM(tr_in.amount)  FROM transfers tr_in  WHERE tr_in.to_account_id = a.id AND NOT tr_in.is_voided), 0)
        - COALESCE((SELECT SUM(tr_out.amount) FROM transfers tr_out WHERE tr_out.from_account_id = a.id AND NOT tr_out.is_voided), 0)
        AS current_balance
FROM accounts a
LEFT JOIN transactions t ON t.account_id = a.id
LEFT JOIN categories c   ON c.id = t.category_id
GROUP BY a.id, a.name, a.opening_balance;

-- ------------------------------------------------------------
-- general_ledger: one chronological, read-only view of everything
-- ------------------------------------------------------------
CREATE VIEW general_ledger AS
SELECT * FROM (
    SELECT
        t.id,
        t.transaction_date          AS entry_date,
        a.name                      AS account_name,
        c.name                      AS category_name,
        f.name                      AS fund_name,
        mem.full_name               AS member_name,
        CASE WHEN c.category_type = 'income' THEN t.amount ELSE -t.amount END AS signed_amount,
        t.description,
        u.full_name                 AS entered_by_name,
        t.is_voided,
        t.voided_reason,
        'transaction'                AS entry_type
    FROM transactions t
    JOIN accounts a       ON a.id = t.account_id
    JOIN categories c     ON c.id = t.category_id
    LEFT JOIN funds f     ON f.id = t.fund_id
    LEFT JOIN members mem ON mem.id = t.member_id
    JOIN users u          ON u.id = t.entered_by

    UNION ALL

    SELECT
        tr.id,
        tr.transfer_date            AS entry_date,
        af.name || ' -> ' || ato.name AS account_name,
        'Transfer'                   AS category_name,
        NULL                          AS fund_name,
        NULL                          AS member_name,
        tr.amount                    AS signed_amount,
        tr.description,
        u.full_name                  AS entered_by_name,
        tr.is_voided,
        tr.voided_reason,
        'transfer'                    AS entry_type
    FROM transfers tr
    JOIN accounts af  ON af.id = tr.from_account_id
    JOIN accounts ato ON ato.id = tr.to_account_id
    JOIN users u      ON u.id = tr.entered_by
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
WHERE v.visitor_status = 'active'
GROUP BY v.id, v.full_name, v.first_visit_date
HAVING COUNT(vv.id) >= 4;

-- ------------------------------------------------------------
-- convert_visitor_to_member: the actual transition step.
-- A scheduled job (cron, pg_cron, app-level worker — whatever
-- runs the "daemon") would loop over
-- visitor_conversion_candidates and call this per visitor_id.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION convert_visitor_to_member(
    p_visitor_id     UUID,
    p_entered_by     UUID,             -- who/what triggered the conversion (a user, or a service account for the daemon)
    p_member_status  TEXT DEFAULT 'working'
)
RETURNS UUID AS $$
DECLARE
    v_member_id UUID;
    v           RECORD;
BEGIN
    SELECT * INTO v FROM visitors WHERE id = p_visitor_id AND visitor_status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Visitor % not found or not active', p_visitor_id;
    END IF;

    INSERT INTO members (full_name, phone_number, general_area, location_status, location, member_status, entered_by)
    VALUES (v.full_name, v.phone_number, v.general_area, v.location_status, v.location, p_member_status, p_entered_by)
    RETURNING id INTO v_member_id;

    UPDATE visitors
    SET visitor_status      = 'converted',
        converted_member_id = v_member_id,
        converted_at        = now(),
        updated_by           = p_entered_by,
        updated_at           = now()
    WHERE id = p_visitor_id;

    RETURN v_member_id;
END;
$$ LANGUAGE plpgsql;


-- ================================
-- New column
-- ===============================
-- A new column location2 us added to the database as a text column from NocoDB to 
-- take care of geoData. This was not created when building the database but afterwards from
-- NocoDb