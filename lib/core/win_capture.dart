import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

// Windows system calls, bound by name. The screen and the clipboard are read through them
// directly, so no script has to be written to disk and run (the app has administrator rights).
typedef _VoidP = Pointer<Void>;

typedef _GetMetricsC = Int32 Function(Int32);
typedef _GetMetrics = int Function(int);
typedef _GetDcC = _VoidP Function(_VoidP);
typedef _GetDc = _VoidP Function(_VoidP);
typedef _ReleaseDcC = Int32 Function(_VoidP, _VoidP);
typedef _ReleaseDc = int Function(_VoidP, _VoidP);
typedef _CompatDcC = _VoidP Function(_VoidP);
typedef _CompatDc = _VoidP Function(_VoidP);
typedef _CompatBmpC = _VoidP Function(_VoidP, Int32, Int32);
typedef _CompatBmp = _VoidP Function(_VoidP, int, int);
typedef _SelectC = _VoidP Function(_VoidP, _VoidP);
typedef _Select = _VoidP Function(_VoidP, _VoidP);
typedef _BitBltC = Int32 Function(_VoidP, Int32, Int32, Int32, Int32, _VoidP, Int32, Int32, Uint32);
typedef _BitBlt = int Function(_VoidP, int, int, int, int, _VoidP, int, int, int);
typedef _GetDibitsC = Int32 Function(_VoidP, _VoidP, Uint32, Uint32, Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _GetDibits = int Function(_VoidP, _VoidP, int, int, Pointer<Uint8>, Pointer<Uint8>, int);
typedef _DeleteC = Int32 Function(_VoidP);
typedef _Delete = int Function(_VoidP);
typedef _OpenClipC = Int32 Function(_VoidP);
typedef _OpenClip = int Function(_VoidP);
typedef _NoArgsC = Int32 Function();
typedef _NoArgs = int Function();
typedef _GetClipC = _VoidP Function(Uint32);
typedef _GetClip = _VoidP Function(int);
typedef _LockC = _VoidP Function(_VoidP);
typedef _Lock = _VoidP Function(_VoidP);
typedef _SizeC = IntPtr Function(_VoidP);
typedef _Size = int Function(_VoidP);

/// A picture of the whole screen (all monitors), as image file bytes, or null.
Future<Uint8List?> captureScreen() async {
  if (!Platform.isWindows) return null;
  try {
    final raw = _grabScreen();
    if (raw == null) return null;
    // Turning the pixels into a PNG takes a moment for a big screen: off the UI thread.
    return await Isolate.run(() {
      final image = img.Image.fromBytes(
          width: raw.width,
          height: raw.height,
          bytes: raw.pixels.buffer,
          order: img.ChannelOrder.bgra,
          numChannels: 4);
      return Uint8List.fromList(img.encodePng(image));
    });
  } catch (_) {
    return null;
  }
}

({int width, int height, Uint8List pixels})? _grabScreen() {
  final user = DynamicLibrary.open('user32.dll');
  final gdi = DynamicLibrary.open('gdi32.dll');
  final metrics = user.lookupFunction<_GetMetricsC, _GetMetrics>('GetSystemMetrics');
  // the virtual screen: every monitor, its top-left corner may be negative
  final x = metrics(76), y = metrics(77), w = metrics(78), h = metrics(79);
  if (w <= 0 || h <= 0 || w * h > 100 * 1000 * 1000) return null;
  final getDc = user.lookupFunction<_GetDcC, _GetDc>('GetDC');
  final releaseDc = user.lookupFunction<_ReleaseDcC, _ReleaseDc>('ReleaseDC');
  final createDc = gdi.lookupFunction<_CompatDcC, _CompatDc>('CreateCompatibleDC');
  final createBmp = gdi.lookupFunction<_CompatBmpC, _CompatBmp>('CreateCompatibleBitmap');
  final select = gdi.lookupFunction<_SelectC, _Select>('SelectObject');
  final bitBlt = gdi.lookupFunction<_BitBltC, _BitBlt>('BitBlt');
  final getBits = gdi.lookupFunction<_GetDibitsC, _GetDibits>('GetDIBits');
  final deleteObject = gdi.lookupFunction<_DeleteC, _Delete>('DeleteObject');
  final deleteDc = gdi.lookupFunction<_DeleteC, _Delete>('DeleteDC');

  final screen = getDc(nullptr);
  if (screen.address == 0) return null;
  final memory = createDc(screen);
  final bitmap = createBmp(screen, w, h);
  final header = calloc<Uint8>(40);
  final pixels = calloc<Uint8>(w * h * 4);
  try {
    final old = select(memory, bitmap);
    // SRCCOPY | CAPTUREBLT: also windows that are layered or float above the rest
    final ok = bitBlt(memory, 0, 0, w, h, screen, x, y, 0x00CC0020 | 0x40000000);
    select(memory, old);
    if (ok == 0) return null;
    // BITMAPINFOHEADER: 40 bytes, a negative height means the top row comes first
    final head = header.cast<Int32>();
    head[0] = 40;
    head[1] = w;
    head[2] = -h;
    header.cast<Uint16>()[6] = 1; // planes
    header.cast<Uint16>()[7] = 32; // bits per pixel
    final lines = getBits(memory, bitmap, 0, h, pixels, header, 0);
    if (lines == 0) return null;
    return (width: w, height: h, pixels: Uint8List.fromList(pixels.asTypedList(w * h * 4)));
  } finally {
    calloc.free(header);
    calloc.free(pixels);
    deleteObject(bitmap);
    deleteDc(memory);
    releaseDc(nullptr, screen);
  }
}

/// The picture on the clipboard, as image file bytes, or null when there is none.
Future<Uint8List?> clipboardImage() async {
  if (!Platform.isWindows) return null;
  try {
    return _clipboardBmp();
  } catch (_) {
    return null;
  }
}

Uint8List? _clipboardBmp() {
  final user = DynamicLibrary.open('user32.dll');
  final kernel = DynamicLibrary.open('kernel32.dll');
  final open = user.lookupFunction<_OpenClipC, _OpenClip>('OpenClipboard');
  final close = user.lookupFunction<_NoArgsC, _NoArgs>('CloseClipboard');
  final getData = user.lookupFunction<_GetClipC, _GetClip>('GetClipboardData');
  final lock = kernel.lookupFunction<_LockC, _Lock>('GlobalLock');
  final unlock = kernel.lookupFunction<_OpenClipC, _OpenClip>('GlobalUnlock');
  final size = kernel.lookupFunction<_SizeC, _Size>('GlobalSize');

  if (open(nullptr) == 0) return null;
  try {
    const cfDib = 8;
    final handle = getData(cfDib);
    if (handle.address == 0) return null;
    final data = lock(handle);
    if (data.address == 0) return null;
    try {
      final length = size(handle);
      if (length < 40 || length > 256 * 1024 * 1024) return null;
      final dib = Uint8List.fromList(data.cast<Uint8>().asTypedList(length));
      final view = ByteData.sublistView(dib);
      final headerSize = view.getUint32(0, Endian.little);
      final bits = view.getUint16(14, Endian.little);
      final compression = view.getUint32(16, Endian.little);
      var colors = view.getUint32(32, Endian.little);
      if (colors == 0 && bits <= 8) colors = 1 << bits;
      // where the pixels start: after the header, the colour masks and the palette
      final offset = 14 + headerSize + (compression == 3 ? 12 : 0) + colors * 4;
      final file = Uint8List(14 + length);
      final out = ByteData.sublistView(file);
      file[0] = 0x42; // "BM"
      file[1] = 0x4D;
      out.setUint32(2, file.length, Endian.little);
      out.setUint32(10, offset, Endian.little);
      file.setRange(14, file.length, dib);
      return file;
    } finally {
      unlock(handle);
    }
  } finally {
    close();
  }
}
