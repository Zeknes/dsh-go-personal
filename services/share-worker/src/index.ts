// Plugin market and download routes.

import { json } from './api';
import type { Env } from './env';
import { beta, isBetaPath } from './beta';
export { BetaGuard } from './beta-guard';
import { accessMode, download, isDownloadPath } from './download';
export { StatsSalt } from './stats';
import { githubStars } from './github';
import { isMarketPath, market, publishMarket } from './market';
import type { Ctx } from './files';
import { notFound } from './site';

/** Paths of the retired public download mirror; 404 (/download is the
 *  public page once DOWNLOAD_ACCESS=public). */
const RETIRED = /^\/(?:update\.json|download(?:\/.*)?)$/;

async function route(request: Request, env: Env, ctx: Ctx): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (path.startsWith('/api/')) {
    if (path === '/api/github/stars') return githubStars(request, env, ctx);
    return json(404, { error: 'not_found' });
  }

  if (isMarketPath(path)) return market(request, env, ctx);
  if (isBetaPath(path)) return beta(request, env, ctx);
  if (isDownloadPath(path) && accessMode(env) === 'public') return download(request, env, ctx);
  if (RETIRED.test(path) || path.startsWith('/__edge/')) return notFound();
  if (method !== 'GET' && method !== 'HEAD') return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  // The site's files never get here (wrangler.jsonc assets): no such file, or a hidden one.
  return notFound();
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await route(request, env, ctx);
    } catch (e) {
      console.error('unhandled', e instanceof Error ? e.message : String(e));
      return json(500, { error: 'internal' });
    }
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await publishMarket(env);
  },
} satisfies ExportedHandler<Env>;
