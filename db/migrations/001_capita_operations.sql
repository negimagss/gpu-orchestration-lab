-- ══════════════════════════════════════════════════════════════
-- Capita Operations Team — Complaint Management System
-- Database: PostgreSQL
-- ══════════════════════════════════════════════════════════════

-- ── ENUMS ────────────────────────────────────────────────────

CREATE TYPE customer_type AS ENUM ('commercial', 'private');

CREATE TYPE complaint_type AS ENUM (
    'billing',
    'service_outage',
    'technical',
    'account',
    'general',
    'escalation'
);

CREATE TYPE complaint_status AS ENUM (
    'open',
    'in_progress',
    'awaiting_customer',
    'escalated',
    'resolved',
    'closed'
);

CREATE TYPE resolution_outcome AS ENUM (
    'active',
    'resolved',
    'abandoned',
    'wrong_call'
);


-- ── TEAMS ────────────────────────────────────────────────────
-- Operations teams that handle complaints

CREATE TABLE teams (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_name       VARCHAR(100) NOT NULL UNIQUE,
    location        VARCHAR(255),
    duties          TEXT,
    regions         TEXT[],                     -- Array of region codes team covers
    latitude        DECIMAL(10, 7),
    longitude       DECIMAL(10, 7),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_teams_regions ON teams USING GIN (regions);
CREATE INDEX idx_teams_location ON teams (location);


-- ── CUSTOMERS ────────────────────────────────────────────────
-- Initial customer creation and info

CREATE TABLE customers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,
    region          VARCHAR(100) NOT NULL,
    address         TEXT,
    customer_type   customer_type NOT NULL DEFAULT 'private',
    customer_since  DATE NOT NULL DEFAULT CURRENT_DATE,
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    deleted_at      TIMESTAMPTZ,                -- Soft delete
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_customers_region ON customers (region);
CREATE INDEX idx_customers_active ON customers (active) WHERE active = TRUE;
CREATE INDEX idx_customers_type ON customers (customer_type);
CREATE INDEX idx_customers_deleted ON customers (deleted_at) WHERE deleted_at IS NULL;


-- ── COMPLAINTS ───────────────────────────────────────────────
-- Complaint records linked to customers

CREATE TABLE complaints (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    type            complaint_type NOT NULL,
    status          complaint_status NOT NULL DEFAULT 'open',
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ                 -- Soft delete
);

CREATE INDEX idx_complaints_customer ON complaints (customer_id);
CREATE INDEX idx_complaints_status ON complaints (status);
CREATE INDEX idx_complaints_type ON complaints (type);
CREATE INDEX idx_complaints_created ON complaints (created_at DESC);
CREATE INDEX idx_complaints_deleted ON complaints (deleted_at) WHERE deleted_at IS NULL;


-- ── STATUS HISTORY ───────────────────────────────────────────
-- Tracks every status change for a complaint (audit trail)
-- No primary key on id as specified — uses auto-generated serial

CREATE TABLE complaint_status_history (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY,  -- NOT a primary key
    complaint_id        UUID NOT NULL REFERENCES complaints(id) ON DELETE CASCADE,
    team_id             UUID REFERENCES teams(id) ON DELETE SET NULL,
    description         TEXT,
    status              complaint_status NOT NULL,
    resolution_notes    JSONB DEFAULT '{}',
    /*
        resolution_notes example:
        {
            "root_cause": "billing system sync delay",
            "action_taken": "manual adjustment applied",
            "customer_contacted": true,
            "follow_up_required": false,
            "internal_notes": "ticket #4521 linked"
        }
    */
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- No PK constraint — but we still index for fast lookups
CREATE INDEX idx_status_history_complaint ON complaint_status_history (complaint_id);
CREATE INDEX idx_status_history_team ON complaint_status_history (team_id);
CREATE INDEX idx_status_history_status ON complaint_status_history (status);
CREATE INDEX idx_status_history_created ON complaint_status_history (created_at DESC);
CREATE INDEX idx_status_history_resolution ON complaint_status_history
    USING GIN (resolution_notes);


-- ── DELEGATIONS ──────────────────────────────────────────────
-- Which team is assigned to resolve which complaint

CREATE TABLE delegations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    complaint_id        UUID NOT NULL REFERENCES complaints(id) ON DELETE CASCADE,
    team_id             UUID NOT NULL REFERENCES teams(id) ON DELETE RESTRICT,
    support_engineer    VARCHAR(255),
    outcome             resolution_outcome NOT NULL DEFAULT 'active',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ                 -- Soft delete
);

CREATE INDEX idx_delegations_complaint ON delegations (complaint_id);
CREATE INDEX idx_delegations_team ON delegations (team_id);
CREATE INDEX idx_delegations_outcome ON delegations (outcome);
CREATE INDEX idx_delegations_engineer ON delegations (support_engineer);
CREATE INDEX idx_delegations_active ON delegations (outcome) WHERE outcome = 'active';


-- ══════════════════════════════════════════════════════════════
-- TRIGGERS — Auto-update updated_at timestamps
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_customers_updated
    BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION update_timestamp();

CREATE TRIGGER trg_complaints_updated
    BEFORE UPDATE ON complaints
    FOR EACH ROW EXECUTE FUNCTION update_timestamp();

CREATE TRIGGER trg_teams_updated
    BEFORE UPDATE ON teams
    FOR EACH ROW EXECUTE FUNCTION update_timestamp();

CREATE TRIGGER trg_delegations_updated
    BEFORE UPDATE ON delegations
    FOR EACH ROW EXECUTE FUNCTION update_timestamp();


-- ══════════════════════════════════════════════════════════════
-- TRIGGER — Auto-insert status history when complaint status changes
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION track_complaint_status_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO complaint_status_history (complaint_id, status, description)
        VALUES (NEW.id, NEW.status, 'Status changed from ' || OLD.status || ' to ' || NEW.status);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_complaint_status_track
    AFTER UPDATE ON complaints
    FOR EACH ROW EXECUTE FUNCTION track_complaint_status_change();


-- ══════════════════════════════════════════════════════════════
-- SEED DATA — Sample teams
-- ══════════════════════════════════════════════════════════════

INSERT INTO teams (team_name, location, duties, regions, latitude, longitude) VALUES
    ('North Operations',    'Manchester',   'Handles billing and service complaints',       ARRAY['north', 'northwest', 'northeast'],  53.4808, -2.2426),
    ('South Operations',    'London',       'Handles technical and escalation complaints',  ARRAY['south', 'southeast', 'southwest'],  51.5074, -0.1278),
    ('Midlands Support',    'Birmingham',   'General complaints and account issues',        ARRAY['midlands', 'east_midlands', 'west_midlands'], 52.4862, -1.8904),
    ('Scotland & NI Ops',   'Edinburgh',    'Full service coverage for Scotland and NI',    ARRAY['scotland', 'northern_ireland'],      55.9533, -3.1883);
