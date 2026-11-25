-- CreateTable
CREATE TABLE "AgentEarning" (
    "id" TEXT NOT NULL,
    "agentId" TEXT NOT NULL,
    "playerId" TEXT NOT NULL,
    "rakeShareId" TEXT,
    "feeShareId" TEXT,
    "amount" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AgentEarning_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "AgentEarning_agentId_createdAt_idx" ON "AgentEarning"("agentId", "createdAt");

-- CreateIndex
CREATE INDEX "AgentEarning_agentId_playerId_idx" ON "AgentEarning"("agentId", "playerId");

-- AddForeignKey
ALTER TABLE "AgentEarning" ADD CONSTRAINT "AgentEarning_agentId_fkey" FOREIGN KEY ("agentId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AgentEarning" ADD CONSTRAINT "AgentEarning_rakeShareId_fkey" FOREIGN KEY ("rakeShareId") REFERENCES "RakeShare"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AgentEarning" ADD CONSTRAINT "AgentEarning_feeShareId_fkey" FOREIGN KEY ("feeShareId") REFERENCES "FeeShare"("id") ON DELETE SET NULL ON UPDATE CASCADE;


-- Dosadašnje zarade agenata (jedan nivo): prenose se u novu tabelu.
INSERT INTO "AgentEarning" ("id", "agentId", "playerId", "rakeShareId", "amount", "createdAt")
SELECT 'ae_r_' || "id", "agentId", "userId", "id", "agentCut", "createdAt" FROM "RakeShare" WHERE "agentId" IS NOT NULL AND "agentCut" > 0;
INSERT INTO "AgentEarning" ("id", "agentId", "playerId", "feeShareId", "amount", "createdAt")
SELECT 'ae_f_' || "id", "agentId", "userId", "id", "agentCut", "createdAt" FROM "FeeShare" WHERE "agentId" IS NOT NULL AND "agentCut" > 0;
