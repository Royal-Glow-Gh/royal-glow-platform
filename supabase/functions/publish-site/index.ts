// Royal Glow — "Publish website now" (Supabase Edge Function: publish-site)
// Called by the staff app's Website page. Checks the caller is admin or Blog staff, then asks
// GitHub to run the "Publish main website" workflow, which rebuilds royalglowgh.com in about a minute.
// The GitHub key lives only in this function's secrets (GITHUB_TOKEN), never in a web page.
// Deploy: Supabase -> Edge Functions -> Deploy a new function -> Via editor -> name "publish-site" -> paste -> Deploy.
// Secret: Edge Functions -> Secrets -> GITHUB_TOKEN = a fine-grained GitHub token for
//         Royal-Glow-Gh/royal-glow-platform with "Actions: Read and write".
import { createClient } from 'npm:@supabase/supabase-js@2';

const REPO = Deno.env.get('GITHUB_REPO') ?? 'Royal-Glow-Gh/royal-glow-platform';
const WORKFLOW = 'publish-site.yml';
const COOLDOWN_MS = 60_000;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { message: 'Use POST.' });

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const token = Deno.env.get('GITHUB_TOKEN');

  // 1. Who is asking? Use their own sign-in, so the database's role rules decide.
  const asCaller = createClient(url, anon, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: { user } } = await asCaller.auth.getUser();
  if (!user) return json(401, { message: 'Please sign in again.' });
  const { data: allowed, error: roleErr } = await asCaller.rpc('is_staff', { roles: ['admin', 'content'] });
  if (roleErr || !allowed) return json(403, { message: 'Your role is not allowed to publish the website.' });

  // 2. One publish a minute is plenty (the build takes about that long).
  const db = createClient(url, service);
  const { data: last } = await db.from('site_publish_log').select('requested_at').eq('ok', true)
    .order('requested_at', { ascending: false }).limit(1);
  if (last?.length && Date.now() - Date.parse(last[0].requested_at) < COOLDOWN_MS) {
    return json(429, { message: 'The website was published less than a minute ago and is still updating. Try again shortly.' });
  }
  if (!token) return json(500, { message: 'The GITHUB_TOKEN secret is not set for the publish-site function.' });

  // 3. Ask GitHub to run the website workflow on the main branch.
  const r = await fetch(`https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'royal-glow-publish-site',
    },
    body: JSON.stringify({ ref: 'main' }),
  });
  const ok = r.status === 204;
  const detail = ok ? null : `GitHub ${r.status}: ${(await r.text()).slice(0, 300)}`;
  await db.from('site_publish_log').insert({ requested_by: user.id, ok, message: detail });
  if (!ok) {
    const hint = r.status === 401 ? ' The GitHub token is wrong or has expired.' : r.status === 403 || r.status === 404 ? ' The GitHub token needs access to the repository with "Actions: Read and write".' : '';
    return json(502, { message: `GitHub did not accept the request (${r.status}).${hint}` });
  }
  return json(200, { message: 'Rebuild started. The website updates in about a minute.' });
});
