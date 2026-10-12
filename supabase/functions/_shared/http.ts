export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
export const response = (data: unknown, status = 200) =>
  Response.json(data, { status, headers: cors });
export async function readBody(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > 8192) throw new Error('request too large');
  const value = JSON.parse(text);
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    throw new Error('invalid body');
  }
  return value;
}
