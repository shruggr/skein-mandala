// The free `Buffer` global skein's client code uses (src/client/raw.ts), as
// skein-site's build injects it: skein's own shim (web/shims/buffer.ts).
// Imported first by each page, before the client is called.
import { Buffer } from "skein/web/shims/buffer.ts";

(globalThis as { Buffer?: unknown }).Buffer ??= Buffer;
