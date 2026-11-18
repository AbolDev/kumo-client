// Makes lib/core/operator_data.dart from the research file of operators (a JSON array, see below).
//
//   dart run tools/make_operator_data.dart operators.json
//
// Each record: {"brand": "MCI, Hamrah Aval", "country": "IR", "kind": "mobile", "asns": [197207], "names": ["mobile communication
// company of iran"], "holder": [...], "source": "https://..."}. Only brand, asns and names go into the app; the rest is the proof.
import 'dart:convert';
import 'dart:io';

String q(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tools/make_operator_data.dart operators.json');
    exit(2);
  }
  final records = (jsonDecode(File(args.first).readAsStringSync()) as List).cast<Map<String, dynamic>>();
  final out = StringBuffer()
    ..writeln('// The operators the app shows a known name for: ${records.length} operators, with their ASNs and the pieces of the names')
    ..writeln('// they are registered under. Made from research (every ASN checked against its holder in RIPEstat), by')
    ..writeln('// tools/make_operator_data.dart; do not edit by hand.')
    ..writeln()
    ..writeln('/// An operator (a mobile network or an internet provider) by the names the services report it under, and the name people know')
    ..writeln('/// it by.')
    ..writeln('class OperatorEntry {')
    ..writeln('  const OperatorEntry(this.brand, {this.asns = const [], this.names = const []});')
    ..writeln()
    ..writeln('  /// The name people know it by, in Latin letters ("Irancell").')
    ..writeln('  final String brand;')
    ..writeln()
    ..writeln('  /// The numbers of its networks (197207), exact.')
    ..writeln('  final List<int> asns;')
    ..writeln()
    ..writeln('  /// Lower-case pieces of the name it is registered under, each one only that company\'s.')
    ..writeln('  final List<String> names;')
    ..writeln('}')
    ..writeln()
    ..writeln('const operatorTable = <OperatorEntry>[');
  String? country;
  for (final r in records) {
    final c = '${r['country'] ?? ''}';
    if (c != country) {
      country = c;
      out.writeln('  // $c');
    }
    final asns = [for (final a in (r['asns'] as List? ?? const [])) '$a'];
    final names = [for (final n in (r['names'] as List? ?? const [])) q('$n'.toLowerCase().trim())];
    out.write('  OperatorEntry(${q('${r['brand']}')}');
    if (asns.isNotEmpty) out.write(', asns: [${asns.join(', ')}]');
    if (names.isNotEmpty) out.write(', names: [${names.join(', ')}]');
    out.writeln('),');
  }
  out.writeln('];');
  File('lib/core/operator_data.dart').writeAsStringSync(out.toString());
  stdout.writeln('${records.length} operators written to lib/core/operator_data.dart');
}
