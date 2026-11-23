-- CreateTable
CREATE TABLE "CashRequest" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "agentId" TEXT,
    "type" TEXT NOT NULL,
    "amount" INTEGER NOT NULL,
    "note" TEXT,
    "status" TEXT NOT NULL DEFAULT 'PENDING',
    "decidedById" TEXT,
    "decidedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "CashRequest_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "CashRequest_status_createdAt_idx" ON "CashRequest"("status", "createdAt");

-- CreateIndex
CREATE INDEX "CashRequest_agentId_status_idx" ON "CashRequest"("agentId", "status");

-- CreateIndex
CREATE INDEX "CashRequest_userId_createdAt_idx" ON "CashRequest"("userId", "createdAt");

