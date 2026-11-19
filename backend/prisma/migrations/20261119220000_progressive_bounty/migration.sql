-- AlterTable
ALTER TABLE "Tournament" ADD COLUMN     "progressive" BOOLEAN NOT NULL DEFAULT true;

-- AlterTable
ALTER TABLE "TournamentEntry" ADD COLUMN     "headBounty" INTEGER NOT NULL DEFAULT 0;

