-- AlterTable
ALTER TABLE "PokerTable" ADD COLUMN     "bombPotBB" INTEGER NOT NULL DEFAULT 2,
ADD COLUMN     "bombPotEvery" INTEGER NOT NULL DEFAULT 0,
ADD COLUMN     "straddle" BOOLEAN NOT NULL DEFAULT false;

-- CreateTable
CREATE TABLE "PlayerNote" (
    "ownerId" TEXT NOT NULL,
    "targetId" TEXT NOT NULL,
    "text" TEXT NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "PlayerNote_pkey" PRIMARY KEY ("ownerId","targetId")
);

-- AddForeignKey
ALTER TABLE "PlayerNote" ADD CONSTRAINT "PlayerNote_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "PlayerNote" ADD CONSTRAINT "PlayerNote_targetId_fkey" FOREIGN KEY ("targetId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

