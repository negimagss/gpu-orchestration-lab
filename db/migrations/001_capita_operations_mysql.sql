-- ══════════════════════════════════════════════════════════════
-- Capita Operations Team — Complaint Management System
-- Database: MySQL 8.0+
-- ══════════════════════════════════════════════════════════════

-- ── TEAMS ────────────────────────────────────────────────────
-- Operations teams that handle complaints

CREATE TABLE teams (
    id              CHAR(36) PRIMARY KEY DEFAULT (UUID()),
    team_name       VARCHAR(100) NOT NULL UNIQUE,
    location        VARCHAR(255),
    duties          TEXT,
    regions         JSON DEFAULT JSON_ARRAY(),         -- JSON array of region codes
    latitude        DECIMAL(10, 7),
    longitude       DECIMAL(10, 7),
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE INDEX idx_teams_location ON teams (location);


-- ── CUSTOMERS ────────────────────────────────────────────────
-- Initial customer creation and info

CREATE TABLE customers (
    id              CHAR(36) PRIMARY KEY DEFAULT (UUID()),
    name            VARCHAR(255) NOT NULL,
    region          VARCHAR(100) NOT NULL,
    address         TEXT,
    customer_type   ENUM('commercial', 'private') NOT NULL DEFAULT 'private',
    customer_since  DATE NOT NULL DEFAULT CURDATE(),
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    deleted_at      TIMESTAMP NULL,                    -- Soft delete
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE INDEX idx_customers_region ON customers (region);
CREATE INDEX idx_customers_active ON customers (active);
CREATE INDEX idx_customers_type ON customers (customer_type);
CREATE INDEX idx_customers_deleted ON customers (deleted_at);


-- ── COMPLAINTS ───────────────────────────────────────────────
-- Complaint records linked to customers

CREATE TABLE complaints (
    id              CHAR(36) PRIMARY KEY DEFAULT (UUID()),
    customer_id     CHAR(36) NOT NULL,
    type            ENUM('billing', 'service_outage', 'technical', 'account', 'general', 'escalation') NOT NULL,
    status          ENUM('open', 'in_progress', 'awaiting_customer', 'escalated', 'resolved', 'closed') NOT NULL DEFAULT 'open',
    description     TEXT,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted_at      TIMESTAMP NULL,                    -- Soft delete

    CONSTRAINT fk_complaints_customer FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE RESTRICT
);

CREATE INDEX idx_complaints_customer ON complaints (customer_id);
CREATE INDEX idx_complaints_status ON complaints (status);
CREATE INDEX idx_complaints_type ON complaints (type);
CREATE INDEX idx_complaints_created ON complaints (created_at DESC);
CREATE INDEX idx_complaints_deleted ON complaints (deleted_at);


-- ── STATUS HISTORY ───────────────────────────────────────────
-- Tracks every status change for a complaint (audit trail)
-- No primary key as specified — uses auto-generated id

CREATE TABLE complaint_status_history (
    id                  BIGINT AUTO_INCREMENT UNIQUE,  -- Auto-incremented but NOT primary key
    complaint_id        CHAR(36) NOT NULL,
    team_id             CHAR(36),
    description         TEXT,
    status              ENUM('open', 'in_progress', 'awaiting_customer', 'escalated', 'resolved', 'closed') NOT NULL,
    resolution_notes    JSON DEFAULT JSON_OBJECT(),
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
    created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_status_history_complaint FOREIGN KEY (complaint_id) REFERENCES complaints(id) ON DELETE CASCADE,
    CONSTRAINT fk_status_history_team FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE SET NULL
);

CREATE INDEX idx_status_history_complaint ON complaint_status_history (complaint_id);
CREATE INDEX idx_status_history_team ON complaint_status_history (team_id);
CREATE INDEX idx_status_history_status ON complaint_status_history (status);
CREATE INDEX idx_status_history_created ON complaint_status_history (created_at DESC);


-- ── DELEGATIONS ──────────────────────────────────────────────
-- Which team is assigned to resolve which complaint

CREATE TABLE delegations (
    id                  CHAR(36) PRIMARY KEY DEFAULT (UUID()),
    complaint_id        CHAR(36) NOT NULL,
    team_id             CHAR(36) NOT NULL,
    support_engineer    VARCHAR(255),
    outcome             ENUM('active', 'resolved', 'abandoned', 'wrong_call') NOT NULL DEFAULT 'active',
    created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMP NULL,                -- Soft delete

    CONSTRAINT fk_delegations_complaint FOREIGN KEY (complaint_id) REFERENCES complaints(id) ON DELETE CASCADE,
    CONSTRAINT fk_delegations_team FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE RESTRICT
);

CREATE INDEX idx_delegations_complaint ON delegations (complaint_id);
CREATE INDEX idx_delegations_team ON delegations (team_id);
CREATE INDEX idx_delegations_outcome ON delegations (outcome);
CREATE INDEX idx_delegations_engineer ON delegations (support_engineer);


-- ══════════════════════════════════════════════════════════════
-- TRIGGERS — Auto-insert status history when complaint status changes
-- ══════════════════════════════════════════════════════════════

DELIMITER $$

CREATE TRIGGER trg_complaint_status_track
AFTER UPDATE ON complaints
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status OR OLD.status IS NULL THEN
        INSERT INTO complaint_status_history (complaint_id, status, description)
        VALUES (NEW.id, NEW.status, CONCAT('Status changed from ', COALESCE(OLD.status, 'none'), ' to ', NEW.status));
    END IF;
END$$

DELIMITER ;


-- ══════════════════════════════════════════════════════════════
-- SEED DATA — Sample teams
-- ══════════════════════════════════════════════════════════════

INSERT INTO teams (team_name, location, duties, regions, latitude, longitude) VALUES
    (UUID(), 'North Operations',    'Manchester',   'Handles billing and service complaints',       JSON_ARRAY('north', 'northwest', 'northeast'),  53.4808, -2.2426),
    (UUID(), 'South Operations',    'London',       'Handles technical and escalation complaints',  JSON_ARRAY('south', 'southeast', 'southwest'),  51.5074, -0.1278),
    (UUID(), 'Midlands Support',    'Birmingham',   'General complaints and account issues',        JSON_ARRAY('midlands', 'east_midlands', 'west_midlands'), 52.4862, -1.8904),
    (UUID(), 'Scotland & NI Ops',   'Edinburgh',    'Full service coverage for Scotland and NI',    JSON_ARRAY('scotland', 'northern_ireland'),      55.9533, -3.1883);
