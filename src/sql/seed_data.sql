-- ============================================================
-- Seed data — run once against a freshly created database
-- ============================================================

-- ------------------------------------------------------------
-- roles
-- ------------------------------------------------------------
INSERT INTO roles (name) VALUES ('Admin'), ('Treasurer'), ('Offertory steward');

-- ------------------------------------------------------------
-- currencies
-- ------------------------------------------------------------
INSERT INTO currencies (code, name, symbol) VALUES
    ('KES', 'Kenyan Shilling', 'KSh'),
    ('USD', 'US Dollar', '$');

-- ------------------------------------------------------------
-- accounts
-- ------------------------------------------------------------
INSERT INTO accounts (name, account_type, currency_id, opening_balance) VALUES
    ('Coop Bank', 'bank', (SELECT id FROM currencies WHERE code = 'KES'), 0),
    ('Petty cash / M-Pesa', 'mobile_money_cash', (SELECT id FROM currencies WHERE code = 'KES'), 0);

-- ------------------------------------------------------------
-- genders
-- ------------------------------------------------------------
INSERT INTO genders (label) VALUES ('Male'), ('Female');

-- ------------------------------------------------------------
-- member_statuses
-- ------------------------------------------------------------
INSERT INTO member_statuses (label) VALUES ('Student'), ('Working'), ('Retired');

-- ------------------------------------------------------------
-- visitor_statuses
-- ------------------------------------------------------------
INSERT INTO visitor_statuses (label) VALUES ('Active'), ('Converted'), ('Lapsed');

-- ------------------------------------------------------------
-- location_statuses
-- ------------------------------------------------------------
INSERT INTO location_statuses (label) VALUES
    ('Within circuit'), ('Outside circuit'), ('Diaspora');

-- ------------------------------------------------------------
-- Fellowship groups
-- ------------------------------------------------------------
INSERT INTO fellowship_groups (name, description) VALUES
    ('Mens Fellowship', 'A fellowship for all men above 34 years'),
    ('Women Fellowship', 'A fellowship for all women above 34 years'),
    ('Youth Fellowship', 'A fellowship for all between 18 to 34 years'),
    ('Juniour Church', 'A fellowship for all children below 18 years');

-- ------------------------------------------------------------
-- categories: parent categories
-- ------------------------------------------------------------
INSERT INTO categories (name, category_type) VALUES
    ('Offertory', 'income'),
    ('Shukrani', 'income'),
    ('Tithe', 'income'),
    ('Donation', 'income'),
    ('Harambee', 'income'),
    ('Assessment', 'expense'),
    ('Stipend', 'expense'),
    ('Travel', 'expense'),
    ('Rent', 'expense'),
    ('Pension', 'expense'),
    ('Transaction Charges', 'expense'),
    ('Stationary', 'expense'),
    ('Entertainment', 'expense'),
    ('Airtime', 'expense'),
    ('Preacher Welfare', 'expense'),
    ('Bank Opening/Expense', 'expense'),
    ('Refund', 'expense'),
    ('Fuel', 'expense'),
    ('Maintenance', 'expense');

INSERT INTO categories (name, category_type, parent_category_id)
SELECT 'Special Offertory/Sadaka Maalum', 'income', id
FROM categories WHERE name = 'Offertory' AND category_type = 'income';

-- ------------------------------------------------------------
-- circuit targets, current year
-- per-minister: Stipend, Pension, Rent
-- circuit-wide (minister_id left NULL): Assessment Paid to synod
-- ------------------------------------------------------------
INSERT INTO society_targets (target_category_id, year, period, target_amount)
SELECT c.id, 2026, 'Annual', 1500000
FROM categories c
WHERE c.name = 'Assessment' AND c.category_type = 'expense';