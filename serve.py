import http.server, socketserver
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('X-Frame-Options', 'ALLOWALL')
        self.send_header('Content-Security-Policy', 'frame-ancestors *')
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        super().end_headers()
    def do_OPTIONS(self):
        self.send_response(200); self.end_headers()
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('0.0.0.0', 5060), H) as httpd: httpd.serve_forever()
