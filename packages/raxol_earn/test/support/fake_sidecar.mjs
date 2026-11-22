// The real sidecar request handler (priv/signer_sidecar/app.mjs) over a
// stand-in adapter, for the Elixir suite. Prints {"port": N} once listening and
// exits when stdin closes. argv: <app.mjs path> <signer private key> <address>
import http from "node:http";

const [appPath, signerKey, address] = process.argv.slice(2);
const { createHandler } = await import(appPath);
const { deriveKey } = await import(new URL("envelope.mjs", appPath).href);

const sig = "0x" + "ab".repeat(65);
const adapter = {
  signMessage: async () => sig,
  signTypedData: async () => sig,
  sendTransaction: async (_chainId, calls) => calls.map((_c, i) => `0x${String(i).padStart(64, "f")}`),
  getTransactionReceipt: async () => ({ status: "success" }),
  readContract: async () => 1n,
  getLogs: async () => [],
};

const server = http.createServer(
  createHandler({ adapter, key: deriveKey(signerKey), address, chainIds: [8453] }),
);
server.listen(0, "127.0.0.1", () => console.log(JSON.stringify({ port: server.address().port })));
process.stdin.resume();
process.stdin.on("end", () => process.exit(0));
