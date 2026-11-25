// raxol-earn signing sidecar.
//
// Wraps @virtuals-protocol/acp-node-v2's PrivyAlchemyEvmProviderAdapter and exposes
// the ProviderAdapter primitives over a localhost-only HTTP API, so the Elixir
// raxol_earn release can sign auth + settle ACP jobs AS a Virtuals-managed (Privy +
// Alchemy ERC-4337 / EIP-7702) agent wallet -- without holding any raw key. The
// P-256 authorization key lives ONLY in this process's env.
//
// Security posture: binds loopback only unless RAXOL_ACP_SIDECAR_ALLOW_REMOTE=1,
// and terminates when its parent (the BEAM) closes stdin -- so its lifetime is
// bound to the release. Requests and responses are authenticated with a key
// derived from the authorization key (envelope.mjs, app.mjs), so a process
// without that key can neither use this sidecar nor answer in its place.
//
// Endpoints (all JSON):
//   GET  /health          -> { ok, address, chainIds }
//   GET  /address         -> { address }
//   GET  /chains          -> { chainIds }
//   POST /sign-message    { chainId, message }            -> { signature }
//   POST /sign-typed-data { chainId, typedData }          -> { signature }
//   POST /send-calls      { chainId, calls:[{to,data,value?}] } -> { txHashes }
//   POST /receipt         { chainId, hash }               -> { receipt }
//   POST /read            { chainId, address, abi, functionName, args } -> { result }
//   POST /logs            { chainId, ...filter }          -> { logs }

import http from "node:http";
import { base } from "@account-kit/infra";
import { PrivyAlchemyEvmProviderAdapter } from "@virtuals-protocol/acp-node-v2";
import { createHandler } from "./app.mjs";
import { deriveKey, isLoopback } from "./envelope.mjs";

const HOST = process.env.RAXOL_ACP_SIGNER_HOST || "127.0.0.1";
const PORT = Number(process.env.RAXOL_ACP_SIGNER_PORT || "4048");

if (!isLoopback(HOST) && process.env.RAXOL_ACP_SIDECAR_ALLOW_REMOTE !== "1") {
  console.error(
    `[signer] refusing to bind non-loopback host ${HOST}; set RAXOL_ACP_SIDECAR_ALLOW_REMOTE=1 to allow it`,
  );
  process.exit(1);
}

function requireEnv(name) {
  const v = process.env[name];
  if (!v || v.trim() === "") {
    console.error(`[signer] missing required env ${name}`);
    process.exit(1);
  }
  return v;
}

// Only Base mainnet is wired -- the storefront authenticates and settles on Base.
// serverUrl / privyAppId default to the SDK's prod constants; override via env to
// point at a different ACP environment.
const CHAINS = [base];

async function main() {
  const signerPrivateKey = requireEnv("RAXOL_ACP_SIGNER_PRIVATE_KEY");
  const key = deriveKey(signerPrivateKey);

  const adapter = await PrivyAlchemyEvmProviderAdapter.create({
    walletAddress: requireEnv("RAXOL_ACP_WALLET_ADDRESS"),
    walletId: requireEnv("RAXOL_ACP_WALLET_ID"),
    signerPrivateKey,
    chains: CHAINS,
    ...(process.env.RAXOL_ACP_SERVER_URL
      ? { serverUrl: process.env.RAXOL_ACP_SERVER_URL }
      : {}),
    ...(process.env.PRIVY_APP_ID ? { privyAppId: process.env.PRIVY_APP_ID } : {}),
  });

  const address = await adapter.getAddress();
  const chainIds = await adapter.getSupportedChainIds();
  console.log(`[signer] ready: wallet ${address} chains ${chainIds.join(",")}`);

  const server = http.createServer(createHandler({ adapter, key, address, chainIds }));
  server.headersTimeout = 10_000;
  server.requestTimeout = 30_000;
  server.maxConnections = 64;

  // An emitter error (EADDRINUSE, above all) is not reachable by main().catch, so
  // without this the process would fault opaquely and leave whatever already holds
  // the port answering /health in its place.
  server.on("error", (err) => {
    console.error(`[signer] cannot listen on ${HOST}:${PORT}: ${err.message}`);
    process.exit(1);
  });

  server.listen(PORT, HOST, () => {
    console.log(`[signer] listening on http://${HOST}:${PORT}`);
  });

  // Die with the parent: when the BEAM closes the port, stdin emits 'end'.
  process.stdin.resume();
  process.stdin.on("end", () => {
    console.log("[signer] parent closed stdin -- exiting");
    process.exit(0);
  });
  process.stdin.on("close", () => process.exit(0));
}

main().catch((e) => {
  console.error(`[signer] fatal: ${e?.stack || e}`);
  process.exit(1);
});
