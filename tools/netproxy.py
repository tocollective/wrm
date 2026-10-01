#!/usr/bin/env python3
"""The network of the emulator's web build.

A page in a browser can't open TCP connections or look up host names, so
the web build (source/network_web.c) asks this proxy on the host:

  GET /resolve/NAME    the first IPv4 address of NAME as text, 404 if none
  GET /tcp/ADDR/PORT   a WebSocket whose binary messages are the bytes of
                       a TCP connection to ADDR:PORT; 502 if it can't open

One proxy reaches any address and port, for any page that asks, so it
listens on 127.0.0.1 unless told otherwise. Only the standard library.
"""

import argparse
import asyncio
import base64
import hashlib
import socket
import struct
import urllib.parse

WEBSOCKET_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CONTINUATION, TEXT, BINARY, CLOSE, PING, PONG = 0, 1, 2, 8, 9, 10
FRAME_MAX = 1 << 24  # a larger frame from the page drops the connection
CONNECT_TIMEOUT = 10  # seconds


def log(message):
	print(f"netproxy: {message}", flush=True)


async def respond(writer, status, body=b"", headers=()):
	# any page may ask (the emulator's is often on another port), and
	# Chrome asks before a public page reaches localhost
	head = [f"HTTP/1.1 {status}",
			"Access-Control-Allow-Origin: *",
			"Access-Control-Allow-Private-Network: true",
			f"Content-Length: {len(body)}",
			"Connection: close", *headers]
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


async def resolve(writer, name):
	try:
		found = await asyncio.get_running_loop().getaddrinfo(
			name, None, family=socket.AF_INET, type=socket.SOCK_STREAM)
		addr = found[0][4][0]
	except (OSError, IndexError):
		log(f"resolve {name}: not found")
		await respond(writer, "404 Not Found")
		return
	log(f"resolve {name}: {addr}")
	await respond(writer, "200 OK", addr.encode(),
				  ["Content-Type: text/plain"])


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


async def handle(reader, writer):
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

		if method == "OPTIONS":
			await respond(writer, "204 No Content",
						  headers=["Access-Control-Allow-Methods: GET"])
		elif method == "GET" and len(path) == 2 and path[0] == "resolve":
			await resolve(writer, path[1])
		elif (method == "GET" and len(path) == 3 and path[0] == "tcp"
			  and "sec-websocket-key" in headers
			  and path[2].isdigit() and 0 < int(path[2]) < 1 << 16):
			await tunnel(reader, writer, headers["sec-websocket-key"],
						 path[1], int(path[2]))
		else:
			await respond(writer, "404 Not Found")
	except (OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError,
			asyncio.TimeoutError):
		pass
	finally:
		writer.close()


def main():
	parser = argparse.ArgumentParser(
		description="WebSocket-to-TCP and DNS proxy for the emulator's web build")
	parser.add_argument("--listen", default="127.0.0.1", metavar="ADDR",
						help="address to listen on (default: 127.0.0.1)")
	parser.add_argument("--port", type=int, default=8080,
						help="port to listen on (default: 8080)")
	args = parser.parse_args()

	async def serve():
		server = await asyncio.start_server(handle, args.listen, args.port)
		log(f"listening on {args.listen}:{args.port}")
		async with server:
			await server.serve_forever()

	try:
		asyncio.run(serve())
	except KeyboardInterrupt:
		pass


if __name__ == "__main__":
	main()
