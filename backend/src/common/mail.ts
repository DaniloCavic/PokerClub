import { Logger } from '@nestjs/common';
import * as nodemailer from 'nodemailer';

const log = new Logger('Mail');

/**
 * Slanje e-pošte (SMTP). Podešava se na Railway-u:
 *   SMTP_HOST, SMTP_PORT (465 ili 587), SMTP_USER, SMTP_PASS, MAIL_FROM.
 * Npr. Gmail: SMTP_HOST=smtp.gmail.com, SMTP_PORT=465, SMTP_USER=adresa@gmail.com,
 * SMTP_PASS=lozinka za aplikacije (App Password).
 * Bez podešavanja poruka se samo upiše u log servera (za probu).
 */
export async function sendMail(to: string, subject: string, text: string) {
  const host = process.env.SMTP_HOST;
  if (!host) {
    log.warn(`SMTP nije podešen. Poruka za ${to}: ${subject}\n${text}`);
    return false;
  }
  const port = Number(process.env.SMTP_PORT || 465);
  const transport = nodemailer.createTransport({
    host,
    port,
    secure: port === 465,
    auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS } : undefined,
  });
  await transport.sendMail({ from: process.env.MAIL_FROM || process.env.SMTP_USER, to, subject, text });
  return true;
}

export const mailReady = () => !!process.env.SMTP_HOST;
