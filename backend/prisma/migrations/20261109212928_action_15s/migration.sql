-- AlterTable
ALTER TABLE "PokerTable" ALTER COLUMN "actionSeconds" SET DEFAULT 15;
UPDATE "PokerTable" SET "actionSeconds" = 15;
