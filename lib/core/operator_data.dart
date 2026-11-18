// The operators the app shows a known name for. Made from research (every ASN checked against its holder), see
// tools/make_operator_data.dart; do not edit by hand.
/// An operator (a mobile network or an internet provider) by the names the services report it under, and the name people know
/// it by. The data is in operator_data.dart.
class OperatorEntry {
  const OperatorEntry(this.brand, {this.asns = const [], this.names = const []});

  /// The name people know it by, in Latin letters ("Irancell").
  final String brand;

  /// The numbers of its networks (197207), exact.
  final List<int> asns;

  /// Lower-case pieces of the name it is registered under, each one only that company's.
  final List<String> names;
}

const operatorTable = <OperatorEntry>[
  OperatorEntry('MCI, Hamrah Aval', asns: [197207], names: ['mobile communication company of iran']),
  OperatorEntry('Irancell', asns: [44244], names: ['iran cell service and communication']),
  OperatorEntry('Rightel', asns: [57218], names: ['rightel communication']),
];
