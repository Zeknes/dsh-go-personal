// The site (the home page at /, the landing page at /share/ and their files)
// is static: scripts/build-site.mjs puts it in public/ with the headers each
// file gets (public/_headers), and Cloudflare serves it without running the
// Worker (wrangler.jsonc assets). The Worker serves the conversation viewer
// at /c/<id> (public/c.html), and the 404 for any path with no file.


const COMMON: Record<string, string> = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Robots-Tag': 'noindex',
  'Strict-Transport-Security': 'max-age=31536000',
};

export function redirect(location: string, status = 302): Response {
  return new Response(null, { status, headers: { ...COMMON, Location: location, 'Cache-Control': 'no-store' } });
}

export function notFound(): Response {
  return new Response('Not found', {
    status: 404,
    headers: { ...COMMON, 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}
