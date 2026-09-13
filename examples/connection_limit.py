#!/usr/bin/env python3
"""An interactive companion to docs/CONNECTION-LIMIT-WALKTHROUGH.md."""
import argparse
import http.client
import sys
import time


# An accepted socket can be closed before or during the first HTTP exchange.
# A timeout or a failed TCP connect is not evidence of admission refusal.
CLOSED = (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError,
          ConnectionAbortedError)


def hello(connection, name):
    original_socket = connection.sock
    if original_socket is None:
        raise RuntimeError("A held connection has closed. Restart the walkthrough.")
    connection.request("GET", "/hello?name=client-" + name)
    response = connection.getresponse()
    body = response.read(1024)
    if response.status != 200 or body != ("client-" + name).encode():
        raise RuntimeError("Expected the Baz App demo's /hello response. Check the server command.")
    if response.will_close or connection.sock is not original_socket:
        raise RuntimeError("The server did not retain this keep-alive connection.")
    return "HTTP 200 - " + body.decode("ascii")


def connect(port, name, timeout=2.0):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        try:
            connection.connect()
        except OSError as error:
            raise RuntimeError("TCP connection failed before the HTTP exchange: " + str(error)) from error
        message = hello(connection, name)
        return connection, message
    except BaseException:
        connection.close()
        raise


def pause(number, instruction):
    print("\n" + str(number) + ". " + instruction, flush=True)
    input("Press Enter to do this, or Ctrl-C to stop: ")


def walkthrough(port):
    held = {}
    print("Two slots. Three clients.")
    print("Keep the Baz server running in your other terminal.")
    print("This client uses real HTTP/1.1 connections to 127.0.0.1:" + str(port))
    print("Complete each step within five minutes so idle connections stay open.")
    try:
        pause(1, "Open connection A and leave it connected.")
        held["A"], message = connect(port, "A")
        print("A: " + message + "; held open.\nHeld by this walkthrough: A (1 of 2 slots).")

        pause(2, "Open connection B. Both slots will be occupied.")
        hello(held["A"], "A")
        held["B"], message = connect(port, "B")
        print("B: " + message + "; held open.\nHeld by this walkthrough: A, B (2 of 2 slots).")

        pause(3, "Try connection C while A and B are still open.")
        hello(held["A"], "A")
        hello(held["B"], "B")
        try:
            extra, _ = connect(port, "C")
        except CLOSED:
            # Confirm refusal was not caused by a server exit or expired holders.
            hello(held["A"], "A")
            hello(held["B"], "B")
            print("C: closed by the server without an HTTP response.")
            print("A and B still answer on their original connections. Both slots remain occupied.")
        else:
            extra.close()
            raise RuntimeError("C was admitted. Start the server with --connections 2, then restart this client.")

        pause(4, "Close A to release one slot.")
        hello(held["B"], "B")
        held.pop("A").close()
        print("A: closed. Baz can reclaim its slot after connection cleanup.")
        print("Held by this walkthrough: B (1 of 2 slots).")

        pause(5, "Try C again. B stays connected.")
        hello(held["B"], "B")
        deadline = time.monotonic() + 2.0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("The released slot was not reusable within two seconds.")
            try:
                held["C"], message = connect(port, "C", timeout=min(1.0, remaining))
                break
            except CLOSED:
                # Closing the client socket does not synchronously finish the
                # server's application and kernel ownership cleanup.
                time.sleep(min(0.02, max(0.0, deadline - time.monotonic())))
        hello(held["B"], "B")
        print("C: " + message + "; admitted after A released a slot.")
        print("B still answers on its original connection.")
        print("\nYou filled the limit, observed refusal, and reused the released capacity.")
    finally:
        for connection in held.values():
            connection.close()
        print("\nWalkthrough connections closed. Stop the server with Ctrl-C in its terminal.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8080, help="Baz App demo port (default: 8080)")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    try:
        walkthrough(args.port)
    except (KeyboardInterrupt, EOFError):
        print("\nWalkthrough stopped.")
        return 130
    except (OSError, http.client.HTTPException, RuntimeError) as error:
        print("\nCould not complete the walkthrough: " + str(error), file=sys.stderr)
        print("Check that the documented server is running with two slots and a five-minute timeout.", file=sys.stderr)
        print("If a step was left idle too long, restart this client. See the guide's troubleshooting section.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
