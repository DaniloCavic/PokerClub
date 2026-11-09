-- AlterTable
ALTER TABLE "Hand" ADD COLUMN     "playerIds" TEXT[] DEFAULT ARRAY[]::TEXT[];

-- CreateIndex
CREATE INDEX "Hand_playerIds_idx" ON "Hand" USING GIN ("playerIds");

-- Postojeće ruke: igrači iz zapisa ruke
UPDATE "Hand" SET "playerIds" = ARRAY(SELECT p->>'userId' FROM jsonb_array_elements("details"->'players') AS p);
