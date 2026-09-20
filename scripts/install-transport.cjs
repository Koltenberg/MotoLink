// Temporary, authenticated TCP transport. TLS terminates at the client and Apple.
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { WebSocketServer } = require('ws');
const allowed = new Set(['gsa.apple.com', 'gsas.apple.com', 'developerservices2.apple.com', 'developerservices.apple.com', 'idmsa.apple.com']);
const publicKey = fs.readFileSync(process.argv[2], 'utf8');
const used = new Set();
const httpServer = http.createServer((req, res) => { res.writeHead(404); res.end(); });
const wss = new WebSocketServer({ server: httpServer, path: '/apple-tls', maxPayload: 1024 * 1024, perMessageDeflate: false });
wss.on('connection', ws => {
  let socket;
  let verified = false;
  const authTimer = setTimeout(() => ws.close(1008), 5000);
  const end = () => { clearTimeout(authTimer); socket?.destroy(); ws.close(); };
  ws.on('error', end);
  ws.on('close', () => { clearTimeout(authTimer); socket?.destroy(); });
  ws.on('message', (data, binary) => {
    if (!verified) {
      try {
        if (binary || data.length > 2048) throw Error('Bad request');
        const { host, timestamp, nonce, signature } = JSON.parse(data.toString());
        if (!allowed.has(host) || !Number.isSafeInteger(timestamp) || Math.abs(Date.now() - timestamp) > 60000 || !/^[a-f0-9]{32}$/.test(nonce) || used.has(nonce)) throw Error('Denied');
        const payload = Buffer.from(`${host}\n${timestamp}\n${nonce}`);
        if (!crypto.verify(null, payload, publicKey, Buffer.from(signature, 'base64'))) throw Error('Denied');
        used.add(nonce);
        setTimeout(() => used.delete(nonce), 120000).unref();
        verified = true;
        clearTimeout(authTimer);
        socket = net.connect({ host, port: 443 }, () => ws.send('ready'));
        socket.setTimeout(120000, end);
        socket.on('data', chunk => { if (ws.bufferedAmount > 8 * 1024 * 1024) return end(); ws.send(chunk); });
        socket.on('end', end);
        socket.on('error', end);
      } catch { ws.close(1008, 'Denied'); }
    } else {
      if (!binary || !socket || socket.writableLength > 8 * 1024 * 1024) return end();
      socket.write(data);
    }
  });
});
httpServer.listen(18742, '127.0.0.1', () => console.log('Apple TLS transport listening'));
setTimeout(() => { for (const ws of wss.clients) ws.terminate(); httpServer.close(); process.exit(0); }, 20 * 60 * 1000);