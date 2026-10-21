-- D-103 (BR-145): a stock adjustment is a third kind of stock movement. The value is
-- added on its own, because Postgres lets a new enum value be used only after the
-- transaction that added it has committed; migration 0054 uses it. Nothing else changes
-- here: no row, check or function reads the new value yet.
alter type stock_move add value if not exists 'adjust';
