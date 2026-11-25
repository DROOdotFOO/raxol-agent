// Request handling for the signing sidecar, independent of the SDK: server.mjs
// passes in the real adapter; tests pass a stand-in. Every request is
// authenticated before its body is read in full, and only responses to
// authenticated requests are signed (envelope.mjs).

import { precheck, responseSig, verifyRequest } from "./envelope.mjs";

// Requests are small (typed data, a batch of calls); cap what an
// unauthenticated or runaway caller can make this process hold.
export const MAX_BODY_BYTES = 1_000_000;

// JSON.stringify cannot serialize BigInt; render as decimal string. Used for
// receipts/logs/read results that viem returns with bigint fields.
function jsonSafe(_key, value) {
  return typeof value === "bigint" ? value.toString() : value;
}

// Convert an incoming call's value (decimal string, 0x-hex, or number) to BigInt.
function toBigIntValue(v) {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "bigint") return v;
  if (typeof v === "number") return BigInt(v);
  if (typeof v === "string") return v.startsWith("0x") ? BigInt(v) : BigInt(v);
  throw new Error(`unparseable call value: ${JSON.stringify(v)}`);
}

// viem TypedDataDefinition needs a primaryType. The Elixir side may omit it; infer
// it as the single non-EIP712Domain entry in `types`.
function withPrimaryType(typedData) {
  if (typedData.primaryType) return typedData;
  const keys = Object.keys(typedData.types || {}).filter(
    (k) => k !== "EIP712Domain",
  );
  if (keys.length !== 1) {
    throw new Error(
      `cannot infer primaryType from types keys: ${JSON.stringify(keys)}`,
    );
  }
  return { ...typedData, primaryType: keys[0] };
}

// The raw bytes, because the request signature covers exactly what was sent.
function readRaw(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("body too large"));
        req.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function parseJson(raw) {
  if (raw === "") return {};
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`invalid JSON body: ${e.message}`);
  }
}

// `ctx` carries the MAC key, this sidecar's wallet and the authenticated
// request's signature, so the BEAM can check the response answers its own
// request and came from the sidecar it meant to reach.
function send(res, ctx, status, obj) {
  const payload = JSON.stringify(obj, jsonSafe);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
    "x-raxol-sig": responseSig(ctx.key, ctx.reqSig, status, ctx.address, payload),
  });
  res.end(payload);
}

// Unsigned on purpose: signing a refusal for a caller without the key would
// hand it a valid response for any request signature it names.
function refuse(res, reason) {
  const payload = JSON.stringify({ error: "unauthorized", reason });
  res.writeHead(401, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
    connection: "close",
  });
  res.end(payload);
}

// Map an adapter error onto a structured HTTP response. The SDK throws
// ApprovalRequiredError when a Privy wallet policy needs dashboard approval.
function errorResponse(res, ctx, err) {
  const name = err?.name || "";
  const msg = err?.shortMessage || err?.message || String(err);
  if (name === "ApprovalRequiredError" || err?.approvalId) {
    return send(res, ctx, 409, {
      error: "approval_required",
      approvalId: err.approvalId,
      approvalUrl: err.approvalUrl,
      detail: err.detail || msg,
    });
  }
  console.error(`[signer] error: ${msg}`);
  return send(res, ctx, 500, { error: "signer_error", detail: msg });
}

export function createHandler({ adapter, key, address, chainIds }) {
  const seen = new Map();

  const routes = {
    "GET /health": async () => ({ ok: true, address, chainIds }),
    "GET /address": async () => ({ address }),
    "GET /chains": async () => ({ chainIds }),
    "POST /sign-message": async (b) => ({
      signature: await adapter.signMessage(b.chainId, b.message),
    }),
    "POST /sign-typed-data": async (b) => ({
      signature: await adapter.signTypedData(
        b.chainId,
        withPrimaryType(b.typedData),
      ),
    }),
    "POST /send-calls": async (b) => {
      const calls = (b.calls || []).map((c) => {
        const value = toBigIntValue(c.value);
        return {
          to: c.to,
          data: c.data ?? "0x",
          ...(value !== undefined ? { value } : {}),
        };
      });
      const result = await adapter.sendTransaction(b.chainId, calls);
      const txHashes = Array.isArray(result) ? result : [result];
      return { txHashes };
    },
    "POST /receipt": async (b) => ({
      receipt: await adapter.getTransactionReceipt(b.chainId, b.hash),
    }),
    "POST /read": async (b) => ({
      result: await adapter.readContract(b.chainId, {
        address: b.address,
        abi: b.abi,
        functionName: b.functionName,
        args: b.args ?? [],
      }),
    }),
    "POST /logs": async (b) => {
      const { chainId, ...filter } = b;
      return { logs: await adapter.getLogs(chainId, filter) };
    },
  };


  return async (req, res) => {
    const path = req.url.split("?")[0];
    const early = precheck(req.headers, Date.now());
    if (early) return refuse(res, early);

    let raw;
    try {
      raw = await readRaw(req);
    } catch (err) {
      return refuse(res, "body_too_large");
    }

    const denied = verifyRequest(
      key,
      { method: req.method, path, headers: req.headers, body: raw },
      Date.now(),
      seen,
    );
    if (denied) return refuse(res, denied);

    const ctx = { key, address, reqSig: req.headers["x-raxol-sig"] };
    try {
      const handler = routes[`${req.method} ${path}`];
      if (!handler) return send(res, ctx, 404, { error: "not_found", route: path });
      send(res, ctx, 200, await handler(parseJson(raw)));
    } catch (err) {
      errorResponse(res, ctx, err);
    }
  };
}
