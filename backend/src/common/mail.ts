import { Logger } from '@nestjs/common';
import * as nodemailer from 'nodemailer';

const log = new Logger('Mail');

/**
 * Slanje e-pošte. Dva načina (podešava se na Railway-u):
 *  1) Brevo (preporučeno ako hosting blokira SMTP): BREVO_API_KEY i MAIL_FROM (adresa potvrđena u Brevo-u).
 *  2) SMTP: SMTP_HOST, SMTP_PORT (465 ili 587), SMTP_USER, SMTP_PASS, MAIL_FROM.
 *     Npr. Gmail: SMTP_HOST=smtp.gmail.com, SMTP_PORT=465, SMTP_USER=adresa@gmail.com, SMTP_PASS=App Password.
 * Bez podešavanja poruka se samo upiše u log servera (za probu).
 * Greška se baca (i upisuje u log), da se vidi zašto mejl nije otišao.
 */
export async function sendMail(to: string, subject: string, text: string): Promise<boolean> {
  const from = process.env.MAIL_FROM || process.env.SMTP_USER || '';
  try {
    if (process.env.BREVO_API_KEY) {
      const m = /^(.*)<(.+)>\s*$/.exec(from);
      const sender = m ? { name: m[1].trim() || 'Poker klub Triling', email: m[2].trim() } : { name: 'Poker klub Triling', email: from };
      const res = await fetch('https://api.brevo.com/v3/smtp/email', {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json', 'api-key': process.env.BREVO_API_KEY },
        body: JSON.stringify({ sender, to: [{ email: to }], subject, textContent: text }),
        signal: AbortSignal.timeout(20_000),
      });
      if (!res.ok) throw new Error(`Brevo ${res.status}: ${(await res.text()).slice(0, 300)}`);
      log.log(`Poslat mejl (Brevo) na ${to}: ${subject}`);
      return true;
    }
    const host = process.env.SMTP_HOST;
    if (!host) {
      log.warn(`Slanje mejlova nije podešeno. Poruka za ${to}: ${subject}\n${text}`);
      return false;
    }
    const port = Number(process.env.SMTP_PORT || 465);
    const transport = nodemailer.createTransport({
      host,
      port,
      secure: port === 465,
      auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: (process.env.SMTP_PASS ?? '').replace(/\s+/g, '') } : undefined,
      connectionTimeout: 15_000,
      greetingTimeout: 15_000,
      socketTimeout: 20_000,
    });
    await transport.sendMail({ from, to, subject, text });
    log.log(`Poslat mejl (SMTP) na ${to}: ${subject}`);
    return true;
  } catch (e) {
    log.error(`Mejl na ${to} nije poslat: ${(e as Error).message}`);
    throw e;
  }
}

export const mailReady = () => !!(process.env.BREVO_API_KEY || process.env.SMTP_HOST);

/** Kako je slanje podešeno (bez tajnih podataka), za admin panel. */
export const mailConfig = () => ({
  method: process.env.BREVO_API_KEY ? 'Brevo' : process.env.SMTP_HOST ? 'SMTP' : null,
  host: process.env.SMTP_HOST ?? null,
  port: process.env.SMTP_PORT ?? null,
  user: process.env.SMTP_USER ?? null,
  from: process.env.MAIL_FROM ?? null,
  passSet: !!process.env.SMTP_PASS,
});
