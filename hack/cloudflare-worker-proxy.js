/**
 * Cloudflare Worker which rewrites queries to media.n8r.ch to the underlying s3 bucket.
 */

export default {
    async fetch(request) {
      const ORIGINS = {
        "media-n8r-ch.clement-nuss.workers.dev": "sos-ch-gva-2.exo.io",
        "media.n8r.ch": "sos-ch-gva-2.exo.io",
      };

      const url = new URL(request.url);

      // Check if incoming hostname is a key in the ORIGINS object
      if (url.pathname.length > 1 && url.hostname in ORIGINS) {
        const target = ORIGINS[url.hostname];
        url.hostname = target;
        url.pathname = '/media-n8r-ch' + url.pathname;
        // If it is, proxy request to that third party origin
        return fetch(url.toString(), request);
      }

      const html = `<!DOCTYPE html>
      <body>
        <h2>Nothing to be seen around here</h2>
        <cite>replied the gentle Cloudflare Worker.</cite>
      </body>`;

      return new Response(html, {
        headers: {
          "content-type": "text/html;charset=UTF-8",
        },
      });
    },
  };
