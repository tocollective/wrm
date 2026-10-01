#!/usr/bin/env python3
"""The network of the emulator's web build.

A page in a browser can't open TCP connections or look up host names, so
the web build (source/network_web.c) asks this proxy on the host:

  GET /TOKEN/resolve/NAME    the first IPv4 address of NAME as text, 404
                             if none
  GET /TOKEN/tcp/ADDR/PORT   a WebSocket whose binary messages are the
                             bytes of a TCP connection to ADDR:PORT (an
                             IPv4 address); 502 if it can't open

Any page open in the browser can reach the proxy, so it only serves:

- requests with the TOKEN it prints at start, a random one unless
  --token sets it (--no-token drops it from the paths);
- pages from localhost and 127.0.0.1, on any port, and the origins
  --origin adds; a request without an Origin header is not from a page;
- public addresses: loopback, private, link-local, multicast and other
  special ranges are refused (403) unless --allow lets them in.

It listens on 127.0.0.1 unless told otherwise. Only the standard library.
"""

import argparse
import asyncio
import base64
import hashlib
import hmac
import ipaddress
import secrets
import socket
import struct
import urllib.parse

WEBSOCKET_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CONTINUATION, TEXT, BINARY, CLOSE, PING, PONG = 0, 1, 2, 8, 9, 10
FRAME_MAX = 1 << 24  # a larger frame from the page drops the connection
CONNECT_TIMEOUT = 10  # seconds
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")  # pages always allowed


class Policy:
	"""Who may use the proxy and where to."""

	def __init__(self, token, origins, allow):
		self.token = token  # None: no token in the paths
		self.origins = set(origins)  # "*" allows any page
		self.allow = allow  # networks reachable despite not being public

	def origin_allowed(self, origin):
		if origin is None or "*" in self.origins or origin in self.origins:
			return True
		parts = urllib.parse.urlsplit(origin)
		return (parts.scheme in ("http", "https")
				and parts.hostname in LOCAL_HOSTS)

	def token_matches(self, path):
		"""path without the token, None if the token is wrong."""
		if self.token is None:
			return path
		if not path or not hmac.compare_digest(path[0], self.token):
			return None
		return path[1:]

	def address_allowed(self, addr):
		if any(addr in net for net in self.allow):
			return True
		return addr.is_global and not addr.is_multicast


def log(message):
	print(f"netproxy: {message}", flush=True)


async def respond(writer, status, body=b"", headers=(), origin=None):
	# an allowed page is often on another port, and Chrome asks before a
	# public page reaches localhost
	head = [f"HTTP/1.1 {status}", "Vary: Origin"]
	if origin is not None:
		head += [f"Access-Control-Allow-Origin: {origin}",
				 "Access-Control-Allow-Private-Network: true"]
	head += [f"Content-Length: {len(body)}", "Connection: close", *headers]
	writer.write(("\r\n".join(head) + "\r\n\r\n").encode() + body)
	await writer.drain()


def frame(opcode, payload=b""):
	"""A WebSocket frame from the server: final, unmasked."""
	length = len(payload)
	if length < 126:
		header = struct.pack("!BB", 0x80 | opcode, length)
	elif length < 1 << 16:
		header = struct.pack("!BBH", 0x80 | opcode, 126, length)
	else:
		header = struct.pack("!BBQ", 0x80 | opcode, 127, length)
	return header + payload


async def read_frame(reader):
	"""The next frame from the page as (opcode, payload), unmasked."""
	first, second = await reader.readexactly(2)
	length = second & 0x7F
	if length == 126:
		(length,) = struct.unpack("!H", await reader.readexactly(2))
	elif length == 127:
		(length,) = struct.unpack("!Q", await reader.readexactly(8))
	if length > FRAME_MAX:
		raise ConnectionError("frame too large")
	mask = await reader.readexactly(4) if second & 0x80 else None
	payload = await reader.readexactly(length)
	if mask and length:
		key = (mask * (length // 4 + 1))[:length]
		payload = (int.from_bytes(payload, "big")
				   ^ int.from_bytes(key, "big")).to_bytes(length, "big")
	return first & 0x0F, payload


async def resolve(writer, name, origin):
	try:
		found = await asyncio.get_running_loop().getaddrinfo(
			name, None, family=socket.AF_INET, type=socket.SOCK_STREAM)
		addr = found[0][4][0]
	except (OSError, IndexError, UnicodeError):
		log(f"resolve {name}: not found")
		await respond(writer, "404 Not Found", origin=origin)
		return
	# the address may still be refused when the page connects to it
	log(f"resolve {name}: {addr}")
	await respond(writer, "200 OK", addr.encode(),
				  ["Content-Type: text/plain"], origin)


async def tunnel(page_reader, page_writer, key, addr, port):
	target = f"{addr}:{port}"
	try:
		reader, writer = await asyncio.wait_for(
			asyncio.open_connection(addr, port), CONNECT_TIMEOUT)
	except (OSError, asyncio.TimeoutError) as e:
		log(f"tcp {target}: can't connect ({e or 'timeout'})")
		await respond(page_writer, "502 Bad Gateway")
		return

	accept = base64.b64encode(
		hashlib.sha1(key.encode() + WEBSOCKET_GUID).digest()).decode()
	page_writer.write(("HTTP/1.1 101 Switching Protocols\r\n"
					   "Upgrade: websocket\r\n"
					   "Connection: Upgrade\r\n"
					   f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
	await page_writer.drain()
	log(f"tcp {target}: connected")

	async def from_page():
		while True:
			opcode, payload = await read_frame(page_reader)
			if opcode in (CONTINUATION, TEXT, BINARY):
				writer.write(payload)
				await writer.drain()
			elif opcode == PING:
				page_writer.write(frame(PONG, payload))
			elif opcode == CLOSE:
				return

	async def to_page():
		while data := await reader.read(65536):
			page_writer.write(frame(BINARY, data))
			await page_writer.drain()

	page = asyncio.create_task(from_page())
	server = asyncio.create_task(to_page())
	done, _ = await asyncio.wait({page, server},
								 return_when=asyncio.FIRST_COMPLETED)
	if server in done:
		# the other end is done: a clean close, so the page reads it as the
		# end of the stream; the page's own close ends the handshake
		try:
			page_writer.write(frame(CLOSE, struct.pack("!H", 1000)))
			await page_writer.drain()
			await asyncio.wait_for(asyncio.shield(page), 2)
		except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError):
			pass
	for task in (page, server):
		task.cancel()
		try:
			await task
		except (asyncio.CancelledError, OSError, asyncio.IncompleteReadError):
			pass
	writer.close()
	log(f"tcp {target}: closed")


def parse_address(text):
	"""The IPv4 address in text, None if it isn't one."""
	try:
		return ipaddress.IPv4Address(text)
	except ValueError:
		return None


async def handle(policy, reader, writer):
	try:
		head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
		request, *lines = head.decode("latin-1").split("\r\n")
		headers = {}
		for line in lines:
			name, _, value = line.partition(":")
			headers[name.strip().lower()] = value.strip()
		method, target = (request.split(" ") + ["", ""])[:2]
		path = [urllib.parse.unquote(part) for part in
				urllib.parse.urlsplit(target).path.split("/")[1:]]

		# WebSockets aren't covered by CORS, so the proxy checks the page
		# itself; a wrong token looks like a missing path
		origin = headers.get("origin")
		if not policy.origin_allowed(origin):
			log(f"refused a request from {origin}")
			await respond(writer, "403 Forbidden")
			return
		path = policy.token_matches(path)
		if method == "OPTIONS":
			await respond(writer, "204 No Content",
						  ["Access-Control-Allow-Methods: GET"], origin)
		elif path is None:
			await respond(writer, "404 Not Found", origin=origin)
		elif method == "GET" and len(path) == 2 and path[0] == "resolve":
			await resolve(writer, path[1], origin)
		elif (method == "GET" and len(path) == 3 and path[0] == "tcp"
			  and "sec-websocket-key" in headers
			  and parse_address(path[1]) is not None
			  and path[2].isdigit() and 0 < int(path[2]) < 1 << 16):
			if not policy.address_allowed(parse_address(path[1])):
				log(f"tcp {path[1]}:{path[2]}: refused, not a public "
					"address (see --allow)")
				await respond(writer, "403 Forbidden", origin=origin)
				return
			await tunnel(reader, writer, headers["sec-websocket-key"],
						 path[1], int(path[2]))
		else:
			await respond(writer, "404 Not Found", origin=origin)
	except (OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError,
			asyncio.TimeoutError):
		pass
	finally:
		writer.close()


def network(text):
	try:
		return ipaddress.IPv4Network(text, strict=False)
	except ValueError as e:
		raise argparse.ArgumentTypeError(str(e))


def main():
	parser = argparse.ArgumentParser(
		description="WebSocket-to-TCP and DNS proxy for the emulator's web build")
	parser.add_argument("--listen", default="127.0.0.1", metavar="ADDR",
						help="address to listen on (default: 127.0.0.1)")
	parser.add_argument("--port", type=int, default=8080,
						help="port to listen on (default: 8080)")
	parser.add_argument("--token",
						help="the token pages pass in the path (default: "
							 "a random one)")
	parser.add_argument("--no-token", action="store_true",
						help="serve without a token in the paths")
	parser.add_argument("--origin", action="append", default=[],
						metavar="ORIGIN",
						help="also serve pages from ORIGIN, e.g. "
							 "https://example.com, or '*' for any page "
							 "(pages from localhost and 127.0.0.1 always are)")
	parser.add_argument("--allow", action="append", default=[], type=network,
						metavar="CIDR",
						help="also connect to this network although it isn't "
							 "public, e.g. 127.0.0.1/32 or 192.168.1.0/24")
	args = parser.parse_args()
	if args.no_token and args.token:
		parser.error("--token and --no-token can't be used together")
	token = None if args.no_token else args.token or secrets.token_urlsafe(16)
	policy = Policy(token, args.origin, args.allow)

	async def serve():
		server = await asyncio.start_server(
			lambda reader, writer: handle(policy, reader, writer),
			args.listen, args.port)
		log(f"listening on {args.listen}:{args.port}")
		host = args.listen if args.listen not in ("0.0.0.0", "") else "HOST"
		proxy = f"{host}:{args.port}" + (f"/{token}" if token else "")
		log(f"open the emulator's page with ?netproxy={proxy}")
		for net in args.allow:
			log(f"allowed: {net}")
		async with server:
			await server.serve_forever()

	try:
		asyncio.run(serve())
	except KeyboardInterrupt:
		pass


if __name__ == "__main__":
	main()
