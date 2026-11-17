import 'package:flutter/material.dart';
import 'package:path_drawing/path_drawing.dart' show parseSvgPathData;

/// The logo of a coin, drawn from its outline (the path of its SVG; no picture is shipped). The outlines are from Simple Icons
/// (Bitcoin, Litecoin, Tether, TON; CC0) and from the cryptocurrency-icons of spothq (Tron; CC0). The names and the logos belong
/// to the projects they stand for; they are here only to tell a wallet from another.
///
/// A coin that has no outline here is drawn as a circle with its ticker in it.
class CoinIcon extends StatelessWidget {
  const CoinIcon(this.coin, {super.key, this.size = 44});

  /// The ticker (`BTC`, `USDT`).
  final String coin;
  final double size;

  @override
  Widget build(BuildContext context) {
    final logo = _logos[coin.toUpperCase()];
    if (logo == null) return _Ticker(coin: coin, size: size);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LogoPainter(logo)),
    );
  }
}

class _Logo {
  const _Logo(this.color, this.box, this.path, {this.disc = true});

  final Color color;

  /// The side of the square the outline is drawn in.
  final double box;
  final String path;

  /// The logo is a circle: what is cut out of it (the letter) is white, as in the logo.
  final bool disc;
}

const _logos = <String, _Logo>{
  'BTC': _Logo(
    Color(0xFFF7931A),
    24,
    'M23.638 14.904c-1.602 6.43-8.113 10.34-14.542 8.736C2.67 22.05-1.244 15.525.362 9.105 1.962 2.67 8.475-1.243 14.9.358c6.43 1.605 10.342 8.115 8.738 14.548v-.002zm-6.35-4.613c.24-1.59-.974-2.45-2.64-3.03l.54-2.153-1.315-.33-.525 2.107c-.345-.087-.705-.167-1.064-.25l.526-2.127-1.32-.33-.54 2.165c-.285-.067-.565-.132-.84-.2l-1.815-.45-.35 1.407s.975.225.955.236c.535.136.63.486.615.766l-1.477 5.92c-.075.166-.24.406-.614.314.015.02-.96-.24-.96-.24l-.66 1.51 1.71.426.93.242-.54 2.19 1.32.327.54-2.17c.36.1.705.19 1.05.273l-.51 2.154 1.32.33.545-2.19c2.24.427 3.93.257 4.64-1.774.57-1.637-.03-2.58-1.217-3.196.854-.193 1.5-.76 1.68-1.93h.01zm-3.01 4.22c-.404 1.64-3.157.75-4.05.53l.72-2.9c.896.23 3.757.67 3.33 2.37zm.41-4.24c-.37 1.49-2.662.735-3.405.55l.654-2.64c.744.18 3.137.524 2.75 2.084v.006z',
  ),
  'LTC': _Logo(
    Color(0xFF345D9D),
    24,
    'M12 0a12 12 0 1012 12A12 12 0 0012 0zm-.2617 3.6777h2.584a.3425.3425 0 01.33.4356l-2.0312 6.918 1.9062-.582-.4082 1.3847-1.9238.5605-1.248 4.213h6.6757a.3425.3425 0 01.3282.4374l-.582 2a.4586.4586 0 01-.4395.3301H6.7324l1.7227-5.8223-1.9063.5801.42-1.3613 1.9101-.58 2.4219-8.1798a.4557.4557 0 01.4375-.334Z',
  ),
  'USDT': _Logo(
    Color(0xFF26A17B),
    24,
    'M18.7538 10.5176c0 .6251-2.2379 1.1483-5.2381 1.2812l.0028.0007c-.0848.0064-.5233.0325-1.5012.0325-.7778 0-1.33-.0233-1.5237-.0325-3.0059-.1322-5.2495-.6555-5.2495-1.2819s2.2436-1.149 5.2495-1.2834v2.0442c.1965.0142.7594.0474 1.5372.0474.9334 0 1.4008-.0389 1.4849-.0466V9.2356c2.9994.1337 5.2381.657 5.2381 1.282zm5.19.5466L12.1248 22.389a.1803.1803 0 0 1-.2496 0L.0562 11.0635a.1781.1781 0 0 1-.0382-.2079l4.3762-9.1921a.1767.1767 0 0 1 .1626-.1026h14.8878a.1768.1768 0 0 1 .1612.1032l4.3762 9.1922a.1782.1782 0 0 1-.0382.2079zm-4.478-.4038c0-.8068-2.5515-1.4799-5.9473-1.6369V7.195h4.186V4.4055H6.3076V7.195h4.1852v1.8286c-3.4018.1562-5.9601.83-5.9601 1.6376 0 .8075 2.5583 1.4806 5.9601 1.6376v5.8618h3.025v-5.8639c3.394-.1563 5.948-.8295 5.948-1.6363z',
    disc: false,
  ),
  'TON': _Logo(
    Color(0xFF0098EA),
    24,
    'M12 0C5.373 0 0 5.373 0 12s5.373 12 12 12 12-5.373 12-12S18.627 0 12 0zM7.902 6.697h8.196c1.505 0 2.462 1.628 1.705 2.94l-5.059 8.765a.86.86 0 0 1-1.488 0L6.199 9.637c-.758-1.314.197-2.94 1.703-2.94zm4.844 1.496v7.58l1.102-2.128 2.656-4.756a.465.465 0 0 0-.408-.696h-3.35zM7.9 8.195a.464.464 0 0 0-.408.694l2.658 4.754 1.102 2.13V8.195H7.9z',
  ),
  'TRX': _Logo(
    Color(0xFFEF0027),
    32,
    'M16 0c8.837 0 16 7.163 16 16s-7.163 16-16 16S0 24.837 0 16 7.163 0 16 0zM7.5 7.257l7.595 19.112 10.583-12.894-3.746-3.562L7.5 7.257zm16.252 6.977l-7.67 9.344.983-8.133 6.687-1.21zM9.472 9.488l6.633 5.502-1.038 8.58L9.472 9.487zM21.7 11.083l2.208 2.099-6.038 1.093 3.83-3.192zM10.194 8.778l10.402 1.914-4.038 3.364-6.364-5.278z',
  ),
};

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.logo) : path = parseSvgPathData(logo.path);

  final _Logo logo;
  final Path path;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / logo.box;
    // The white behind the circle shows through what is cut out of it.
    if (logo.disc) {
      canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 0.5, Paint()..color = Colors.white);
    }
    canvas.save();
    canvas.scale(scale);
    canvas.drawPath(path, Paint()..color = logo.color..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.logo != logo;
}

/// A circle in a colour, with the ticker in it, for a coin the app has no outline of.
class _Ticker extends StatelessWidget {
  const _Ticker({required this.coin, required this.size});

  final String coin;
  final double size;

  @override
  Widget build(BuildContext context) {
    final text = coin.toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: Color(0xFF607D8B), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        text.length > 4 ? text.substring(0, 4) : text,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: text.length > 3 ? 11 : 13),
      ),
    );
  }
}
