// bun preload for the Discord channel plugin.
//
// bun's fetch honours HTTPS_PROXY, but its WebSocket does not, so behind a
// corporate proxy the Discord gateway connection alone goes direct and dies on
// the TLS interception. Pin both to the same proxy the shell already uses.
//
// Reads HTTPS_PROXY / https_proxy and does nothing when neither is set, so the
// same file is safe on a machine with no proxy. claude-discord wires it in
// through the plugin's bunfig.toml on every start, because a plugin update
// replaces that directory.
const proxy = process.env.HTTPS_PROXY ?? process.env.https_proxy

if (proxy) {
  const NativeWebSocket = globalThis.WebSocket
  globalThis.WebSocket = class extends NativeWebSocket {
    constructor(url: string | URL, protocols?: string | string[]) {
      super(url, { protocols: protocols ?? [], proxy } as any)
    }
  } as typeof WebSocket

  const nativeFetch = globalThis.fetch
  globalThis.fetch = ((input, init) => nativeFetch(input, { ...init, proxy } as any)) as typeof fetch
}
