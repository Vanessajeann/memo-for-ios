"""Exercise the actual C bridge with synthetic, local media; no user streams."""
import hashlib
import http.server
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import tempfile
from urllib.parse import urlsplit

binary = str(Path(sys.argv[1]).resolve())
parent = Path(sys.argv[2]).resolve(); parent.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
def command(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)
command('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=10',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '4', '-c:v', 'libx264',
        '-preset', 'ultrafast', '-g', '10', '-bf', '0', '-c:a', 'aac', '-movflags', '+faststart', str(root / 'input.mp4'))
command('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(root/'input.mp4'), '-c', 'copy',
        '-f', 'hls', '-hls_time', '1', '-hls_list_size', '0', str(root/'live.m3u8'))
command('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(root/'input.mp4'), '-c', 'copy', '-f', 'mpegts', str(root/'slow.ts'))
requests = []
class Server(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=str(root), **kwargs)
    def log_message(self, *args): pass
    def do_GET(self):
        requests.append((self.path, self.headers.get('Cookie', '')))
        if self.path == '/cookie.mp4':
            if self.headers.get('Cookie') != 'fixture=ok':
                self.send_error(403); return
            self.path = '/input.mp4'
        elif self.path == '/redirect':
            self.send_response(302); self.send_header('Location', f'http://localhost:{self.server.server_port}/input.mp4'); self.end_headers(); return
        elif self.path == '/stall':
            time.sleep(3); return
        elif self.path == '/slow.ts':
            data = (root/'slow.ts').read_bytes()
            self.send_response(200); self.send_header('Content-Type', 'video/mp2t'); self.send_header('Content-Length', str(len(data))); self.end_headers()
            try:
                for i in range(0,len(data),188*4): self.wfile.write(data[i:i+188*4]); self.wfile.flush(); time.sleep(.01)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        super().do_GET()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Server)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
checks = 0
def check(condition, description):
    global checks
    if not condition: raise AssertionError(description)
    checks += 1; print('PASS', description, flush=True)
def run(mode, source, name, cookie='', cancel=0):
    return json.loads(subprocess.check_output([binary,mode,str(source),str(root/name),cookie,str(cancel)],timeout=20))
def packets(path, selection):
    data = command('ffprobe','-v','error','-select_streams',selection,'-show_packets','-show_data_hash','sha256',
                   '-show_entries','packet=data_hash','-of','json',str(path))
    return [p['data_hash'] for p in json.loads(data)['packets']]
try:
    result = run('capture',base+'/input.mp4','capture.mkv')
    check(result['code']==0 and result['packets']>0, 'HTTP MP4 captured as MKV: '+str(result))
    check(packets(root/'input.mp4','v')==packets(root/'capture.mkv','v'), 'recorded video packet payloads unchanged')
    result = run('mp4',root/'capture.mkv','final.mp4')
    check(result['code']==0, 'MKV remuxed to MP4')
    for selection in ['v','a']:
        check(packets(root/'capture.mkv',selection)==packets(root/'final.mp4',selection), 'MP4 '+selection+' packet payloads unchanged')
    command('ffmpeg','-v','error','-i',str(root/'final.mp4'),'-f','null','-')
    check(True, 'final MP4 audio and video decode')
    result = run('capture',base+'/live.m3u8','hls.mkv')
    check(result['code']==0 and result['packets']>0, 'HLS MPEG-TS with ADTS AAC captured')
    result = run('mp4',root/'hls.mkv','hls.mp4')
    check(result['code']==0, 'HLS capture remuxed to MP4')
    command('ffmpeg','-v','error','-i',str(root/'hls.mp4'),'-f','null','-')
    check(True, 'HLS result decodes')
    result=run('capture',base+'/cookie.mp4','cookie.mkv','fixture=ok')
    check(result['code']==0, 'same-host Cookie reaches authenticated input: '+str(requests[-2:]))
    before=len(requests)
    result=run('capture',base+'/redirect','redirect.mkv','fixture=ok')
    check(result['code']==0 and any(p=='/input.mp4' and c=='' for p,c in requests[before:]), 'redirect to another hostname does not receive Cookie')
    check(run('capture',base+'/absent.mp4','absent.mkv')['code']<0, 'HTTP errors are reported')
    start=time.monotonic(); run('capture',base+'/stall','stall.mkv',cancel=100)
    check(time.monotonic()-start<2, 'stop interrupts a blocked network read')
    result=run('capture',base+'/slow.ts','stopped.mkv',cancel=-1)
    check(result['code']==0 and result['packets']>=5, 'stop after media writes closes a retained segment')
    command('ffmpeg','-v','error','-i',str(root/'stopped.mkv'),'-f','null','-')
    check(True, 'stopped segment decodes')
    sentinel=b'do not overwrite'; (root/'existing.mkv').write_bytes(sentinel)
    check(run('capture',base+'/input.mp4','existing.mkv')['code']<0 and (root/'existing.mkv').read_bytes()==sentinel, 'existing output is never overwritten')
    original=(root/'capture.mkv').read_bytes()
    check(run('mp4',root/'capture.mkv','existing.mkv')['code']<0 and (root/'capture.mkv').read_bytes()==original, 'failed MP4 conversion retains its input')
    check(run('mp4',root/'capture.mkv','cancelled.part',cancel=-2)['code']<0 and (root/'capture.mkv').read_bytes()==original, 'cancelled MP4 conversion cannot report a complete file')
    check(run('capture',base+'/input.mp4','injected.mkv','a=b\r\nInjected: yes')['code']<0, 'native bridge rejects header injection independently')
    print(json.dumps({'checks':checks,'status':'passed'}))
finally:
    server.shutdown()
