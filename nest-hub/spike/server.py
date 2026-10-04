"""Spike server: serves index.html and logs /ping heartbeats from the Nest Hub."""
import datetime, http.server, sys, urllib.parse

class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/touch') or self.path.startswith('/audio'):
            print(datetime.datetime.now().strftime('%H:%M:%S'), 'TOUCH', self.path, flush=True)
            self.send_response(204); self.end_headers(); return
        if self.path.startswith('/ping'):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            print(datetime.datetime.now().strftime('%H:%M:%S'), 'PING', self.client_address[0],
                  'up=' + q.get('up', ['?'])[0], q.get('info', [''])[0] if q.get('up') == ['0'] else '', flush=True)
            self.send_response(204); self.end_headers(); return
        print(datetime.datetime.now().strftime('%H:%M:%S'), 'GET', self.client_address[0], self.path, flush=True)
        super().do_GET()
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(('0.0.0.0', int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
