/**
 * The client's network for the per-network limits (#123).
 *
 * TRUSTED_IP_HEADER names a header the ingress sets itself. On Supabase's
 * hosted platform that is `cf-connecting-ip`: Cloudflare, in front of every
 * project, overwrites it with the one address that connected to it, so a
 * client cannot forge it, and it never lists proxies. X-Forwarded-For is not
 * suitable: its first entries are whatever the client sent, and hops added
 * after Cloudflare would make every rider look like the same proxy.
 *
 * Only the last entry is read, so even a list-valued header yields the hop
 * the ingress added rather than a prefix the client wrote; anything that is
 * not an IP address is refused.
 */
export function trustedIp(req: Request, header: string): string | null {
  const ip = req.headers.get(header)?.split(',').at(-1)?.trim();
  return ip && /^[0-9a-f:.]+$/i.test(ip) ? ip : null;
}
