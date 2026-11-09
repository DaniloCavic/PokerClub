-- AlterTable
ALTER TABLE "PokerTable" ADD COLUMN     "opensAt" TIMESTAMP(3);

-- AlterTable
ALTER TABLE "User" ADD COLUMN     "rakeShareBps" INTEGER NOT NULL DEFAULT 0;

-- CreateTable
CREATE TABLE "RakeShare" (
    "id" TEXT NOT NULL,
    "handId" TEXT NOT NULL,
    "tableId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "agentId" TEXT,
    "amount" INTEGER NOT NULL,
    "agentCut" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "RakeShare_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "RakeShare_agentId_createdAt_idx" ON "RakeShare"("agentId", "createdAt");

-- CreateIndex
CREATE INDEX "RakeShare_createdAt_idx" ON "RakeShare"("createdAt");

-- CreateIndex
CREATE INDEX "RakeShare_userId_idx" ON "RakeShare"("userId");

-- AddForeignKey
ALTER TABLE "RakeShare" ADD CONSTRAINT "RakeShare_handId_fkey" FOREIGN KEY ("handId") REFERENCES "Hand"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RakeShare" ADD CONSTRAINT "RakeShare_tableId_fkey" FOREIGN KEY ("tableId") REFERENCES "PokerTable"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RakeShare" ADD CONSTRAINT "RakeShare_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RakeShare" ADD CONSTRAINT "RakeShare_agentId_fkey" FOREIGN KEY ("agentId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;
