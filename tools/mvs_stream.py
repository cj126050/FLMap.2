#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""狗端海康 MV-CS060 相机 → 主机实时看图（MJPEG over HTTP）。

狗端（Go2 / Jetson，需先装 MVS SDK 到 /opt/MVS）：
  export MVCAM_COMMON_RUNENV=/opt/MVS/lib
  export LD_LIBRARY_PATH=/opt/MVS/lib/aarch64:$LD_LIBRARY_PATH
  python3 mvs_stream.py --scale 4 --quality 75

主机观看：
  浏览器  http://192.168.123.18:8080/
  截图    http://192.168.123.18:8080/snapshot
  调曝光  http://192.168.123.18:8080/expo=60000
  调增益  http://192.168.123.18:8080/gain=12
  统计    http://192.168.123.18:8080/stats

架构要点（都是实测踩出来的，别改回去）：
  1. HTTP 必须多线程。单线程 HTTPServer 下 /stream 会一直占着唯一线程，
     /stats 和 /snapshot 全部超时。
  2. 编码只做一次，放独立线程，所有客户端共用同一份 JPEG。否则每来一个
     浏览器就多一份编码，Jetson 扛不住。
  3. 采集线程零拷贝：直接把 ctypes 缓冲拷进预分配的 numpy 数组，交给编码
     线程时只传引用。之前用 bytes(self.buf[:need]) 每帧复制 4.5MB，
     把编码线程卡到 1.5fps（实测从 1.5 提到 10.4）。
  4. 降采样用「纯抽样」不用「2x2 平均」：3072x2048 抽 1/4 只要 3.3ms，
     做平均要 46ms，慢 14 倍。
  5. 编码用 PIL/libjpeg 的 JPEG。PNG+zlib 压缩 768x512 要 114ms、1MB，
     JPEG 只要 2.4ms、58KB。
"""
import argparse
import struct
import sys
import threading
import time
import zlib
from ctypes import *
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, "/opt/MVS/Samples/aarch64/Python/MvImport")
from MvCameraControl_class import *  # noqa


# numpy 可选：有就用（快一个量级），没有退回纯 Python
try:
    import numpy as _NP
except Exception:
    _NP = None

# PIL 可选：用来做 JPEG 编码。JPEG 比 PNG 小一个量级，编码还更快
try:
    from PIL import Image as _PILImage
    import io as _io
except Exception:
    _PILImage = None


def encode_jpeg(rgb, w, h, quality=70):
    """用 PIL/libjpeg 编 JPEG。768x512 q75 约 2.4ms、58KB，比 PNG 小 18 倍。"""
    if _PILImage is not None and _NP is not None:
        a = rgb if isinstance(rgb, _NP.ndarray) else _NP.frombuffer(
            rgb, dtype=_NP.uint8, count=w * h * 3)
        a = a.reshape(h, w, 3)
        buf = _io.BytesIO()
        _PILImage.fromarray(a, "RGB").save(buf, "JPEG", quality=quality,
                                           optimize=False, progressive=False,
                                           subsampling=2)
        return buf.getvalue(), "image/jpeg"
    if isinstance(rgb, _NP.ndarray):
        rgb = rgb.tobytes()
    return encode_png(rgb, w, h, 1), "image/png"


# ───────────────────────────── PNG 编码
def encode_png(rgb, w, h, level=3):
    """PNG 编码。filter 全 0（None）时每行前加一个 0 字节即可，
    用 numpy 一次拼好，比逐行拷贝快得多。"""
    stride = w * 3
    if _NP is not None:
        a = rgb if isinstance(rgb, _NP.ndarray) else _NP.frombuffer(
            rgb, dtype=_NP.uint8, count=stride * h)
        a = a.reshape(h, stride)
        raw = _NP.zeros((h, stride + 1), dtype=_NP.uint8)
        raw[:, 1:] = a
        body = raw.tobytes()
    else:
        if isinstance(rgb, _NP.ndarray) and _NP is not None:
            rgb = rgb.tobytes()
        raw = bytearray((stride + 1) * h)
        o = 0
        for y in range(h):
            raw[o] = 0
            o += 1
            raw[o:o + stride] = rgb[y * stride:(y + 1) * stride]
            o += stride
        body = bytes(raw)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(body, level)) +
            chunk(b"IEND", b""))


def downscale_rgb(data, w, h, factor):
    """降采样。numpy 可用时用「纯抽样」（跨步切片），这是实测最快的方式：

        3072x2048 抽 1/4 -> 768x512    3.3 ms
        3072x2048 做 2x2 平均          46.0 ms   ← 慢 14 倍，不做

    data 可以是 bytes 也可以是 numpy 数组（采集线程零拷贝传过来）。
    """
    if factor <= 1:
        return data, w, h
    if _NP is not None:
        a = data if isinstance(data, _NP.ndarray) else _NP.frombuffer(
            data, dtype=_NP.uint8, count=w * h * 3)
        a = a.reshape(h, w, 3)
        b = a[0::factor, 0::factor]
        c = _NP.ascontiguousarray(b)
        return c, c.shape[1], c.shape[0]

    nw, nh = w // factor, h // factor
    out = bytearray(nw * nh * 3)
    o = 0
    for y in range(nh):
        row = data[(y * factor) * w * 3:((y * factor) + 1) * w * 3]
        for x in range(nw):
            p = x * factor * 3
            out[o] = row[p]
            out[o + 1] = row[p + 1]
            out[o + 2] = row[p + 2]
            o += 3
    return bytes(out), nw, nh


# 暗光增强：曝光不足时把信号拉起来，否则主机看到的就是全黑
def auto_stretch(data, low_pct=2, high_cap=255):
    if _NP is not None:
        a = data if isinstance(data, _NP.ndarray) else _NP.frombuffer(data, dtype=_NP.uint8)
        n = a.size
        step = max(1, n // (256 * 1024))
        g = a[::step]
        lo = int(_NP.percentile(g, low_pct))
        hi = int(_NP.percentile(g, 99.5))
        if hi <= lo + 4:
            return data
        scale = high_cap / float(hi - lo)
        lut = _NP.clip((_NP.arange(256, dtype=_NP.float32) - lo) * scale,
                       0, 255).astype(_NP.uint8)
        return lut[a]

    hist = [0] * 256
    step = max(1, len(data) // 400000)
    for v in data[::step]:
        hist[v] += 1
    total = sum(hist)
    lo = hi = 0
    acc = 0
    for i in range(256):
        acc += hist[i]
        if acc >= total * low_pct / 100.0:
            lo = i
            break
    acc = 0
    for i in range(255, -1, -1):
        acc += hist[i]
        if acc >= total * 0.5 / 100.0:
            hi = i
            break
    if hi <= lo + 4:
        return data
    scale = high_cap / float(hi - lo)
    lut = bytes(0 if i < lo else min(255, int((i - lo) * scale)) for i in range(256))
    return data.translate(lut)


PAGE = b"""<!doctype html><meta charset=utf-8><title>MV-CS060 @ Go2</title>
<style>
body{margin:0;background:#0d0d0d;color:#d8d8d8;font:13px/1.5 system-ui,sans-serif}
header{padding:8px 16px;background:#191919;border-bottom:1px solid #2e2e2e;
       display:flex;gap:18px;align-items:center;flex-wrap:wrap}
b{color:#6cf} code{background:#222;padding:1px 5px;border-radius:3px}
a{color:#8cf} img{display:block;max-width:100%;margin:8px auto;background:#000}
</style>
<header>
  <b>Go2 / MV-CS060-10UC-PRO</b>
  <span id=s>connecting...</span>
  <span>exp <code id=e>-</code>us</span>
  <span><a href="/snapshot">snapshot</a></span>
</header>
<img src="/stream">
<script>
setInterval(()=>fetch('/stats').then(r=>r.json()).then(d=>{
  document.getElementById('s').textContent =
    d.w+'x'+d.h+'  '+d.fps.toFixed(1)+' fps  '+d.frames+' frames';
  document.getElementById('e').textContent = d.expo;
}).catch(()=>{}),1000);
</script>
"""


class Cam:
    def __init__(self, expo, gain, pixfmt, binning=1, decim=1, roi=1):
        self.expo, self.gain, self.pixfmt = expo, gain, pixfmt
        self.binning, self.decim, self.roi = binning, decim, roi
        self.hw_factor = 1
        self.lock = threading.Lock()
        self.frame = None
        self.w = self.h = 0
        self.fps = 0.0
        self.count = 0
        self.seq = 0
        self.idx = 0
        self.err = None
        # 编码结果（服务端只算一次，所有客户端共用）
        self.png = None
        self.png_type = "image/jpeg"
        self.png_seq = 0
        self.png_lock = threading.Lock()
        self.enc_fps = 0.0

    def open(self):
        MvCamera.MV_CC_Initialize()
        dl = MV_CC_DEVICE_INFO_LIST()
        if MvCamera.MV_CC_EnumDevices(MV_GIGE_DEVICE | MV_USB_DEVICE, dl) != 0 or dl.nDeviceNum == 0:
            raise RuntimeError("没有枚举到相机")
        # 多台时找海康那台
        target = 0
        for i in range(dl.nDeviceNum):
            info = cast(dl.pDeviceInfo[i], POINTER(MV_CC_DEVICE_INFO)).contents
            if info.nTLayerType == MV_USB_DEVICE:
                usb = info.SpecialInfo.stUsb3VInfo
                name = bytes(usb.chModelName).decode("utf-8", "ignore").strip("\x00")
                print("  [%d] %s" % (i, name), flush=True)
                if "MV-" in name:
                    target = i
        info = cast(dl.pDeviceInfo[target], POINTER(MV_CC_DEVICE_INFO)).contents
        self.cam = MvCamera()
        if self.cam.MV_CC_CreateHandle(info) != 0:
            raise RuntimeError("创建句柄失败（相机可能被别的进程占用）")
        if self.cam.MV_CC_OpenDevice(MV_ACCESS_Exclusive, 0) != 0:
            raise RuntimeError("打开设备失败")
        c = self.cam
        c.MV_CC_SetEnumValue("TriggerMode", 0)
        c.MV_CC_SetEnumValue("ExposureAuto", 0)
        c.MV_CC_SetEnumValue("GainAuto", 0)
        c.MV_CC_SetEnumValue("PixelFormat", self.pixfmt)
        c.MV_CC_SetFloatValue("ExposureTime", float(self.expo))
        c.MV_CC_SetFloatValue("Gain", float(self.gain))

        # ── 硬件降采样：让相机直接吐小图，省掉 Python 逐像素运算
        #   Binning=2 是 2x2 硬平均值，顺带降噪；Decimation 是抽样，更快但易出锯齿
        #   优先 Binning，再叠 Decimation
        self.hw_factor = 1
        if self.binning > 1:
            if (c.MV_CC_SetEnumValue("BinningHorizontal", self.binning) == 0 and
                    c.MV_CC_SetEnumValue("BinningVertical", self.binning) == 0):
                self.hw_factor *= self.binning
            else:
                print("  Binning 不可用，跳过", flush=True)
        if self.decim > 1:
            if (c.MV_CC_SetEnumValue("DecimationHorizontal", self.decim) == 0 and
                    c.MV_CC_SetEnumValue("DecimationVertical", self.decim) == 0):
                self.hw_factor *= self.decim
            else:
                print("  Decimation 不可用，跳过", flush=True)

        # ── 相机直接出小图（ROI 裁切）：这是最快的路，Python 端零运算
        #   Width 增量 4、Height 增量 2、最小 376x320
        if self.roi:
            rm = MVCC_INTVALUE()
            memset(byref(rm), 0, sizeof(rm))
            c.MV_CC_GetIntValue("WidthMax", rm)
            wmax = rm.nCurValue or 3072
            memset(byref(rm), 0, sizeof(rm))
            c.MV_CC_GetIntValue("HeightMax", rm)
            hmax = rm.nCurValue or 2048
            tw = max(376, (wmax // self.roi) // 4 * 4)
            th = max(320, (hmax // self.roi) // 2 * 2)
            c.MV_CC_SetIntValue("Width", tw)
            c.MV_CC_SetIntValue("Height", th)
            print("  相机 ROI 直接出小图 -> %dx%d" % (tw, th), flush=True)

        if c.MV_CC_StartGrabbing() != 0:
            raise RuntimeError("开始取流失败")
        pl = MVCC_INTVALUE()
        memset(byref(pl), 0, sizeof(pl))
        c.MV_CC_GetIntValue("PayloadSize", pl)
        self.n = pl.nCurValue
        self.buf = (c_ubyte * self.n)()
        threading.Thread(target=self._loop, daemon=True).start()

    def start_encoder(self, factor, level, stretch):
        """独立编码线程：取最新帧 → 降采样 → 拉伸 → PNG，只算一次

        factor 是期望的总缩小倍数（相对 3072 全幅）。
        ROI/Binning 已经把图缩过了，软件只补剩余倍数，且下限为 1
        —— 目标是「软件缩放不做或只做 1 次」，因为 Jetson 上纯 Python 很贵。
        """
        def run():
            seen = -1
            t0, cnt = time.time(), 0
            sw = 1
            while True:
                with self.lock:
                    data, w, h, seq = self.frame, self.w, self.h, self.seq
                if data is None or seq == seen:
                    time.sleep(0.005)
                    continue
                seen = seq
                # 目标宽度 = 3072/factor，按实际帧宽取整数倍（只允许 1/2/3/4）
                target = max(1, 3072 // max(1, factor))
                sw = max(1, min(4, int(round(w / float(target)))))
                try:
                    rgb, nw, nh = downscale_rgb(data, w, h, sw)
                    if stretch:
                        rgb = auto_stretch(rgb)
                    img, ctype = encode_jpeg(rgb, nw, nh, level)
                except Exception as e:
                    print("编码失败:", e, flush=True)
                    time.sleep(0.2)
                    continue
                with self.png_lock:
                    self.png = img
                    self.png_type = ctype
                    self.png_seq += 1
                cnt += 1
                el = time.time() - t0
                if el >= 1.0:
                    self.enc_fps = cnt / el
                    t0, cnt = time.time(), 0
        threading.Thread(target=run, daemon=True).start()

    def _loop(self):
        fr = MV_FRAME_OUT_INFO_EX()
        memset(byref(fr), 0, sizeof(fr))
        t0, cnt = time.time(), 0
        # 双缓冲：两块 numpy 数组轮流写。写入后只交换「引用」，不做 bytes 复制，
        # 避免每帧拷贝 4.5MB 拖住 GIL（这曾是编码帧率上不去的真凶）。
        nbuf = 2
        bufs = None
        idx = 0
        while True:
            if self.cam.MV_CC_GetOneFrameTimeout(byref(self.buf), self.n, fr, 2000) != 0:
                continue
            need = fr.nWidth * fr.nHeight * 3
            if need > self.n:
                continue
            if _NP is not None:
                if bufs is None:
                    bufs = [_NP.empty(need, dtype=_NP.uint8) for _ in range(nbuf)]
                cur = bufs[idx]
                idx = (idx + 1) % nbuf
                cur[:] = _NP.frombuffer(self.buf, dtype=_NP.uint8, count=need)
                payload = cur            # 直接交给编码线程，零拷贝
            else:
                payload = bytes(self.buf[:need])
            with self.lock:
                self.frame = payload
                self.w, self.h = fr.nWidth, fr.nHeight
                self.count += 1
                self.seq += 1
            cnt += 1
            el = time.time() - t0
            if el >= 1.0:
                self.fps = cnt / el
                t0, cnt = time.time(), 0

    def set_expo(self, v):
        if self.cam.MV_CC_SetFloatValue("ExposureTime", float(v)) == 0:
            self.expo = v

    def set_gain(self, v):
        if self.cam.MV_CC_SetFloatValue("Gain", float(v)) == 0:
            self.gain = v

    def close(self):
        try:
            self.cam.MV_CC_StopGrabbing()
            self.cam.MV_CC_CloseDevice()
            self.cam.MV_CC_DestroyHandle()
        except Exception:
            pass


def make_handler(cam, factor, level, stretch):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, *a):
            pass

        def do_GET(self):
            p = self.path
            if p in ("/", "/index.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(PAGE)))
                self.end_headers()
                self.wfile.write(PAGE)
                return
            if p.startswith("/stats"):
                body = ('{"fps":%.2f,"efps":%.2f,"w":%d,"h":%d,"expo":%d,"gain":%.1f,"frames":%d}'
                        % (cam.fps, cam.enc_fps, cam.w, cam.h,
                           cam.expo, cam.gain, cam.count)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if p.startswith("/expo") or p.startswith("/gain"):
                try:
                    key, val = p.lstrip("/").split("=")[0], float(p.split("=")[1].split("&")[0])
                    if key == "expo":
                        cam.set_expo(int(val))
                    else:
                        cam.set_gain(val)
                    print("[%s] -> %s" % (key, val), flush=True)
                except Exception as e:
                    print("参数设置失败:", e, flush=True)
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")
                return
            if p.startswith("/snapshot"):
                with cam.png_lock:
                    png, ctype = cam.png, cam.png_type
                if png is None:
                    self.send_error(503, "no frame yet")
                    return
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(png)))
                self.end_headers()
                self.wfile.write(png)
                return
            if p.startswith("/stream"):
                self.send_response(200)
                self.send_header("Content-Type",
                                 "multipart/x-mixed-replace; boundary=frame")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                last = -1
                while True:
                    with cam.png_lock:
                        png, ctype, seq = cam.png, cam.png_type, cam.png_seq
                    if png is None or seq == last:
                        time.sleep(0.01)
                        continue
                    last = seq
                    try:
                        self.wfile.write(b"--frame\r\nContent-Type: " +
                                         ctype.encode() +
                                         b"\r\nContent-Length: %d\r\n\r\n" % len(png))
                        self.wfile.write(png)
                        self.wfile.write(b"\r\n")
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        return
                return
            self.send_error(404)
    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--expo", type=int, default=30000)
    ap.add_argument("--gain", type=float, default=10.0,
                    help="默认给点增益，暗光下更容易看出内容")
    ap.add_argument("--scale", type=int, default=4,
                    help="目标总缩小倍数，决定最终宽度 = 3072/scale")
    ap.add_argument("--roi", type=int, default=1,
                    help="相机 ROI 裁切倍数：1=全幅（默认）。"
                         ">1 只取左上角一小块，是用画幅换速度，看画面时别开")
    ap.add_argument("--binning", type=int, default=2, choices=[1, 2],
                    help="相机硬件合并（2x2 平均，降噪），默认 2")
    ap.add_argument("--decim", type=int, default=1, choices=[1, 2, 4],
                    help="相机硬件抽样（更快，略有锯齿），默认关")
    ap.add_argument("--quality", type=int, default=70,
                    help="JPEG 质量 30-95，默认 70（PIL 不可用时退化成 zlib 级别）")
    ap.add_argument("--no-stretch", action="store_true", help="关掉自动对比度拉伸")
    args = ap.parse_args()

    print("打开相机…", flush=True)
    cam = Cam(args.expo, args.gain, PixelType_Gvsp_RGB8_Packed,
              binning=args.binning, decim=args.decim, roi=args.roi)
    cam.open()
    time.sleep(1.5)
    cam.start_encoder(args.scale, args.quality, not args.no_stretch)
    print("✓ 相机输出 %dx%d  曝光=%dus 增益=%.1fdB  拉伸=%s"
          % (cam.w, cam.h, args.expo, args.gain,
             "关" if args.no_stretch else "开"), flush=True)
    print("  主机看: http://192.168.123.18:%d/" % args.port, flush=True)

    class Srv(ThreadingHTTPServer):
        daemon_threads = True

    srv = Srv(("0.0.0.0", args.port),
              make_handler(cam, args.scale, args.quality, not args.no_stretch))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n退出")
    finally:
        cam.close()


if __name__ == "__main__":
    main()
