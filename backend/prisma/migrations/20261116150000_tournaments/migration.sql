-- CreateEnum
CREATE TYPE "TournamentStatus" AS ENUM ('REGISTERING', 'RUNNING', 'FINISHED', 'CANCELLED');

-- CreateEnum
CREATE TYPE "EntryStatus" AS ENUM ('PLAYING', 'BUSTED');

-- AlterEnum
-- This migration adds more than one value to an enum.
-- With PostgreSQL versions 11 and earlier, this is not possible
-- in a single migration. This can be worked around by creating
-- multiple migrations, each migration adding only one value to
-- the enum.


ALTER TYPE "TxType" ADD VALUE 'TOURNAMENT_BUY_IN';
ALTER TYPE "TxType" ADD VALUE 'TOURNAMENT_PRIZE';
ALTER TYPE "TxType" ADD VALUE 'TOURNAMENT_REFUND';

-- AlterTable
ALTER TABLE "PokerTable" ADD COLUMN     "tournamentId" TEXT;

-- CreateTable
CREATE TABLE "Tournament" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "variant" "Variant" NOT NULL,
    "status" "TournamentStatus" NOT NULL DEFAULT 'REGISTERING',
    "startAt" TIMESTAMP(3) NOT NULL,
    "buyIn" INTEGER NOT NULL,
    "fee" INTEGER NOT NULL DEFAULT 0,
    "startingStack" INTEGER NOT NULL,
    "maxPlayers" INTEGER NOT NULL DEFAULT 0,
    "minPlayers" INTEGER NOT NULL DEFAULT 2,
    "tableSize" INTEGER NOT NULL DEFAULT 9,
    "actionSeconds" INTEGER NOT NULL DEFAULT 20,
    "levels" JSONB NOT NULL,
    "breakMode" TEXT NOT NULL DEFAULT 'HOURLY',
    "breakEvery" INTEGER NOT NULL DEFAULT 4,
    "breakMinutes" INTEGER NOT NULL DEFAULT 5,
    "lateRegLevels" INTEGER NOT NULL DEFAULT 0,
    "rebuyLevels" INTEGER NOT NULL DEFAULT 0,
    "rebuyMax" INTEGER NOT NULL DEFAULT 0,
    "rebuyPrice" INTEGER NOT NULL DEFAULT 0,
    "rebuyFee" INTEGER NOT NULL DEFAULT 0,
    "rebuyChips" INTEGER NOT NULL DEFAULT 0,
    "rebuyBelow" INTEGER NOT NULL DEFAULT 0,
    "reentryMax" INTEGER NOT NULL DEFAULT 0,
    "addonLevel" INTEGER NOT NULL DEFAULT 0,
    "addonPrice" INTEGER NOT NULL DEFAULT 0,
    "addonFee" INTEGER NOT NULL DEFAULT 0,
    "addonChips" INTEGER NOT NULL DEFAULT 0,
    "guarantee" INTEGER NOT NULL DEFAULT 0,
    "payoutMode" TEXT NOT NULL DEFAULT 'PERCENT',
    "payPercent" INTEGER NOT NULL DEFAULT 15,
    "payouts" JSONB NOT NULL DEFAULT '[]',
    "estimatedMinutes" INTEGER NOT NULL DEFAULT 0,
    "createdById" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "startedAt" TIMESTAMP(3),
    "finishedAt" TIMESTAMP(3),
    "prizePool" INTEGER NOT NULL DEFAULT 0,

    CONSTRAINT "Tournament_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "TournamentEntry" (
    "id" TEXT NOT NULL,
    "tournamentId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "entryNo" INTEGER NOT NULL DEFAULT 1,
    "status" "EntryStatus" NOT NULL DEFAULT 'PLAYING',
    "chips" INTEGER NOT NULL,
    "rebuys" INTEGER NOT NULL DEFAULT 0,
    "addons" INTEGER NOT NULL DEFAULT 0,
    "position" INTEGER,
    "prize" INTEGER NOT NULL DEFAULT 0,
    "paid" INTEGER NOT NULL DEFAULT 0,
    "feePaid" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "bustedAt" TIMESTAMP(3),

    CONSTRAINT "TournamentEntry_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Tournament_status_startAt_idx" ON "Tournament"("status", "startAt");

-- CreateIndex
CREATE INDEX "TournamentEntry_tournamentId_status_idx" ON "TournamentEntry"("tournamentId", "status");

-- CreateIndex
CREATE UNIQUE INDEX "TournamentEntry_tournamentId_userId_entryNo_key" ON "TournamentEntry"("tournamentId", "userId", "entryNo");

-- AddForeignKey
ALTER TABLE "PokerTable" ADD CONSTRAINT "PokerTable_tournamentId_fkey" FOREIGN KEY ("tournamentId") REFERENCES "Tournament"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Tournament" ADD CONSTRAINT "Tournament_createdById_fkey" FOREIGN KEY ("createdById") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "TournamentEntry" ADD CONSTRAINT "TournamentEntry_tournamentId_fkey" FOREIGN KEY ("tournamentId") REFERENCES "Tournament"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "TournamentEntry" ADD CONSTRAINT "TournamentEntry_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

