-- AlterEnum
ALTER TYPE "TxType" ADD VALUE 'TOURNAMENT_BOUNTY';

-- AlterTable
ALTER TABLE "Tournament" ADD COLUMN     "bounty" INTEGER NOT NULL DEFAULT 0,
ADD COLUMN     "repeat" TEXT NOT NULL DEFAULT 'NONE';

-- AlterTable
ALTER TABLE "TournamentEntry" ADD COLUMN     "bountyWon" INTEGER NOT NULL DEFAULT 0,
ADD COLUMN     "knockouts" INTEGER NOT NULL DEFAULT 0;

-- AlterTable
ALTER TABLE "User" ADD COLUMN     "agentCode" TEXT,
ADD COLUMN     "lastDevice" TEXT,
ADD COLUMN     "lastIp" TEXT,
ADD COLUMN     "welcomeSeenAt" TIMESTAMP(3);

-- CreateTable
CREATE TABLE "FeeShare" (
    "id" TEXT NOT NULL,
    "tournamentId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "agentId" TEXT,
    "amount" INTEGER NOT NULL,
    "agentCut" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "FeeShare_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "SecurityAlert" (
    "id" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "tableId" TEXT,
    "tableName" TEXT,
    "userIds" TEXT[],
    "names" TEXT NOT NULL,
    "detail" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "seen" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "SecurityAlert_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "FeeShare_agentId_createdAt_idx" ON "FeeShare"("agentId", "createdAt");

-- CreateIndex
CREATE INDEX "FeeShare_createdAt_idx" ON "FeeShare"("createdAt");

-- CreateIndex
CREATE INDEX "SecurityAlert_createdAt_idx" ON "SecurityAlert"("createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "User_agentCode_key" ON "User"("agentCode");

-- AddForeignKey
ALTER TABLE "FeeShare" ADD CONSTRAINT "FeeShare_tournamentId_fkey" FOREIGN KEY ("tournamentId") REFERENCES "Tournament"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "FeeShare" ADD CONSTRAINT "FeeShare_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "FeeShare" ADD CONSTRAINT "FeeShare_agentId_fkey" FOREIGN KEY ("agentId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

