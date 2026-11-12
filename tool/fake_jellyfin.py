"""Minimal stand-in for a Jellyfin server, to exercise the app's playback path."""
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

MEDIA = os.path.join(os.path.dirname(__file__), 'media')  # see make_test_media.sh
LOG = open(os.path.join(os.path.dirname(__file__), 'server.log'), 'w')
T = 10_000_000
STATE = {'pos': 20 * T}


def ep(i):
    return {
        'Id': f'e{i}', 'Type': 'Episode', 'Name': f'Episode {i}', 'SeriesId': 's1',
        'SeriesName': 'Test Show', 'SeasonId': 'se1', 'SeasonName': 'Season 1',
        'IndexNumber': i, 'ParentIndexNumber': 1, 'RunTimeTicks': 60 * T,
        'UserData': {'PlaybackPositionTicks': STATE['pos'] if i == 1 else 0, 'Played': False},
        'ImageTags': {}, 'Overview': 'A generated test clip.',
        'Chapters': [{'StartPositionTicks': s * T, 'Name': n}
                     for s, n in [(0, 'Opening'), (20, 'Middle'), (40, 'Finale')]],
        'MediaSources': [source(f'e{i}')],
    }


def source(id_, direct=True):
    return {
        'Id': id_, 'Container': 'mkv', 'Bitrate': 6_500_000, 'Name': 'movie',
        'SupportsDirectPlay': direct, 'SupportsDirectStream': direct, 'SupportsTranscoding': True,
        **({} if direct else {'TranscodingUrl': '/hls/main.m3u8?ApiKey=tok'}),
        'MediaStreams': [
            {'Index': 0, 'Type': 'Video', 'Codec': 'h264', 'Width': 1280, 'Height': 720, 'VideoRangeType': 'SDR', 'DisplayTitle': '720p H264'},
            {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'Channels': 1, 'Language': 'eng', 'IsDefault': True, 'DisplayTitle': 'English AAC'},
            {'Index': 2, 'Type': 'Audio', 'Codec': 'aac', 'Channels': 1, 'Language': 'spa', 'DisplayTitle': 'Spanish AAC'},
            {'Index': 3, 'Type': 'Subtitle', 'Codec': 'subrip', 'Language': 'eng', 'DisplayTitle': 'English SRT', 'IsTextSubtitleStream': True},
        ],
    }


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def note(self, extra=''):
        auth = self.headers.get('Authorization', '')
        LOG.write(f"{self.command} {self.path} auth={'yes' if 'Token=\"tok\"' in auth else 'NO'} range={self.headers.get('Range')} {extra}\n")
        LOG.flush()

    def send_json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def send_file(self, path, ctype):
        size = os.path.getsize(path)
        start, end = 0, size - 1
        m = re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range') or '')
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = int(m.group(2))
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        else:
            self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        try:
            with open(path, 'rb') as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        u = urlparse(self.path)
        p, q = u.path, parse_qs(u.query)
        self.note()
        if p == '/System/Info/Public':
            return self.send_json({'ServerName': 'Fake', 'Version': '10.11.0', 'Id': 'srv'})
        if p == '/UserViews':
            return self.send_json({'Items': [{'Id': 'lib', 'Name': 'Shows', 'CollectionType': 'tvshows'}]})
        if p == '/UserItems/Resume':
            return self.send_json({'Items': [ep(1)] if STATE['pos'] else []})
        if p == '/Shows/NextUp':
            return self.send_json({'Items': []})
        if p == '/Items/Latest':
            return self.send_json([])
        if p == '/Shows/s1/Episodes':
            start = q.get('startItemId', ['e1'])[0]
            eps = [ep(1), ep(2)]
            i = [e['Id'] for e in eps].index(start)
            return self.send_json({'Items': eps[i:]})
        m = re.match(r'/Items/(e\d)$', p)
        if m:
            return self.send_json(ep(int(m.group(1)[1])))
        if p.startswith('/MediaSegments/'):
            return self.send_json({'Items': [{'Type': 'Intro', 'StartTicks': 22 * T, 'EndTicks': 32 * T}]})
        if re.match(r'/Videos/e\d/stream', p):
            return self.send_file(os.path.join(MEDIA, 'movie.mkv'), 'video/x-matroska')
        if p.startswith('/hls/'):
            f = os.path.join(MEDIA, 'hls', os.path.basename(p))
            return self.send_file(f, 'application/vnd.apple.mpegurl' if f.endswith('.m3u8') else 'video/mp2t')
        if p.startswith('/Items') and p != '/Items':
            return self.send_json({'Items': []} if 'Similar' in p else {}, 200 if 'Similar' in p else 404)
        return self.send_json({'Items': [], 'TotalRecordCount': 0})

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        p = urlparse(self.path).path
        if p.endswith('/PlaybackInfo'):
            direct = bool(body.get('EnableDirectPlay'))
            self.note(f"direct={direct} maxBitrate={body.get('MaxStreamingBitrate')} audio={body.get('AudioStreamIndex')} sub={body.get('SubtitleStreamIndex')}")
            id_ = p.split('/')[2]
            return self.send_json({'MediaSources': [source(id_, direct)], 'PlaySessionId': 'sess'})
        if p.startswith('/Sessions/Playing'):
            self.note(f"item={body.get('ItemId')} pos={body.get('PositionTicks', 0) / T:.1f}s paused={body.get('IsPaused')} method={body.get('PlayMethod')}")
            if body.get('ItemId') == 'e1':
                STATE['pos'] = body.get('PositionTicks', 0)
            self.send_response(204)
            self.send_header('Content-Length', '0')
            return self.end_headers()
        self.note()
        self.send_json({})


ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
