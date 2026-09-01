-- ------------------------------------------------------------
-- Example spatial queries against the new `location` columns.
-- Not objects created by this script — just reference for the app/reports layer.
-- ------------------------------------------------------------

-- Insert a member's location (note: ST_MakePoint takes longitude first, then latitude)
-- UPDATE members
-- SET location = ST_SetSRID(ST_MakePoint(36.817223, -1.286389), 4326)::geography
-- WHERE id = '...';

-- Members within 5km of a given point (e.g. the church building)
-- SELECT full_name, general_area,
--        ST_Distance(location, ST_SetSRID(ST_MakePoint(36.817223, -1.286389), 4326)::geography) AS meters_away
-- FROM members
-- WHERE ST_DWithin(location, ST_SetSRID(ST_MakePoint(36.817223, -1.286389), 4326)::geography, 5000)
-- ORDER BY meters_away;

-- Nearest 10 members to a visitor, for assigning a follow-up host who lives close by
-- SELECT m.full_name, ST_Distance(m.location, v.location) AS meters_away
-- FROM members m, visitors v
-- WHERE v.id = '...' AND m.location IS NOT NULL
-- ORDER BY m.location <-> v.location
-- LIMIT 10;

-- -----------------------------------
-- Deleting a value from a table based on a value
-- -----------------------------------
DELETE FROM members
WHERE column_name = 'Clement Nyiro Mwagwabi'

-- -----------------------------------
-- Deleting all values of a table and all values in other tables with foreign keys from this table
-- -----------------------------------
TRUNCATE TABLE members CASCADE;