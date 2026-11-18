/** Adrese sa kojih aplikacija i admin panel smeju da šalju zahteve (null = sve, za lokalni rad). */
export function allowedOrigins(): string[] | null {
  const list = (process.env.ALLOWED_ORIGINS ?? '').split(',').map((x) => x.trim()).filter(Boolean);
  for (const d of [process.env.RAILWAY_PUBLIC_DOMAIN, process.env.PUBLIC_DOMAIN]) {
    if (d) list.push(`https://${d.replace(/^https?:\/\//, '')}`);
  }
  return list.length ? list : null;
}
