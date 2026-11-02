export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-firebase-appcheck',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
export const response = (data: unknown, status = 200) =>
  Response.json(data, { status, headers: cors });
/**
 * The JSON object of a request, at most maxLength UTF-16 code units (8192 by
 * default; forms with long text pass more, #295).
 */
export async function readBody(
  req: Request,
  maxLength = 8192,
): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > maxLength) throw new Error('request too large');
  const value = JSON.parse(text);
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    throw new Error('invalid body');
  }
  return value;
}
