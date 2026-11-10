-- CreateTable
CREATE TABLE "LiveViewLog" (
    "id" TEXT NOT NULL,
    "actorId" TEXT NOT NULL,
    "tableId" TEXT NOT NULL,
    "tableName" TEXT NOT NULL,
    "handNo" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "LiveViewLog_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "LiveViewLog_createdAt_idx" ON "LiveViewLog"("createdAt");

-- AddForeignKey
ALTER TABLE "LiveViewLog" ADD CONSTRAINT "LiveViewLog_actorId_fkey" FOREIGN KEY ("actorId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
