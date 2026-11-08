-- AlterTable
ALTER TABLE "User" ADD COLUMN     "avatar" BYTEA,
ADD COLUMN     "avatarAt" TIMESTAMP(3),
ADD COLUMN     "avatarType" TEXT;
