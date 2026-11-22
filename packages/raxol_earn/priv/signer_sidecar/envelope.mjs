// Mutual authentication with the BEAM. The Elixir side, and the protocol
// spec, is Raxol.Earn.SignerSidecar.Envelope; the two must compute the same
// bytes, and signer_sidecar_envelope_test.exs checks that they do.
// node:crypto only, so it loads without the SDK installed.

import { createHash, createHmac, timingSafeEqual } from "node:crypto";

const CONTEXT = "raxol-earn-sidecar/v1";

// A request whose timestamp is further than this from now is refused.
export const MAX_SKEW_MS = 30_000;

export function deriveKey(signerPrivateKey) {
  return createHmac("sha256", signerPrivateKey.trim()).update(CONTEXT).digest();
}

const sha256 = (body) => createHash("sha256").update(body).digest("hex");
const hmacHex = (key, data) => createHmac("sha256", key).update(data).digest("hex");

export function requestSig(key, method, path, body, ts, nonce) {
  return hmacHex(key, ["req", method.toUpperCase(), path, ts, nonce, sha256(body)].join("\n"));
}

export function responseSig(key, reqSig, status, address, body) {
  return hmacHex(
    key,
    ["res", reqSig, String(status), address.toLowerCase(), sha256(body)].join("\n"),
  );
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}

// The checks that need no body, so an unauthenticated caller is turned away
// before anything is read. Returns null or a short reason.
export function precheck(headers, now) {
  const ts = headers["x-raxol-ts"];
  const nonce = headers["x-raxol-nonce"];
  const sig = headers["x-raxol-sig"];
  if (!ts || !nonce || !sig) return "missing_auth";
  if (!/^[0-9]{1,16}$/.test(ts) || !/^[0-9a-f]{32}$/.test(nonce) || !/^[0-9a-f]{64}$/.test(sig))
    return "malformed_auth";
  if (Math.abs(now - Number(ts)) > MAX_SKEW_MS) return "stale";
  return null;
}

// Returns null when the request is authentic, else a short reason. `seen` maps
// an accepted nonce to the first moment its timestamp is stale; the caller owns
// it and it is pruned here.
export function verifyRequest(key, { method, path, headers, body }, now, seen) {
  const early = precheck(headers, now);
  if (early) return early;

  const { "x-raxol-ts": ts, "x-raxol-nonce": nonce, "x-raxol-sig": sig } = headers;
  for (const [n, exp] of seen) if (exp <= now) seen.delete(n);
  if (seen.has(nonce)) return "replayed";
  if (!safeEqual(sig, requestSig(key, method, path, body, ts, nonce))) return "bad_signature";

  seen.set(nonce, Number(ts) + MAX_SKEW_MS + 1);
  return null;
}

const LOOPBACK = /^(localhost|127(\.\d{1,3}){3}|::1|\[::1\])$/i;

export function isLoopback(host) {
  return LOOPBACK.test(host);
}
