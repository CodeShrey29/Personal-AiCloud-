"""
WSGI application that routes requests:
  /seafhttp/* -> Go fileserver on port 8082
  /*          -> Seahub Django app

This replaces nginx for Render's single-port deployment.
"""
import os
import sys
from urllib.parse import urljoin
from http.client import HTTPConnection

# Add seahub to path
SEAHUB_DIR = '/opt/seahub'
PYPACKAGES_DIR = '/opt/cloudai/pypackages'
if SEAHUB_DIR not in sys.path:
    sys.path.insert(0, SEAHUB_DIR)
if PYPACKAGES_DIR not in sys.path:
    sys.path.insert(0, PYPACKAGES_DIR)

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'seahub.settings')

# Import Django WSGI app lazily
_django_app = None

def get_django_app():
    global _django_app
    if _django_app is None:
        from seahub.wsgi import application
        _django_app = application
    return _django_app


FILESERVER_HOST = '127.0.0.1'
FILESERVER_PORT = 8082


def proxy_to_fileserver(environ, start_response):
    """Proxy request to Go fileserver, stripping /seafhttp prefix."""
    path = environ.get('PATH_INFO', '')
    # Strip /seafhttp prefix
    if path.startswith('/seafhttp'):
        path = path[len('/seafhttp'):]
    if not path:
        path = '/'

    query = environ.get('QUERY_STRING', '')
    url = path
    if query:
        url = f"{path}?{query}"

    method = environ.get('REQUEST_METHOD', 'GET')

    # Read request body
    content_length = environ.get('CONTENT_LENGTH', '')
    body = None
    if content_length:
        body = environ['wsgi.input'].read(int(content_length))

    # Build headers to forward
    headers = {}
    for key, value in environ.items():
        if key.startswith('HTTP_'):
            header_name = key[5:].replace('_', '-')
            headers[header_name] = value
    if content_length:
        headers['Content-Length'] = content_length
    content_type = environ.get('CONTENT_TYPE')
    if content_type:
        headers['Content-Type'] = content_type

    try:
        conn = HTTPConnection(FILESERVER_HOST, FILESERVER_PORT, timeout=1200)
        conn.request(method, url, body=body, headers=headers)
        resp = conn.getresponse()

        # Build response headers
        resp_headers = [(k, v) for k, v in resp.getheaders()
                        if k.lower() not in ('transfer-encoding',)]

        status = f"{resp.status} {resp.reason}"
        start_response(status, resp_headers)

        # Stream response body
        data = resp.read()
        conn.close()
        return [data]
    except Exception as e:
        start_response('502 Bad Gateway', [('Content-Type', 'text/plain')])
        return [f"Fileserver proxy error: {e}".encode()]


def application(environ, start_response):
    """Main WSGI entry point — routes between seahub and fileserver."""
    path = environ.get('PATH_INFO', '')

    if path.startswith('/seafhttp'):
        return proxy_to_fileserver(environ, start_response)
    else:
        return get_django_app()(environ, start_response)
